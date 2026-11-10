package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:bytes"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"

// The second HALF_CLOSE ends the stream. Frames already accepted for it
// (response DATA, the other side's HALF_CLOSE) used to be deleted first, so
// the peer waiting on that EOF never finished. Held writer: the frames are
// still in the caller outbox when the caller's HALF_CLOSE is applied. They
// must still be there, and the caller must then read them.
@(test)
test_second_half_close_keeps_queued_response :: proc(t: ^testing.T) {
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
	stream, found := relay_lookup_stream(&server, sid)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	box := server_lookup_outbox(&server, stream.caller_conn)
	testing.expect(t, box != nil, "caller outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)

	payload := make([]u8, 46 * 1024)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = u8(i)
	}
	must_write_stream(t, agent, .Data, payload, sid)
	must_write_stream(t, agent, .HalfClose, nil, sid)

	queued := 0
	start := time.now()
	for time.since(start) < 2 * time.Second {
		queued = outbox_queued(box, sid)
		if queued >= 2 {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expectf(t, queued >= 2, "agent DATA+HALF_CLOSE never queued (have %d)", queued)
	if queued < 2 {
		return
	}

	must_write_stream(t, caller, .HalfClose, nil, sid)

	got_half := false
	wait := time.now()
	for time.since(wait) < 2 * time.Second && !got_half {
		_ = trans.connection_set_recv_timeout(agent, 200 * time.Millisecond)
		frame, terr, perr := trans.read_frame(agent, &agent_dec)
		if terr == .Timeout {
			continue
		}
		testing.expect_value(t, terr, trans.TransportError.None)
		testing.expect_value(t, perr, proto.ProtocolError.None)
		if frame.header.opcode == .HalfClose && frame.header.stream_id == sid {
			got_half = true
		}
		proto.frame_destroy(&frame)
	}
	testing.expect(t, got_half, "caller HALF_CLOSE was not forwarded")

	// Still held: a drop would have emptied this queue inside the handler.
	testing.expect_value(t, outbox_queued(box, sid), 2)
	if outbox_queued(box, sid) != 2 {
		return
	}
	sn := metrics_snapshot(&server).resets[.StreamNotFound]
	testing.expect_value(t, sn, u64(0))

	outbox_set_writer_hold(box, false)
	data := must_read_opcode(t, caller, &caller_dec, .Data)
	testing.expect(t, bytes.equal(data.payload, payload), "queued response was dropped")
	proto.frame_destroy(&data)
	hc := must_read_opcode(t, caller, &caller_dec, .HalfClose)
	testing.expect_value(t, hc.header.stream_id, sid)
	proto.frame_destroy(&hc)
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], u64(0))
}

// Caller sends a request, then half-closes. The response is still queued
// (writer held) when that HALF_CLOSE is applied. Dropping the queue here
// delivers a short or empty body. The caller must read the response bytes
// unchanged, then the agent's HALF_CLOSE.
@(test)
test_request_half_close_delivers_full_response :: proc(t: ^testing.T) {
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
	request := []u8{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}
	must_write_stream(t, caller, .Data, request, sid)
	req := must_read_opcode(t, agent, &agent_dec, .Data)
	testing.expect(t, bytes.equal(req.payload, request), "request bytes")
	proto.frame_destroy(&req)

	stream, found := relay_lookup_stream(&server, sid)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	box := server_lookup_outbox(&server, stream.caller_conn)
	testing.expect(t, box != nil, "caller outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)

	response := make([]u8, 32 * 1024)
	defer delete(response)
	for i in 0 ..< len(response) {
		response[i] = u8(i * 3 + 1)
	}
	must_write_stream(t, agent, .Data, response, sid)
	must_write_stream(t, agent, .HalfClose, nil, sid)

	queued := 0
	start := time.now()
	for time.since(start) < 2 * time.Second {
		queued = outbox_queued(box, sid)
		if queued >= 2 {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expectf(t, queued >= 2, "response never queued (have %d)", queued)
	if queued < 2 {
		return
	}

	must_write_stream(t, caller, .HalfClose, nil, sid)
	got_half := false
	wait := time.now()
	for time.since(wait) < 2 * time.Second && !got_half {
		_ = trans.connection_set_recv_timeout(agent, 200 * time.Millisecond)
		frame, terr, perr := trans.read_frame(agent, &agent_dec)
		if terr == .Timeout {
			continue
		}
		testing.expect_value(t, terr, trans.TransportError.None)
		testing.expect_value(t, perr, proto.ProtocolError.None)
		if frame.header.opcode == .HalfClose && frame.header.stream_id == sid {
			got_half = true
		}
		proto.frame_destroy(&frame)
	}
	testing.expect(t, got_half, "caller HALF_CLOSE was not forwarded")
	testing.expect_value(t, outbox_queued(box, sid), 2)
	if outbox_queued(box, sid) != 2 {
		return
	}

	outbox_set_writer_hold(box, false)
	data := must_read_opcode(t, caller, &caller_dec, .Data)
	testing.expect(t, bytes.equal(data.payload, response), "half-close dropped the response")
	proto.frame_destroy(&data)
	hc := must_read_opcode(t, caller, &caller_dec, .HalfClose)
	testing.expect_value(t, hc.header.stream_id, sid)
	proto.frame_destroy(&hc)
}

// Caller half-closes, then the agent sends the response, HALF_CLOSE, and
// CLOSE. The second HALF_CLOSE ends the stream. The response must arrive
// whole, closed is recorded once, and the following CLOSE is not
// STREAM_NOT_FOUND.
@(test)
test_half_close_then_close_records_closed_once :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	clog: ConnectionLog
	connection_log_init(&clog)
	defer connection_log_destroy(&clog)
	server.connection_observer_ctx = &clog
	server.connection_observer = observe_connection

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	sid := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	before := metrics_snapshot(&server).resets[.StreamNotFound]

	stream, found := relay_lookup_stream(&server, sid)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	box := server_lookup_outbox(&server, stream.caller_conn)
	testing.expect(t, box != nil, "caller outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)

	must_write_stream(t, caller, .HalfClose, nil, sid)
	caller_half := must_read_opcode(t, agent, &agent_dec, .HalfClose)
	testing.expect_value(t, caller_half.header.stream_id, sid)
	proto.frame_destroy(&caller_half)

	response := make([]u8, 32 * 1024)
	defer delete(response)
	for i in 0 ..< len(response) {
		response[i] = u8(i * 3 + 1)
	}
	must_write_stream(t, agent, .Data, response, sid)
	must_write_stream(t, agent, .HalfClose, nil, sid)
	must_write_stream(t, agent, .Close, nil, sid)

	closed_n := 0
	start := time.now()
	for time.since(start) < 2 * time.Second {
		sync.mutex_lock(&clog.mutex)
		closed_n = 0
		for kind in clog.kinds {
			if kind == .Closed {
				closed_n += 1
			}
		}
		sync.mutex_unlock(&clog.mutex)
		if closed_n >= 1 {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect_value(t, closed_n, 1)
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], before)

	_ = trans.connection_set_recv_timeout(agent, 200 * time.Millisecond)
	frame, terr, _ := trans.read_frame(agent, &agent_dec)
	testing.expect_value(t, terr, trans.TransportError.Timeout)
	if terr == .None {
		testing.expect(t, frame.header.opcode != .Reset, "CLOSE was STREAM_NOT_FOUND")
		proto.frame_destroy(&frame)
	}

	queued := outbox_queued(box, sid)
	testing.expect(t, queued >= 2, "response was dropped before CLOSE")
	outbox_set_writer_hold(box, false)
	data := must_read_opcode(t, caller, &caller_dec, .Data)
	testing.expect(t, bytes.equal(data.payload, response), "response bytes")
	proto.frame_destroy(&data)
	hc := must_read_opcode(t, caller, &caller_dec, .HalfClose)
	testing.expect_value(t, hc.header.stream_id, sid)
	proto.frame_destroy(&hc)
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], before)

	sync.mutex_lock(&clog.mutex)
	closed_n = 0
	for kind in clog.kinds {
		if kind == .Closed {
			closed_n += 1
		}
	}
	sync.mutex_unlock(&clog.mutex)
	testing.expect_value(t, closed_n, 1)
}

finished_len :: proc(server: ^Server, role: proto.PeerRole) -> int {
	sync.mutex_lock(&server.handlers_mutex)
	defer sync.mutex_unlock(&server.handlers_mutex)
	for h in server.handlers {
		if h != nil && h.role == role && h.state == .Authenticated {
			return half_close_finished_len(&h.half_close_finished)
		}
	}
	return -1
}

closed_count :: proc(clog: ^ConnectionLog) -> int {
	sync.mutex_lock(&clog.mutex)
	defer sync.mutex_unlock(&clog.mutex)
	n := 0
	for kind in clog.kinds {
		if kind == .Closed {
			n += 1
		}
	}
	return n
}

expect_reset_not_found :: proc(t: ^testing.T, conn: ^trans.Connection, dec: ^proto.FrameDecoder, sid: proto.StreamId) {
	f := must_read_opcode(t, conn, dec, .Reset)
	testing.expect_value(t, f.header.stream_id, sid)
	testing.expect_value(t, read_wire_failure(t, f), proto.WireError.StreamNotFound)
	proto.frame_destroy(&f)
}

expect_no_stream_frame :: proc(t: ^testing.T, conn: ^trans.Connection, dec: ^proto.FrameDecoder) {
	_ = trans.connection_set_recv_timeout(conn, 200 * time.Millisecond)
	frame, terr, _ := trans.read_frame(conn, dec)
	testing.expect_value(t, terr, trans.TransportError.Timeout)
	if terr == .None {
		proto.frame_destroy(&frame)
	}
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
}

// Caller half-closes, then the agent half-closes and does not send CLOSE.
// That is what agent_maybe_finish does. The ring stays at its cap, a CLOSE
// for an id still in the ring is silent, and an aged-out id is
// STREAM_NOT_FOUND.
@(test)
test_half_close_finished_ring_stays_bounded :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	clog: ConnectionLog
	connection_log_init(&clog)
	defer connection_log_destroy(&clog)
	server.connection_observer_ctx = &clog
	server.connection_observer = observe_connection

	agent, adec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&adec)
	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	cdec: proto.FrameDecoder
	handshake_caller(t, caller, &cdec)
	defer proto.decoder_destroy(&cdec)
	_ = trans.connection_set_recv_timeout(agent, 2 * time.Second)
	_ = trans.connection_set_recv_timeout(caller, 2 * time.Second)

	N :: 10_000
	first: proto.StreamId
	last: proto.StreamId
	for i in 0 ..< N {
		if testing.failed(t) {
			return
		}
		sid := open_test_stream(t, agent, &adec, caller, &cdec)
		must_write_stream(t, caller, .HalfClose, nil, sid)
		a := must_read_opcode(t, agent, &adec, .HalfClose)
		proto.frame_destroy(&a)
		must_write_stream(t, agent, .Data, []u8{1}, sid)
		must_write_stream(t, agent, .HalfClose, nil, sid)
		c := must_read_opcode(t, caller, &cdec, .Data)
		proto.frame_destroy(&c)
		hc := must_read_opcode(t, caller, &cdec, .HalfClose)
		proto.frame_destroy(&hc)
		if i == 0 {
			first = sid
		}
		last = sid
	}

	kept := finished_len(&server, .Agent)
	caller_kept := finished_len(&server, .Caller)
	fmt.printfln("half_close ring: agent_kept=%d caller_kept=%d cap=%d after %d streams", kept, caller_kept, HALF_CLOSE_FINISHED_CAP, N)
	testing.expect_value(t, kept, HALF_CLOSE_FINISHED_CAP)
	testing.expect_value(t, caller_kept, HALF_CLOSE_FINISHED_CAP)
	start := time.now()
	for closed_count(&clog) < N && time.since(start) < 2 * time.Second {
		time.sleep(1 * time.Millisecond)
	}
	testing.expect_value(t, closed_count(&clog), N)

	nf := metrics_snapshot(&server).resets[.StreamNotFound]
	must_write_stream(t, agent, .Data, []u8{9}, last)
	expect_reset_not_found(t, agent, &adec, last)
	testing.expect_value(t, finished_len(&server, .Agent), HALF_CLOSE_FINISHED_CAP)
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], nf + 1)

	nf = metrics_snapshot(&server).resets[.StreamNotFound]
	must_write_stream(t, agent, .Close, nil, last)
	expect_no_stream_frame(t, agent, &adec)
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], nf)
	testing.expect_value(t, closed_count(&clog), N)
	testing.expect_value(t, finished_len(&server, .Agent), HALF_CLOSE_FINISHED_CAP - 1)

	must_write_stream(t, caller, .Close, nil, last)
	expect_no_stream_frame(t, caller, &cdec)
	testing.expect_value(t, closed_count(&clog), N)

	must_write_stream(t, agent, .Close, nil, first)
	expect_reset_not_found(t, agent, &adec, first)
}

// Agent half-closes first, caller second, then the agent sends CLOSE.
// The id is on the agent connection too, so that CLOSE is not
// STREAM_NOT_FOUND, and closed is still recorded once.
@(test)
test_agent_half_close_first_then_close :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	clog: ConnectionLog
	connection_log_init(&clog)
	defer connection_log_destroy(&clog)
	server.connection_observer_ctx = &clog
	server.connection_observer = observe_connection

	agent, adec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&adec)
	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	cdec: proto.FrameDecoder
	handshake_caller(t, caller, &cdec)
	defer proto.decoder_destroy(&cdec)
	_ = trans.connection_set_recv_timeout(agent, 2 * time.Second)
	_ = trans.connection_set_recv_timeout(caller, 2 * time.Second)

	sid := open_test_stream(t, agent, &adec, caller, &cdec)
	must_write_stream(t, agent, .Data, []u8{1, 2, 3}, sid)
	must_write_stream(t, agent, .HalfClose, nil, sid)
	d := must_read_opcode(t, caller, &cdec, .Data)
	testing.expect(t, bytes.equal(d.payload, []u8{1, 2, 3}))
	proto.frame_destroy(&d)
	h1 := must_read_opcode(t, caller, &cdec, .HalfClose)
	proto.frame_destroy(&h1)
	must_write_stream(t, caller, .HalfClose, nil, sid)
	h2 := must_read_opcode(t, agent, &adec, .HalfClose)
	proto.frame_destroy(&h2)

	start := time.now()
	for closed_count(&clog) < 1 && time.since(start) < 2 * time.Second {
		time.sleep(1 * time.Millisecond)
	}
	testing.expect_value(t, closed_count(&clog), 1)
	testing.expect_value(t, finished_len(&server, .Caller), 1)
	testing.expect_value(t, finished_len(&server, .Agent), 1)

	nf := metrics_snapshot(&server).resets[.StreamNotFound]
	must_write_stream(t, agent, .Close, nil, sid)
	expect_no_stream_frame(t, agent, &adec)
	must_write_stream(t, caller, .Close, nil, sid)
	expect_no_stream_frame(t, caller, &cdec)
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], nf)
	testing.expect_value(t, closed_count(&clog), 1)
}

// Failure bound if the handler never reaches the hook. The success path
// wakes on the cond; it does not wait this long.
HALF_CLOSE_PAUSE_FAIL :: 2 * time.Second

arm_half_close_pause :: proc(server: ^Server) {
	p := &server.half_close_pause
	sync.mutex_lock(&p.mutex)
	p.pause = true
	p.paused = false
	p.release = false
	p.watch_close = true
	p.close_done = false
	sync.mutex_unlock(&p.mutex)
}

arm_half_close_watch :: proc(server: ^Server) {
	p := &server.half_close_pause
	sync.mutex_lock(&p.mutex)
	p.watch_close = true
	p.close_done = false
	sync.mutex_unlock(&p.mutex)
}

release_half_close_pause :: proc(server: ^Server) {
	p := &server.half_close_pause
	sync.mutex_lock(&p.mutex)
	p.pause = false
	p.release = true
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mutex)
}

wait_half_close_flag :: proc(server: ^Server, want_paused: bool) -> bool {
	p := &server.half_close_pause
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	start := time.now()
	for {
		ready := p.close_done
		if want_paused {
			ready = p.paused
		}
		if ready {
			return true
		}
		if time.since(start) >= HALF_CLOSE_PAUSE_FAIL {
			return false
		}
		left := HALF_CLOSE_PAUSE_FAIL - time.since(start)
		if !sync.cond_wait_with_timeout(&p.cond, &p.mutex, left) && !ready {
			ready = p.close_done
			if want_paused {
				ready = p.paused
			}
			return ready
		}
	}
}

// Agent half-closes first. The caller's HALF_CLOSE is what closes the
// stream. This parks that handler after the state is Closed and before
// the row is removed, then delivers the agent's CLOSE in that window.
// Without the no-op, that CLOSE is IllegalEvent: the queued response is
// dropped and both sides get RESET PROTOCOL_ERROR.
@(test)
test_close_during_terminal_half_close_keeps_response :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	clog: ConnectionLog
	connection_log_init(&clog)
	defer connection_log_destroy(&clog)
	server.connection_observer_ctx = &clog
	server.connection_observer = observe_connection

	agent, adec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&adec)
	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	cdec: proto.FrameDecoder
	handshake_caller(t, caller, &cdec)
	defer proto.decoder_destroy(&cdec)
	_ = trans.connection_set_recv_timeout(agent, 2 * time.Second)
	_ = trans.connection_set_recv_timeout(caller, 2 * time.Second)

	sid := open_test_stream(t, agent, &adec, caller, &cdec)
	stream, found := relay_lookup_stream(&server, sid)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	box := server_lookup_outbox(&server, stream.caller_conn)
	testing.expect(t, box != nil, "caller outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)

	response := make([]u8, 4096)
	defer delete(response)
	for i in 0 ..< len(response) {
		response[i] = u8(i * 3 + 1)
	}
	must_write_stream(t, agent, .Data, response, sid)
	must_write_stream(t, agent, .HalfClose, nil, sid)

	queued := 0
	start := time.now()
	for time.since(start) < 2 * time.Second {
		queued = outbox_queued(box, sid)
		if queued >= 2 {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expectf(t, queued >= 2, "response never queued (have %d)", queued)
	if queued < 2 {
		return
	}
	live, live_ok := relay_lookup_stream(&server, sid)
	testing.expect(t, live_ok && live.state == .AgentHalfClosed, "agent half-close applied")
	if !live_ok || live.state != .AgentHalfClosed {
		return
	}

	arm_half_close_pause(&server)
	defer release_half_close_pause(&server)
	must_write_stream(t, caller, .HalfClose, nil, sid)
	testing.expect(t, wait_half_close_flag(&server, true), "terminal half-close did not pause")
	if testing.failed(t) {
		return
	}

	held, held_ok := relay_lookup_stream(&server, sid)
	testing.expect(t, held_ok && held.state == .Closed, "row still closed, not dropped")
	testing.expect_value(t, outbox_queued(box, sid), 2)
	testing.expect_value(t, metrics_snapshot(&server).resets[.ProtocolError], u64(0))
	testing.expect_value(t, closed_count(&clog), 0)
	if testing.failed(t) {
		return
	}

	must_write_stream(t, agent, .Close, nil, sid)
	testing.expect(t, wait_half_close_flag(&server, false), "agent CLOSE was not handled while paused")
	if testing.failed(t) {
		return
	}

	after, after_ok := relay_lookup_stream(&server, sid)
	testing.expect(t, after_ok && after.state == .Closed, "CLOSE removed or reset the stream")
	testing.expect_value(t, outbox_queued(box, sid), 2)
	testing.expect_value(t, metrics_snapshot(&server).resets[.ProtocolError], u64(0))
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], u64(0))
	testing.expect_value(t, closed_count(&clog), 0)
	agent_box := server_lookup_outbox(&server, after.agent_conn)
	if agent_box != nil {
		testing.expect_value(t, outbox_queued(agent_box, sid), 0)
		outbox_release(agent_box)
	}
	if testing.failed(t) {
		return
	}

	release_half_close_pause(&server)
	agent_half := must_read_opcode(t, agent, &adec, .HalfClose)
	testing.expect_value(t, agent_half.header.stream_id, sid)
	proto.frame_destroy(&agent_half)

	outbox_set_writer_hold(box, false)
	data := must_read_opcode(t, caller, &cdec, .Data)
	testing.expect(t, bytes.equal(data.payload, response), "queued response was dropped")
	proto.frame_destroy(&data)
	hc := must_read_opcode(t, caller, &cdec, .HalfClose)
	testing.expect_value(t, hc.header.stream_id, sid)
	proto.frame_destroy(&hc)

	closed_wait := time.now()
	for closed_count(&clog) < 1 && time.since(closed_wait) < 2 * time.Second {
		time.sleep(1 * time.Millisecond)
	}
	testing.expect_value(t, closed_count(&clog), 1)
	testing.expect_value(t, metrics_snapshot(&server).resets[.ProtocolError], u64(0))
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], u64(0))

	must_write_stream(t, agent, .Close, nil, sid)
	expect_no_stream_frame(t, agent, &adec)
	testing.expect_value(t, closed_count(&clog), 1)
	testing.expect_value(t, metrics_snapshot(&server).resets[.ProtocolError], u64(0))
}

// Agent half-closes, then its CLOSE arrives before the caller finishes.
// That CLOSE used to move the stream to Closed and drop the queued response.
@(test)
test_close_after_own_half_close_keeps_response :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	clog: ConnectionLog
	connection_log_init(&clog)
	defer connection_log_destroy(&clog)
	server.connection_observer_ctx = &clog
	server.connection_observer = observe_connection

	agent, adec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&adec)
	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	cdec: proto.FrameDecoder
	handshake_caller(t, caller, &cdec)
	defer proto.decoder_destroy(&cdec)
	_ = trans.connection_set_recv_timeout(agent, 2 * time.Second)
	_ = trans.connection_set_recv_timeout(caller, 2 * time.Second)

	sid := open_test_stream(t, agent, &adec, caller, &cdec)
	stream, found := relay_lookup_stream(&server, sid)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	box := server_lookup_outbox(&server, stream.caller_conn)
	testing.expect(t, box != nil, "caller outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)

	response := []u8{0x10, 0x20, 0x30, 0x40, 0x50, 0x60}
	must_write_stream(t, agent, .Data, response, sid)
	must_write_stream(t, agent, .HalfClose, nil, sid)

	queued := 0
	start := time.now()
	for time.since(start) < 2 * time.Second {
		queued = outbox_queued(box, sid)
		if queued >= 2 {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expectf(t, queued >= 2, "response never queued (have %d)", queued)
	if queued < 2 {
		return
	}
	live, live_ok := relay_lookup_stream(&server, sid)
	testing.expect(t, live_ok && live.state == .AgentHalfClosed, "agent half-close applied")
	if !live_ok || live.state != .AgentHalfClosed {
		return
	}

	arm_half_close_watch(&server)
	must_write_stream(t, agent, .Close, nil, sid)
	testing.expect(t, wait_half_close_flag(&server, false), "agent CLOSE was not handled")
	if testing.failed(t) {
		return
	}

	after, after_ok := relay_lookup_stream(&server, sid)
	testing.expect(t, after_ok && after.state == .AgentHalfClosed, "CLOSE from the half-closed sender changed state")
	testing.expect_value(t, outbox_queued(box, sid), 2)
	testing.expect_value(t, metrics_snapshot(&server).resets[.ProtocolError], u64(0))
	testing.expect_value(t, closed_count(&clog), 0)
	if testing.failed(t) {
		return
	}

	must_write_stream(t, caller, .HalfClose, nil, sid)
	agent_half := must_read_opcode(t, agent, &adec, .HalfClose)
	testing.expect_value(t, agent_half.header.stream_id, sid)
	proto.frame_destroy(&agent_half)

	outbox_set_writer_hold(box, false)
	data := must_read_opcode(t, caller, &cdec, .Data)
	testing.expect(t, bytes.equal(data.payload, response), "queued response was dropped")
	proto.frame_destroy(&data)
	hc := must_read_opcode(t, caller, &cdec, .HalfClose)
	testing.expect_value(t, hc.header.stream_id, sid)
	proto.frame_destroy(&hc)

	closed_wait := time.now()
	for closed_count(&clog) < 1 && time.since(closed_wait) < 2 * time.Second {
		time.sleep(1 * time.Millisecond)
	}
	testing.expect_value(t, closed_count(&clog), 1)
	testing.expect_value(t, metrics_snapshot(&server).resets[.ProtocolError], u64(0))
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], u64(0))
}
