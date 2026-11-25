package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

must_write_stream :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId,
	loc := #caller_location,
) {
	terr, perr := trans.write_frame(conn, opcode, payload, stream_id)
	testing.expect_value(t, terr, trans.TransportError.None, loc)
	testing.expect_value(t, perr, proto.ProtocolError.None, loc)
}

quiet_test_server :: proc(
	t: ^testing.T,
	server: ^Server,
	reg: ^Registry,
	store: ^auth.StaticTokenAuth,
	loc := #caller_location,
) {
	start_test_server(t, server, reg, store, loc)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
}

when ODIN_TEST {
	@(test)
	test_relay_caller_cancellation_holds_slot_until_reset :: proc(t: ^testing.T) {
		testing.set_fail_timeout(t, 10 * time.Second)
		agent_socket, peer, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(agent_socket)
		defer trans.connection_destroy(peer)
		server: Server
		server_init(&server, nil, {})
		defer server_destroy(&server)
		server.max_streams_per_session = 1
		session: SessionId = 1
		relay_bind_agent(&server, session, agent_socket)
		agent := ConnHandler{server = &server, conn = agent_socket}
		if !testing.expect(t, conn_start_outbox(&agent), "start agent outbox") {
			return
		}
		defer conn_stop_outbox(&agent)
		// The cleanup handler owns one reference; keep the other on the stack.
		socket := trans.Connection{refs = 2, closed = true}
		caller := ConnHandler{server = &server, conn = &socket, role = .Caller}
		sid, held, open_err := relay_open_stream(&server, TEST_SERVICE, session, &socket)
		if !testing.expect_value(t, open_err, RelayOpenError.None) {
			return
		}
		trans.connection_release(held)

		sync.mutex_lock(&agent_socket.write_mutex)
		socket_held := true
		defer if socket_held {
			sync.mutex_unlock(&agent_socket.write_mutex)
		}
		payload, payload_err := proto.encode_open({service_id = TEST_SERVICE})
		defer delete(payload)
		testing.expect_value(t, payload_err, proto.ProtocolError.None)
		testing.expect_value(t, outbox_enqueue(agent.outbox, .Open, sid, payload), OutboxEnqueueError.None)
		start := time.tick_now()
		open_in_flight := false
		for !open_in_flight && time.tick_since(start) < 2 * time.Second {
			open_in_flight = outbox_queued(agent.outbox, sid) == 0
			if !open_in_flight {
				time.sleep(time.Millisecond)
			}
		}
		if !testing.expect(t, open_in_flight, "agent writer took OPEN before caller loss") {
			return
		}
		cleanup := thread.create_and_start_with_poly_data(&caller, conn_cleanup)
		if !testing.expect(t, cleanup != nil, "start caller cleanup") {
			return
		}
		defer {
			if socket_held {
				sync.mutex_unlock(&agent_socket.write_mutex)
				socket_held = false
			}
			thread.destroy(cleanup)
		}
		start = time.tick_now()
		for outbox_queued(agent.outbox, sid) == 0 && time.tick_since(start) < 2 * time.Second {
			time.sleep(time.Millisecond)
		}
		if !testing.expect_value(t, outbox_queued(agent.outbox, sid), 1) {
			return
		}
		thread.join(cleanup)
		_, found := relay_lookup_stream(&server, sid)
		testing.expect(t, !found, "caller cleanup removed stream ownership")
		testing.expect_value(t, outbox_queued(agent.outbox, sid), 1)
		outbox_drop_stream(agent.outbox, sid)
		testing.expect_value(t, outbox_queued(agent.outbox, sid), 1)
		next_caller := trans.Connection{refs = 1}
		new_sid, new_held, admission := relay_open_stream(&server, TEST_SERVICE, session, &next_caller)
		testing.expect_value(t, admission, RelayOpenError.QuotaExceeded)
		if admission == .None {
			trans.connection_release(new_held)
			relay_drop_stream(&server, new_sid)
		}

		sync.mutex_unlock(&agent_socket.write_mutex)
		socket_held = false
		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		open_frame := must_read_opcode(t, peer, &decoder, .Open)
		defer proto.frame_destroy(&open_frame)
		reset_frame := must_read_opcode(t, peer, &decoder, .Reset)
		defer proto.frame_destroy(&reset_frame)
		testing.expect_value(t, open_frame.header.stream_id, sid)
		testing.expect_value(t, reset_frame.header.stream_id, sid)
		start = time.tick_now()
		for {
			new_sid, new_held, admission = relay_open_stream(&server, TEST_SERVICE, session, &next_caller)
			if admission != .QuotaExceeded || time.tick_since(start) >= 2 * time.Second {
				break
			}
			time.sleep(time.Millisecond)
		}
		if !testing.expect_value(t, admission, RelayOpenError.None) {
			return
		}
		trans.connection_release(new_held)
		defer relay_drop_stream(&server, new_sid)

		// An explicit cancellation also retains admission while queued.
		outbox_set_writer_hold(agent.outbox, true)
		testing.expect_value(t, outbox_enqueue(agent.outbox, .Open, new_sid, payload), OutboxEnqueueError.None)
		next_handler := ConnHandler{server = &server, conn = &next_caller, role = .Caller}
		_ = conn_handle_stream_frame(&next_handler, {header = {opcode = .Close, stream_id = new_sid}})
		_, found = relay_lookup_stream(&server, new_sid)
		testing.expect(t, !found)
		testing.expect_value(t, outbox_queued(agent.outbox, new_sid), 1)
		third, third_held, third_err := relay_open_stream(&server, TEST_SERVICE, session, &next_caller)
		testing.expect_value(t, third_err, RelayOpenError.QuotaExceeded)
		if third_err == .None {
			trans.connection_release(third_held)
			relay_drop_stream(&server, third)
		}
	}
}

register_test_agent :: proc(
	t: ^testing.T,
	server: ^Server,
	loc := #caller_location,
) -> (
	^trans.Connection,
	proto.FrameDecoder,
) {
	conn := dial_server(t, server, loc)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder, TOKEN_HOST, loc)
	send_register(t, conn, TEST_SERVICE, loc)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk, loc)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
	return conn, decoder
}

open_test_stream :: proc(
	t: ^testing.T,
	agent: ^trans.Connection,
	agent_dec: ^proto.FrameDecoder,
	caller: ^trans.Connection,
	caller_dec: ^proto.FrameDecoder,
	loc := #caller_location,
) -> proto.StreamId {
	send_connect(t, caller, TEST_SERVICE, loc)
	open_frame := must_read_opcode(t, agent, agent_dec, .Open, loc)
	testing.expect(t, open_frame.header.stream_id != proto.CONNECTION_STREAM_ID, loc = loc)
	open_msg, oerr := proto.decode_open(open_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None, loc)
	testing.expect_value(t, string(open_msg.service_id), TEST_SERVICE, loc)
	delete(string(open_msg.service_id))
	stream_id := open_frame.header.stream_id
	proto.frame_destroy(&open_frame)

	must_write_stream(t, agent, .OpenOk, nil, stream_id, loc)
	ok_frame := must_read_opcode(t, caller, caller_dec, .ConnectOk, loc)
	testing.expect_value(t, ok_frame.header.stream_id, stream_id, loc)
	testing.expect_value(t, proto.decode_empty(ok_frame.payload), proto.ProtocolError.None, loc)
	proto.frame_destroy(&ok_frame)
	return stream_id
}

EchoWorker :: struct {
	ln: ^trans.Listener,
}

echo_accept_and_mirror :: proc(w: ^EchoWorker) {
	conn, err := trans.listener_accept(w.ln)
	if err != .None {
		return
	}
	defer trans.connection_destroy(conn)
	buf: [1024]u8
	for {
		n, rerr := trans.connection_read(conn, buf[:])
		if rerr != .None {
			return
		}
		if trans.connection_write(conn, buf[:n]) != .None {
			return
		}
	}
}

@(test)
test_relay_connect_unknown_service_not_found :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_connect(t, caller, TEST_SERVICE)
	fail := must_read_opcode(t, caller, &decoder, .ConnectFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.ServiceNotFound)
}

@(test)
test_relay_connect_open_ok_same_stream_id :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	stream_id := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	testing.expect(t, stream_id != proto.CONNECTION_STREAM_ID)
}

@(test)
test_relay_echo_bytes_match :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	echo_ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	defer trans.listener_close(&echo_ln)
	_ = trans.listener_set_recv_timeout(&echo_ln, 2 * time.Second)
	echo_ep, eerr := trans.listener_endpoint(echo_ln)
	testing.expect_value(t, eerr, trans.TransportError.None)

	worker := EchoWorker{ln = &echo_ln}
	echo_thread := thread.create_and_start_with_poly_data(&worker, echo_accept_and_mirror)
	defer {
		thread.join(echo_thread)
		thread.destroy(echo_thread)
	}

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, TEST_SERVICE)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	stream_id := open_frame.header.stream_id
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)

	local, derr := trans.connection_dial(echo_ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	testing.expect(t, local != nil)
	defer trans.connection_destroy(local)
	_ = trans.connection_set_recv_timeout(local, 2 * time.Second)

	must_write_stream(t, agent, .OpenOk, nil, stream_id)
	ok_frame := must_read_opcode(t, caller, &caller_dec, .ConnectOk)
	testing.expect_value(t, ok_frame.header.stream_id, stream_id)
	proto.frame_destroy(&ok_frame)

	payload := []u8{'h', 'e', 'l', 'l', 'o'}
	must_write_stream(t, caller, .Data, payload, stream_id)

	data_frame := must_read_opcode(t, agent, &agent_dec, .Data)
	testing.expect_value(t, data_frame.header.stream_id, stream_id)
	testing.expect_value(t, string(data_frame.payload), "hello")
	testing.expect_value(t, trans.connection_write(local, data_frame.payload), trans.TransportError.None)
	proto.frame_destroy(&data_frame)

	buf: [16]u8
	n, rerr := trans.connection_read(local, buf[:])
	testing.expect_value(t, rerr, trans.TransportError.None)
	testing.expect_value(t, string(buf[:n]), "hello")
	must_write_stream(t, agent, .Data, buf[:n], stream_id)

	echoed := must_read_opcode(t, caller, &caller_dec, .Data)
	testing.expect_value(t, echoed.header.stream_id, stream_id)
	testing.expect_value(t, string(echoed.payload), "hello")
	proto.frame_destroy(&echoed)
}

@(test)
test_relay_open_failed_local_unavailable :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, TEST_SERVICE)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	stream_id := open_frame.header.stream_id
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)

	fail_payload, perr := proto.encode_wire_failure(
		proto.WireFailure {
			code       = proto.wire_error_to_u16(.LocalServiceUnavailable),
			diagnostic = "dial failed",
		},
	)
	testing.expect_value(t, perr, proto.ProtocolError.None)
	defer delete(fail_payload)
	must_write_stream(t, agent, .OpenFailed, fail_payload, stream_id)

	fail := must_read_opcode(t, caller, &caller_dec, .ConnectFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.LocalServiceUnavailable)
}

@(test)
test_relay_caller_disconnect_resets_stream_keeps_registration :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	stream_id := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	_ = stream_id

	proto.decoder_destroy(&caller_dec)
	trans.connection_destroy(caller)

	reset_frame := must_read_opcode(t, agent, &agent_dec, .Reset)
	proto.frame_destroy(&reset_frame)

	svc := must_service_id(t, TEST_SERVICE)
	_, found := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, found)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_relay_agent_disconnect_resets_stream_and_drops_registration :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	_ = open_test_stream(t, agent, &agent_dec, caller, &caller_dec)

	proto.decoder_destroy(&agent_dec)
	trans.connection_destroy(agent)

	reset_frame := must_read_opcode(t, caller, &caller_dec, .Reset)
	code := read_wire_failure(t, reset_frame)
	proto.frame_destroy(&reset_frame)
	testing.expect_value(t, code, proto.WireError.AgentUnavailable)

	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		if service_count(&reg) == 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, service_count(&reg), 0)
}

// Agent DATA is stuck because the caller outbox is not draining, so the
// broker agent thread sits in outbox_wait and stops reading. Killing the
// caller session must unblock that write and deliver RESET. A write that
// is still stuck after the session is gone is a wedge on the agent session.
BLOCKED_CHUNK :: 4 * 1024

blocked_agent_reads: int // atomic, incremented by the broker-side agent socket's read hook

count_blocked_agent_read :: proc(_: ^trans.Connection) {
	sync.atomic_add(&blocked_agent_reads, 1)
}

BlockedWrite :: struct {
	conn:      ^trans.Connection,
	stream_id: proto.StreamId,
	stop:      bool, // atomic; finish the in-flight write and send no more DATA
	done:      bool, // atomic
	sent:      int, // atomic
	terr:      trans.TransportError,
	perr:      proto.ProtocolError,
}

blocked_write_proc :: proc(w: ^BlockedWrite) {
	chunk: [BLOCKED_CHUNK]u8
	for !sync.atomic_load(&w.stop) {
		w.terr, w.perr = trans.write_frame(w.conn, .Data, chunk[:], w.stream_id)
		if w.terr != .None || w.perr != .None {
			break
		}
		sync.atomic_add(&w.sent, BLOCKED_CHUNK)
	}
	sync.atomic_store(&w.done, true)
}

@(test)
test_blocked_agent_write_unblocks_when_caller_session_dies :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	// One chunk fills the stream. The next DATA frame is read and then the
	// agent thread waits; further frames sit in the kernel until it reads.
	server.max_stream_buffer = BLOCKED_CHUNK

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	caller_open := true
	defer if caller_open {
		trans.connection_destroy(caller)
	}
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	sid := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	broker_agent, stream, found := relay_acquire_peer(&server, sid, .Agent)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	defer trans.connection_release(broker_agent)
	box := server_lookup_outbox(&server, stream.caller_conn)
	testing.expect(t, box != nil, "caller outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)
	sync.atomic_store(&blocked_agent_reads, 0)
	sync.atomic_store(&broker_agent.read_hook, rawptr(count_blocked_agent_read))
	defer sync.atomic_store(&broker_agent.read_hook, nil)

	w := BlockedWrite {
		conn = agent,
		stream_id = sid,
	}
	// Use the default TCP buffer. An explicit small SO_SNDBUF on Winsock
	// loopback let writes keep completing with the broker reader stalled.
	// Backstop so a real wedge fails the assertion instead of hanging the
	// process. The pass condition is the write finishing within 1s of the
	// caller session dying, not this timeout.
	_ = trans.connection_set_send_timeout(agent, 8 * time.Second)
	th := thread.create_and_start_with_poly_data(&w, blocked_write_proc)
	testing.expect(t, th != nil, "writer thread")
	if th == nil {
		return
	}
	defer {
		sync.atomic_store(&w.stop, true)
		if !sync.atomic_load(&w.done) {
			trans.connection_close(agent)
		}
		thread.join(th)
		thread.destroy(th)
	}
	start := time.now()
	progress := start
	last_sent := 0
	last_reads := 0
	blocked := false
	for time.since(start) < 2 * time.Second {
		if sync.atomic_load(&w.done) {
			break
		}
		sent := sync.atomic_load(&w.sent)
		reads := sync.atomic_load(&blocked_agent_reads)
		if sent != last_sent || reads != last_reads || outbox_queued(box, sid) == 0 {
			last_sent = sent
			last_reads = reads
			progress = time.now()
		} else if sent >= 2 * BLOCKED_CHUNK && reads > 0 && time.since(progress) >= 50 * time.Millisecond {
			blocked = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !blocked {
		testing.expectf(
			t,
			false,
			"DATA write did not block (done=%v sent=%d queued=%d broker_reads=%d)",
			sync.atomic_load(&w.done),
			sync.atomic_load(&w.sent),
			outbox_queued(box, sid),
			sync.atomic_load(&blocked_agent_reads),
		)
		return
	}
	fmt.printfln("backpressure: sent=%d queued=%d broker_reads=%d (unchanged during stall)", last_sent, outbox_queued(box, sid), last_reads)

	// Send until actual backpressure, regardless of how much this host's
	// loopback buffers. Caller loss only has to finish the write in flight.
	sync.atomic_store(&w.stop, true)
	trans.connection_destroy(caller)
	caller_open = false

	deadline := time.now()
	for !sync.atomic_load(&w.done) {
		if time.since(deadline) > 1 * time.Second {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !testing.expect(t, sync.atomic_load(&w.done), "agent DATA write still blocked after caller session died") {
		return
	}
	testing.expect_value(t, w.terr, trans.TransportError.None)
	testing.expect_value(t, w.perr, proto.ProtocolError.None)
	testing.expect(t, sync.atomic_load(&w.sent) > last_sent, "the blocked write made no progress after caller loss")
	testing.expect(t, sync.atomic_load(&blocked_agent_reads) > last_reads, "the broker did not resume reading after caller loss")

	// Pings and resets for buffered DATA can race with the cleanup RESET.
	_ = trans.connection_set_recv_timeout(agent, 1 * time.Second)
	got_reset := false
	reset_start := time.tick_now()
	for !got_reset && time.tick_since(reset_start) < time.Second {
		frame, err, perr := trans.read_frame(agent, &agent_dec)
		if err != .None || perr != .None {
			break
		}
		got_reset = frame.header.opcode == .Reset && frame.header.stream_id == sid &&
			read_wire_failure(t, frame) == .InternalError
		proto.frame_destroy(&frame)
	}
	testing.expect(t, got_reset, "agent did not receive the caller-loss RESET")
}

@(test)
test_relay_may_connect_false_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.may_connect = may_connect_deny_all

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, TEST_SERVICE)
	fail := must_read_opcode(t, caller, &caller_dec, .ConnectFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.Unauthorized)
}

@(test)
test_relay_agent_connect_protocol_error :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	send_connect(t, agent, TEST_SERVICE)
	fail := must_read_opcode(t, agent, &agent_dec, .Error)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.ProtocolError)
}

@(test)
test_relay_data_unknown_stream_reset_not_found :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)

	unknown := proto.make_stream_id(99)
	must_write_stream(t, caller, .Data, []u8{'x'}, unknown)
	reset_frame := must_read_opcode(t, caller, &decoder, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, unknown)
	code := read_wire_failure(t, reset_frame)
	proto.frame_destroy(&reset_frame)
	testing.expect_value(t, code, proto.WireError.StreamNotFound)
}

@(test)
test_relay_unregister_keeps_open_stream_and_sibling :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	SIBLING :: "demo/other"
	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)
	send_register(t, agent, SIBLING)
	sib_ok := must_read_opcode(t, agent, &agent_dec, .RegisterOk)
	delete(string((proto.decode_register_ok(sib_ok.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&sib_ok)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	stream_id := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	send_unregister(t, agent, TEST_SERVICE)
	unreg_ok := must_read_opcode(t, agent, &agent_dec, .UnregisterOk)
	delete(string((proto.decode_unregister_ok(unreg_ok.payload) or_else proto.UnregisterOk{}).service_id))
	proto.frame_destroy(&unreg_ok)

	payload := []u8{'k', 'e', 'e', 'p'}
	must_write_stream(t, caller, .Data, payload, stream_id)
	data_frame := must_read_opcode(t, agent, &agent_dec, .Data)
	testing.expect_value(t, data_frame.header.stream_id, stream_id)
	testing.expect_value(t, string(data_frame.payload), "keep")
	proto.frame_destroy(&data_frame)

	missing := dial_server(t, &server)
	defer trans.connection_destroy(missing)
	missing_dec: proto.FrameDecoder
	handshake_caller(t, missing, &missing_dec)
	defer proto.decoder_destroy(&missing_dec)
	send_connect(t, missing, TEST_SERVICE)
	fail := must_read_opcode(t, missing, &missing_dec, .ConnectFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.ServiceNotFound)

	sib_caller := dial_server(t, &server)
	defer trans.connection_destroy(sib_caller)
	sib_dec: proto.FrameDecoder
	handshake_caller(t, sib_caller, &sib_dec)
	defer proto.decoder_destroy(&sib_dec)
	send_connect(t, sib_caller, SIBLING)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)
}

@(test)
test_relay_data_before_open_ok_protocol_error :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, TEST_SERVICE)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	sid := open_frame.header.stream_id
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)

	must_write_stream(t, caller, .Data, []u8{'x'}, sid)
	reset_frame := must_read_opcode(t, caller, &caller_dec, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, sid)
	testing.expect_value(t, read_wire_failure(t, reset_frame), proto.WireError.ProtocolError)
	proto.frame_destroy(&reset_frame)

	agent_reset := must_read_opcode(t, agent, &agent_dec, .Reset)
	proto.frame_destroy(&agent_reset)

	payload, perr := proto.encode_ping(proto.Ping{nonce = 7})
	testing.expect_value(t, perr, proto.ProtocolError.None)
	defer delete(payload)
	must_write_opcode(t, agent, .Ping, payload)
	pong := must_read_opcode(t, agent, &agent_dec, .Pong)
	proto.frame_destroy(&pong)
}

@(test)
test_relay_duplicate_open_ok_protocol_error :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	sid := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	must_write_stream(t, agent, .OpenOk, nil, sid)
	reset_frame := must_read_opcode(t, agent, &agent_dec, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, sid)
	testing.expect_value(t, read_wire_failure(t, reset_frame), proto.WireError.ProtocolError)
	proto.frame_destroy(&reset_frame)
}

@(test)
test_relay_caller_close_is_delivered_to_agent :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	sid := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	// Queue DATA then CLOSE without the agent reading first so the writer
	// is busy. drop_stream_queues after enqueue used to delete the CLOSE.
	payload := []u8{'x', 'y', 'z'}
	must_write_stream(t, caller, .Data, payload, sid)
	must_write_stream(t, caller, .Close, nil, sid)

	got_close := false
	start := time.now()
	for time.since(start) < 2 * time.Second {
		_ = trans.connection_set_recv_timeout(agent, 100 * time.Millisecond)
		frame, terr, perr := trans.read_frame(agent, &agent_dec)
		if terr == .Timeout {
			continue
		}
		testing.expect_value(t, terr, trans.TransportError.None)
		testing.expect_value(t, perr, proto.ProtocolError.None)
		opcode := frame.header.opcode
		got_sid := frame.header.stream_id
		proto.frame_destroy(&frame)
		if opcode == .Data {
			continue
		}
		testing.expect_value(t, opcode, proto.Opcode.Close)
		testing.expect_value(t, got_sid, sid)
		got_close = true
		break
	}
	testing.expect(t, got_close)

	// The agent's outbox can deliver CLOSE before the caller handler
	// removes the relay. A matching PONG on the caller connection confirms
	// that the same handler has finished processing CLOSE.
	nonce :: u64(7)
	ping, ping_err := proto.encode_ping({nonce = nonce})
	testing.expect_value(t, ping_err, proto.ProtocolError.None)
	defer delete(ping)
	must_write_opcode(t, caller, .Ping, ping)
	pong_frame := must_read_opcode(t, caller, &caller_dec, .Pong)
	defer proto.frame_destroy(&pong_frame)
	pong, pong_err := proto.decode_pong(pong_frame.payload)
	testing.expect_value(t, pong_err, proto.ProtocolError.None)
	testing.expect_value(t, pong.nonce, nonce)
	testing.expect_value(t, metrics_snapshot(&server).active_relay_streams, 0)
}

@(test)
test_relay_close_unknown_stream_reset_not_found :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)

	unknown := proto.make_stream_id(99)
	must_write_stream(t, caller, .Close, nil, unknown)
	reset_frame := must_read_opcode(t, caller, &decoder, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, unknown)
	testing.expect_value(t, read_wire_failure(t, reset_frame), proto.WireError.StreamNotFound)
	proto.frame_destroy(&reset_frame)
}
