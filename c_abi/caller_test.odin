package c_abi

import cl "../caller"
import "core:testing"

@(test)
test_caller_create_rejects_insecure_with_tls_ca :: proc(t: ^testing.T) {
	cfg := ThirpCallerConfig {
		broker   = "127.0.0.1:1",
		token    = "x",
		insecure = 1,
		tls_ca   = "/tmp/x",
	}
	caller: ^CCaller
	err := thirp_caller_create(&cfg, &caller)
	testing.expect_value(t, err, ERR_INVALID_ARGUMENT)
	testing.expect(t, caller == nil)
}

@(test)
test_dial_echo_bytes_match :: proc(t: ^testing.T) {
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
test_dial_unknown_service_not_found :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	caller, caller_cs := must_create_caller(t, &fx)
	defer delete(caller_cs)
	defer thirp_caller_destroy(caller)

	conn: ^cl.Conn
	err := thirp_dial(caller, TEST_SERVICE, &conn)
	testing.expect_value(t, err, ERR_SERVICE_NOT_FOUND)
	testing.expect(t, conn == nil)
}

@(test)
test_dial_join_code_round_trip :: proc(t: ^testing.T) {
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

	caller, caller_cs := must_create_caller(t, &fx)
	defer delete(caller_cs)
	defer thirp_caller_destroy(caller)

	conn: ^cl.Conn
	err := thirp_dial_join_code(caller, "game", cstring(&hosting.join_code[0]), &conn)
	testing.expect_value(t, err, ERR_OK)
	testing.expect(t, conn != nil)
	defer thirp_conn_destroy(conn)
	echo_payload(t, conn, "z")
}
