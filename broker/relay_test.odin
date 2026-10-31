package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:net"
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
	_, found := lookup_service(&reg, svc)
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

// Caller DATA is stuck because the agent outbox is not draining, so the
// broker caller thread sits in outbox_wait and stops reading. Killing the
// agent session must unblock that write and deliver RESET. A write that
// is still stuck after the session is gone is the caller wedge: this
// broker never came back to read, so a later CONNECT stays in the kernel.
BLOCKED_CHUNK :: 4 * 1024
BLOCKED_TOTAL :: 1024 * 1024

BlockedWrite :: struct {
	conn:      ^trans.Connection,
	stream_id: proto.StreamId,
	done:      bool, // atomic
	sent:      int, // atomic
	terr:      trans.TransportError,
	perr:      proto.ProtocolError,
}

blocked_write_proc :: proc(w: ^BlockedWrite) {
	chunk := make([]u8, BLOCKED_CHUNK)
	defer delete(chunk)
	sent := 0
	for sent < BLOCKED_TOTAL {
		w.terr, w.perr = trans.write_frame(w.conn, .Data, chunk, w.stream_id)
		if w.terr != .None || w.perr != .None {
			break
		}
		sent += BLOCKED_CHUNK
		sync.atomic_store(&w.sent, sent)
	}
	sync.atomic_store(&w.done, true)
}

@(test)
test_blocked_caller_write_unblocks_when_agent_session_dies :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	// One chunk fills the stream. The next DATA frame is read and then the
	// caller thread waits; further frames sit in the kernel until it reads.
	server.max_stream_buffer = BLOCKED_CHUNK

	agent, agent_dec := register_test_agent(t, &server)
	agent_open := true
	defer if agent_open {
		trans.connection_destroy(agent)
	}
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	sid := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	stream, found := relay_lookup_stream(&server, sid)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	box := server_lookup_outbox(&server, stream.agent_conn)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)

	w := BlockedWrite {
		conn = caller,
		stream_id = sid,
	}
	// Loopback send buffers are megabytes. Shrink this one so the write
	// stops in the kernel once the broker stops reading, which is the same
	// state a full production buffer reaches.
	testing.expect_value(t, net.set_option(caller.socket, .Send_Buffer_Size, 16 * 1024), net.Socket_Option_Error.None)
	// Backstop so a real wedge fails the assertion instead of hanging the
	// process. The pass condition is the write finishing within 1s of the
	// agent session dying, not this timeout.
	_ = trans.connection_set_send_timeout(caller, 8 * time.Second)
	th := thread.create_and_start_with_poly_data(&w, blocked_write_proc)
	testing.expect(t, th != nil, "writer thread")
	if th == nil {
		return
	}
	defer {
		thread.join(th)
		thread.destroy(th)
	}
	start := time.now()
	blocked := false
	for time.since(start) < 2 * time.Second {
		if sync.atomic_load(&w.done) {
			break
		}
		if outbox_queued(box, sid) >= 1 {
			time.sleep(50 * time.Millisecond)
			blocked = !sync.atomic_load(&w.done)
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(
		t,
		blocked,
		"DATA write did not block (done=%v sent=%d terr=%v perr=%v queued=%d)",
		sync.atomic_load(&w.done),
		sync.atomic_load(&w.sent),
		w.terr,
		w.perr,
		outbox_queued(box, sid),
	)
	if !blocked {
		return
	}

	trans.connection_destroy(agent)
	agent_open = false

	deadline := time.now()
	for !sync.atomic_load(&w.done) {
		if time.since(deadline) > 1 * time.Second {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&w.done), "caller DATA write still blocked after agent session died")
	testing.expect_value(t, w.terr, trans.TransportError.None)
	testing.expect_value(t, w.perr, proto.ProtocolError.None)

	// Closing the agent outbox fails the caller thread's outbox_wait, which
	// resets InternalError, unless cleanup already sent AgentUnavailable.
	// Either code means the DATA write finished and the broker read again.
	_ = trans.connection_set_recv_timeout(caller, 1 * time.Second)
	reset := must_read_opcode(t, caller, &caller_dec, .Reset)
	code := read_wire_failure(t, reset)
	proto.frame_destroy(&reset)
	testing.expectf(
		t,
		code == .InternalError || code == .AgentUnavailable,
		"blocked write reset %v",
		code,
	)
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