package agent

import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:thread"

@(test)
test_agent_register_echo_bytes_match :: proc(t: ^testing.T) {
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

	caller := dial_broker(t, &fx)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	sid := caller_connect_ok(t, caller, &decoder, TEST_SERVICE)

	payload := []u8{'h', 'e', 'l', 'l', 'o'}
	must_write(t, caller, .Data, payload, sid)
	got := must_read_opcode(t, caller, &decoder, .Data)
	testing.expect_value(t, got.header.stream_id, sid)
	testing.expect_value(t, string(got.payload), "hello")
	proto.frame_destroy(&got)
}

@(test)
test_agent_stop_unblocks_run :: proc(t: ^testing.T) {
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
	agent_stop(&agent)
	thread.join(th)
	thread.destroy(th)
}
