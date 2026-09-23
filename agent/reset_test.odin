package agent

import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Field repro after broker PR #3: N=64 (prod N=256) burst, then idle 60s.
// `thirp_resets_total{reason=stream_not_found}` must stay flat. A 288k/s
// loop is visible in milliseconds; the unit idle is short on purpose.
RESET_STORM_BURST :: 64
RESET_STORM_IDLE :: 250 * time.Millisecond
RESET_STORM_DRAIN :: 2 * time.Second

@(test)
test_agent_unknown_data_does_not_reset :: proc(t: ^testing.T) {
	pipe := open_relay_pipe(t)
	defer close_relay_pipe(&pipe)

	relay: AgentRelay
	relay.broker = pipe.broker
	relay.streams = make(map[proto.StreamId]AgentLocalStream)
	defer delete(relay.streams)

	sid := proto.make_stream_id(99)
	agent_handle_data(&relay, make_stream_frame(.Data, sid, []u8{'x'}))
	agent_handle_half_close(&relay, make_stream_frame(.HalfClose, sid, nil))
	agent_reset_owned_stream(&relay, sid, .InternalError)
	expect_no_broker_frame(t, pipe.peer)
}

@(test)
test_agent_finished_stream_data_does_not_reset :: proc(t: ^testing.T) {
	pipe := open_relay_pipe(t)
	defer close_relay_pipe(&pipe)
	local := open_relay_pipe(t)
	defer close_relay_pipe(&local)

	relay: AgentRelay
	relay.broker = pipe.broker
	relay.streams = make(map[proto.StreamId]AgentLocalStream)
	defer delete(relay.streams)

	sid := proto.make_stream_id(7)
	relay.streams[sid] = AgentLocalStream {
		local              = local.broker,
		broker_half_closed = false,
		closed             = false,
	}
	local.broker = nil

	agent_finish_stream(&relay, sid)
	_, found := relay.streams[sid]
	testing.expect(t, !found)
	testing.expect_value(t, sync.atomic_load(&relay.live_pumps), 0)

	agent_handle_data(&relay, make_stream_frame(.Data, sid, []u8{'y'}))
	agent_handle_half_close(&relay, make_stream_frame(.HalfClose, sid, nil))
	agent_finish_stream(&relay, sid)
	agent_reset_owned_stream(&relay, sid, .InternalError)
	expect_no_broker_frame(t, pipe.peer)

	_ = trans.connection_set_recv_timeout(local.peer, 200 * time.Millisecond)
	buf: [8]u8
	_, rerr := trans.connection_read(local.peer, buf[:])
	testing.expect_value(t, rerr, trans.TransportError.Closed)
}

@(test)
test_agent_burst_then_idle_stream_not_found_stays_flat :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_HOST, insecure = true},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	testing.expect_value(
		t,
		register_service(&agent, must_service(t, TEST_SERVICE), LocalTarget{address = echo_ep}),
		AgentError.None,
	)

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)

	payload := []u8{'b', 'u', 'r', 's', 't'}
	for _ in 0 ..< RESET_STORM_BURST {
		echo_via_service(t, &fx, TEST_SERVICE, payload)
	}

	wait_relay_streams_idle(t, &fx)
	base := brk.metrics_snapshot(&fx.server).resets[.StreamNotFound]
	idle_start := time.now()
	for time.since(idle_start) < RESET_STORM_IDLE {
		time.sleep(50 * time.Millisecond)
		got := brk.metrics_snapshot(&fx.server).resets[.StreamNotFound]
		testing.expect_value(t, got, base)
	}
	testing.expect(t, agent_is_connected(&agent))
	echo_via_service(t, &fx, TEST_SERVICE, []u8{'o', 'k'})
	testing.expect_value(
		t,
		brk.metrics_snapshot(&fx.server).resets[.StreamNotFound],
		base,
	)
}

RelayPipe :: struct {
	ln:     trans.Listener,
	broker: ^trans.Connection,
	peer:   ^trans.Connection,
}

open_relay_pipe :: proc(t: ^testing.T, loc := #caller_location) -> RelayPipe {
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	ep, eerr := trans.listener_endpoint(ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	broker, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None, loc)
	peer, aerr := trans.listener_accept(&ln)
	testing.expect_value(t, aerr, trans.TransportError.None, loc)
	return RelayPipe{ln = ln, broker = broker, peer = peer}
}

close_relay_pipe :: proc(p: ^RelayPipe) {
	if p.broker != nil {
		trans.connection_destroy(p.broker)
		p.broker = nil
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

expect_no_broker_frame :: proc(t: ^testing.T, peer: ^trans.Connection, loc := #caller_location) {
	_ = trans.connection_set_recv_timeout(peer, 50 * time.Millisecond)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None, loc)
	defer proto.decoder_destroy(&decoder)
	frame, terr, perr := trans.read_frame(peer, &decoder)
	testing.expect_value(t, terr, trans.TransportError.Timeout, loc)
	testing.expect_value(t, perr, proto.ProtocolError.None, loc)
	proto.frame_destroy(&frame)
}

wait_relay_streams_idle :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) {
	start := time.now()
	for time.since(start) < RESET_STORM_DRAIN {
		if brk.metrics_snapshot(&fx.server).active_relay_streams == 0 {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, brk.metrics_snapshot(&fx.server).active_relay_streams, 0, loc)
}

