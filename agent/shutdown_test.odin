package agent

import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_agent_stop_unregisters_before_exit :: proc(t: ^testing.T) {
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
	sid := must_service(t, TEST_SERVICE)
	testing.expect_value(t, register_service(&agent, sid, LocalTarget{address = echo_ep}), AgentError.None)

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	wait_agent_connected(t, &agent)
	_, found := brk.lookup_service(&fx.reg, sid)
	testing.expect(t, found)

	peer := dial_broker(t, &fx)
	defer trans.connection_destroy(peer)
	decoder: proto.FrameDecoder
	handshake_caller(t, peer, &decoder)
	defer proto.decoder_destroy(&decoder)
	stream := caller_connect_ok(t, peer, &decoder, TEST_SERVICE)

	before := sync.atomic_load(&fx.server.metrics.unregistrations_total)
	agent_stop(&agent)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, stream_ended(t, peer, &decoder, stream))

	wait_lookup(t, &fx.reg, sid, false)
	after := sync.atomic_load(&fx.server.metrics.unregistrations_total)
	testing.expect(t, after > before)
	testing.expect(t, !agent_is_connected(&agent))
	testing.expect(t, agent_has_service(&agent, sid))
}

@(test)
test_agent_stop_returns_when_broker_already_gone :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

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
		register_service(&agent, must_service(t, TEST_SERVICE), LocalTarget{address = trans.loopback_endpoint(9)}),
		AgentError.None,
	)

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	wait_agent_connected(t, &agent)

	sync_close_live(&agent)
	agent_stop(&agent)
	thread.join(th)
	thread.destroy(th)
}

stream_ended :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	stream: proto.StreamId,
	loc := #caller_location,
) -> bool {
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
	start := time.now()
	for time.since(start) < 2 * time.Second {
		frame, terr, perr := trans.read_frame(conn, decoder)
		if terr != .None || perr != .None {
			return true
		}
		op := frame.header.opcode
		sid := frame.header.stream_id
		proto.frame_destroy(&frame)
		if sid == stream && (op == .Reset || op == .Close) {
			return true
		}
	}
	testing.expect(t, false, loc = loc)
	return false
}

@(test)
test_agent_local_dial_failure_keeps_session_and_sibling :: proc(t: ^testing.T) {
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
	sid_down := must_service(t, "demo/down")
	sid_ok := must_service(t, TEST_SERVICE)
	testing.expect_value(
		t,
		register_service(&agent, sid_down, LocalTarget{address = trans.loopback_endpoint(1)}),
		AgentError.None,
	)
	testing.expect_value(t, register_service(&agent, sid_ok, LocalTarget{address = echo_ep}), AgentError.None)

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)

	expect_connect_failed(t, &fx, "demo/down", proto.WireError.LocalServiceUnavailable)
	testing.expect(t, agent_is_connected(&agent))
	echo_via_service(t, &fx, TEST_SERVICE, []u8{'s', 'i'})
}
