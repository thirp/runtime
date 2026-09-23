package caller

import ag "../agent"
import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:testing"
import "core:time"

// Field: N=256 graceful CLOSE (thirp-connect / ingress conn_destroy), then
// idle. Caller session stays up. `stream_not_found` must stay flat and
// origin fds must return to 0. A 383k/s loop is visible in milliseconds.
CLOSE_STORM_BURST :: 32
CLOSE_STORM_IDLE :: 250 * time.Millisecond
CLOSE_STORM_DRAIN :: 2 * time.Second

@(test)
test_caller_unknown_data_does_not_reset :: proc(t: ^testing.T) {
	pipe := open_caller_pipe(t)
	defer close_caller_pipe(&pipe)

	c: Caller
	c.conn = pipe.caller
	c.streams = make(map[proto.StreamId]^Conn)
	defer delete(c.streams)

	sid := proto.make_stream_id(99)
	caller_handle_data(&c, make_stream_frame(.Data, sid, []u8{'x'}))
	caller_handle_half_close(&c, sid)
	caller_handle_close(&c, sid, .Reset)
	expect_no_peer_frame(t, pipe.peer)
}

@(test)
test_caller_finished_stream_reset_does_not_echo :: proc(t: ^testing.T) {
	pipe := open_caller_pipe(t)
	defer close_caller_pipe(&pipe)

	c: Caller
	c.conn = pipe.caller
	c.streams = make(map[proto.StreamId]^Conn)
	defer delete(c.streams)

	sid := proto.make_stream_id(7)
	stream, aerr := new(Conn)
	testing.expect(t, aerr == .None)
	testing.expect(t, stream != nil)
	defer {
		delete(stream.inbound)
		free(stream)
	}
	stream.caller = &c
	stream.stream_id = sid
	c.streams[sid] = stream

	conn_close(stream)
	_, found := c.streams[sid]
	testing.expect(t, !found)

	drain_peer_control(t, pipe.peer)
	caller_handle_data(&c, make_stream_frame(.Data, sid, []u8{'y'}))
	caller_handle_half_close(&c, sid)
	caller_handle_close(&c, sid, .Reset)
	expect_no_peer_frame(t, pipe.peer)
}

@(test)
test_caller_graceful_close_then_idle_stream_not_found_stays_flat :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, echo_ep, &agent, &run)
	defer stop_agent(&agent, th)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_CALLER, insecure = true},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	payload := []u8{'c', 'l', 'o', 's', 'e'}
	for _ in 0 ..< CLOSE_STORM_BURST {
		conn, derr := dial(&c, must_service(t, TEST_SERVICE))
		testing.expect_value(t, derr, CallerError.None)
		testing.expect(t, conn != nil)
		n, werr := conn_write(conn, payload)
		testing.expect_value(t, werr, ConnError.None)
		testing.expect_value(t, n, len(payload))
		buf: [16]u8
		rn, rerr := conn_read(conn, buf[:])
		testing.expect_value(t, rerr, ConnError.None)
		testing.expect_value(t, string(buf[:rn]), string(payload))
		conn_destroy(conn)
	}

	wait_caller_idle(t, &fx, &echo)
	testing.expect_value(t, sync.atomic_load(&echo.live_conns), 0)
	base := brk.metrics_snapshot(&fx.server).resets[.StreamNotFound]
	idle_start := time.now()
	for time.since(idle_start) < CLOSE_STORM_IDLE {
		time.sleep(50 * time.Millisecond)
		got := brk.metrics_snapshot(&fx.server).resets[.StreamNotFound]
		testing.expect_value(t, got, base)
		testing.expect_value(t, sync.atomic_load(&echo.live_conns), 0)
	}
	testing.expect(t, c.connected)

	conn, derr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, derr, CallerError.None)
	defer conn_destroy(conn)
	_, werr := conn_write(conn, []u8{'o', 'k'})
	testing.expect_value(t, werr, ConnError.None)
	buf: [8]u8
	rn, rerr := conn_read(conn, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:rn]), "ok")
	testing.expect_value(
		t,
		brk.metrics_snapshot(&fx.server).resets[.StreamNotFound],
		base,
	)
}

CallerPipe :: struct {
	ln:     trans.Listener,
	caller: ^trans.Connection,
	peer:   ^trans.Connection,
}

open_caller_pipe :: proc(t: ^testing.T, loc := #caller_location) -> CallerPipe {
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	ep, eerr := trans.listener_endpoint(ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	caller, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None, loc)
	peer, aerr := trans.listener_accept(&ln)
	testing.expect_value(t, aerr, trans.TransportError.None, loc)
	return CallerPipe{ln = ln, caller = caller, peer = peer}
}

close_caller_pipe :: proc(p: ^CallerPipe) {
	if p.caller != nil {
		trans.connection_destroy(p.caller)
		p.caller = nil
	}
	if p.peer != nil {
		trans.connection_destroy(p.peer)
		p.peer = nil
	}
	trans.listener_close(&p.ln)
}

make_stream_frame :: proc(
	opcode: proto.Opcode,
	stream_id: proto.StreamId,
	payload: []u8,
) -> proto.Frame {
	return proto.Frame {
		header = proto.FrameHeader {
			version   = proto.PROTOCOL_MAJOR,
			opcode    = opcode,
			stream_id = stream_id,
		},
		payload = payload,
	}
}

expect_no_peer_frame :: proc(t: ^testing.T, peer: ^trans.Connection, loc := #caller_location) {
	_ = trans.connection_set_recv_timeout(peer, 50 * time.Millisecond)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None, loc)
	defer proto.decoder_destroy(&decoder)
	frame, terr, perr := trans.read_frame(peer, &decoder)
	testing.expect_value(t, terr, trans.TransportError.Timeout, loc)
	testing.expect_value(t, perr, proto.ProtocolError.None, loc)
	proto.frame_destroy(&frame)
}

drain_peer_control :: proc(t: ^testing.T, peer: ^trans.Connection, loc := #caller_location) {
	_ = trans.connection_set_recv_timeout(peer, 100 * time.Millisecond)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None, loc)
	defer proto.decoder_destroy(&decoder)
	for {
		frame, terr, perr := trans.read_frame(peer, &decoder)
		if terr == .Timeout {
			testing.expect_value(t, perr, proto.ProtocolError.None, loc)
			return
		}
		testing.expect_value(t, terr, trans.TransportError.None, loc)
		testing.expect_value(t, perr, proto.ProtocolError.None, loc)
		proto.frame_destroy(&frame)
	}
}

wait_caller_idle :: proc(t: ^testing.T, fx: ^TestBroker, echo: ^EchoFixture, loc := #caller_location) {
	start := time.now()
	for time.since(start) < CLOSE_STORM_DRAIN {
		streams := brk.metrics_snapshot(&fx.server).active_relay_streams
		live := sync.atomic_load(&echo.live_conns)
		if streams == 0 && live == 0 {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, brk.metrics_snapshot(&fx.server).active_relay_streams, 0, loc)
	testing.expect_value(t, sync.atomic_load(&echo.live_conns), 0, loc)
}
