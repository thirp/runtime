package caller

import ag "../agent"
import "core:testing"
import "core:thread"

@(test)
test_dial_echo_bytes_match :: proc(t: ^testing.T) {
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

	conn, derr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, derr, CallerError.None)
	testing.expect(t, conn != nil)
	defer conn_destroy(conn)

	payload := []u8{'h', 'e', 'l', 'l', 'o'}
	n, werr := conn_write(conn, payload)
	testing.expect_value(t, werr, ConnError.None)
	testing.expect_value(t, n, 5)

	buf: [16]u8
	rn, rerr := conn_read(conn, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:rn]), "hello")
}

@(test)
test_dial_unknown_service_not_found :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

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

	conn, derr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, derr, CallerError.ServiceNotFound)
	testing.expect(t, conn == nil)
}

@(test)
test_dial_second_stream_on_same_caller :: proc(t: ^testing.T) {
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

	a, aerr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, aerr, CallerError.None)
	defer conn_destroy(a)
	b, berr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, berr, CallerError.None)
	defer conn_destroy(b)

	_, werr := conn_write(a, []u8{'a'})
	testing.expect_value(t, werr, ConnError.None)
	_, werr = conn_write(b, []u8{'b'})
	testing.expect_value(t, werr, ConnError.None)

	buf: [8]u8
	n, rerr := conn_read(a, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:n]), "a")
	n, rerr = conn_read(b, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:n]), "b")
}

@(test)
test_dial_join_code_round_trip :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: ag.Agent
	testing.expect_value(
		t,
		ag.agent_init(
			&agent,
			ag.AgentConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_HOST, insecure = true},
		),
		ag.AgentError.None,
	)
	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer stop_agent(&agent, th)
	wait_agent_connected(t, &agent)

	hosting, herr := ag.host_ephemeral(
		&agent,
		ag.EphemeralConfig{namespace = "game", local_address = echo_ep},
	)
	testing.expect_value(t, herr, ag.AgentError.None)
	defer ag.hosting_destroy(&hosting)

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

	conn, derr := dial_join_code(&c, "game", hosting.join_code)
	testing.expect_value(t, derr, CallerError.None)
	testing.expect(t, conn != nil)
	defer conn_destroy(conn)

	_, werr := conn_write(conn, []u8{'z'})
	testing.expect_value(t, werr, ConnError.None)
	buf: [8]u8
	n, rerr := conn_read(conn, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:n]), "z")
}
