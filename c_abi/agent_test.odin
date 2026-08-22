package c_abi

import "core:testing"

@(test)
test_agent_create_rejects_insecure_with_tls_ca :: proc(t: ^testing.T) {
	cfg := ThirpAgentConfig {
		broker   = "127.0.0.1:1",
		token    = "x",
		insecure = 1,
		tls_ca   = "/tmp/x",
	}
	agent: ^CAgent
	err := thirp_agent_create(&cfg, &agent)
	testing.expect_value(t, err, ERR_INVALID_ARGUMENT)
	testing.expect(t, agent == nil)
}

@(test)
test_agent_create_rejects_nil_config :: proc(t: ^testing.T) {
	agent: ^CAgent
	testing.expect_value(t, thirp_agent_create(nil, &agent), ERR_INVALID_ARGUMENT)
}

@(test)
test_agent_register_echo_bytes_match :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)
	target_cs := endpoint_cstring(t, echo_ep)
	defer delete(target_cs)

	agent, broker_cs := must_create_agent(t, &fx)
	defer delete(broker_cs)
	defer thirp_agent_destroy(agent)
	must_register(t, agent, TEST_SERVICE, target_cs)

	caller, caller_cs := must_create_caller(t, &fx)
	defer delete(caller_cs)
	defer thirp_caller_destroy(caller)

	conn := must_dial(t, caller, TEST_SERVICE)
	defer thirp_conn_destroy(conn)
	echo_payload(t, conn, "hello")
}

@(test)
test_agent_stop_then_destroy :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	agent, broker_cs := must_create_agent(t, &fx)
	defer delete(broker_cs)
	thirp_agent_stop(agent)
	thirp_agent_destroy(agent)
}

@(test)
test_unregister_unknown_id_is_success :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	agent, broker_cs := must_create_agent(t, &fx)
	defer delete(broker_cs)
	defer thirp_agent_destroy(agent)
	testing.expect_value(t, thirp_unregister_service(agent, TEST_SERVICE), ERR_OK)
}

@(test)
test_unregister_drops_one_service_keeps_other :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)
	target_cs := endpoint_cstring(t, echo_ep)
	defer delete(target_cs)

	agent, broker_cs := must_create_agent(t, &fx)
	defer delete(broker_cs)
	defer thirp_agent_destroy(agent)
	must_register(t, agent, TEST_SERVICE, target_cs)
	must_register(t, agent, TEST_SERVICE_B, target_cs)

	caller, caller_cs := must_create_caller(t, &fx)
	defer delete(caller_cs)
	defer thirp_caller_destroy(caller)

	conn_b := must_dial(t, caller, TEST_SERVICE_B)
	defer thirp_conn_destroy(conn_b)

	testing.expect_value(t, thirp_unregister_service(agent, TEST_SERVICE), ERR_OK)
	wait_dial_error(t, caller, TEST_SERVICE, ERR_SERVICE_NOT_FOUND)

	echo_payload(t, conn_b, "keep")
}

@(test)
test_host_ephemeral_fills_hosting :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)
	target_cs := endpoint_cstring(t, echo_ep)
	defer delete(target_cs)

	agent, broker_cs := must_create_agent(t, &fx)
	defer delete(broker_cs)
	defer thirp_agent_destroy(agent)

	hosting: ThirpHosting
	testing.expect_value(t, thirp_host_ephemeral(agent, "game", target_cs, &hosting), ERR_OK)
	testing.expect(t, cstring(&hosting.service_id[0]) != nil)
	join := string(cstring(&hosting.join_code[0]))
	testing.expect_value(t, len(join), 8)
	sid := string(cstring(&hosting.service_id[0]))
	testing.expect(t, len(sid) > 0)
}
