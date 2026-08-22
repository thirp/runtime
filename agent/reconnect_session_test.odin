package agent

import brk "../broker"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

auth_fail_logs: log.Capture
authz_fail_logs: log.Capture

auth_fail_sink :: proc(text: string) {
	log.capture_sink(&auth_fail_logs, text)
}

authz_fail_sink :: proc(text: string) {
	log.capture_sink(&authz_fail_logs, text)
}

@(test)
test_agent_reconnect_restores_registration :: proc(t: ^testing.T) {
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
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)
	_, found := brk.lookup_service(&fx.reg, sid)
	testing.expect(t, found)

	sync_close_live(&agent)

	dropped := time.now()
	for time.since(dropped) < 2 * time.Second {
		if !agent_is_connected(&agent) {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	start := time.now()
	for time.since(start) < 2 * time.Second {
		_, found = brk.lookup_service(&fx.reg, sid)
		if !found {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	wait_agent_connected(t, &agent)
	start = time.now()
	for time.since(start) < 2 * time.Second {
		_, found = brk.lookup_service(&fx.reg, sid)
		if found {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	_, found = brk.lookup_service(&fx.reg, sid)
	testing.expect(t, found)

	caller := dial_broker(t, &fx)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	stream := caller_connect_ok(t, caller, &decoder, TEST_SERVICE)
	payload := []u8{'r', 'e'}
	must_write(t, caller, .Data, payload, stream)
	got := must_read_opcode(t, caller, &decoder, .Data)
	testing.expect_value(t, string(got.payload), "re")
	proto.frame_destroy(&got)
}

sync_close_live :: proc(agent: ^Agent) {
	sync.mutex_lock(&agent.mutex)
	conn := agent.live_conn
	sync.mutex_unlock(&agent.mutex)
	if conn != nil {
		trans.connection_close(conn)
	}
}

wait_log_contains :: proc(t: ^testing.T, cap: ^log.Capture, needle: string, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		sync.mutex_lock(&cap.mutex)
		got := string(cap.text[:])
		found := strings.contains(got, needle)
		sync.mutex_unlock(&cap.mutex)
		if found {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, loc = loc)
}

@(test)
test_agent_auth_failed_logs_authentication :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	auth_fail_logs.text = make([dynamic]u8)
	defer delete(auth_fail_logs.text)

	logger: log.Logger
	log.logger_init(&logger, .Info, auth_fail_sink)

	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig {
				broker   = broker_endpoint(t, &fx),
				token    = "wrong-token",
				insecure = true,
				logger   = &logger,
			},
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
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}

	wait_log_contains(t, &auth_fail_logs, "\"event\":\"auth_failed\"")
	wait_log_contains(t, &auth_fail_logs, "\"reason\":\"authentication\"")
	testing.expect(t, !agent_is_connected(&agent))
}

@(test)
test_agent_register_unauthorized_logs_authorization :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	fx.server.policy_mode = .Production
	fx.server.may_register = nil
	fx.server.may_connect = nil

	authz_fail_logs.text = make([dynamic]u8)
	defer delete(authz_fail_logs.text)

	logger: log.Logger
	log.logger_init(&logger, .Info, authz_fail_sink)

	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig {
				broker   = broker_endpoint(t, &fx),
				token    = TEST_TOKEN_HOST,
				insecure = true,
				logger   = &logger,
			},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	sid := must_service(t, TEST_SERVICE)
	testing.expect_value(
		t,
		register_service(&agent, sid, LocalTarget{address = trans.loopback_endpoint(9)}),
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

	wait_log_contains(t, &authz_fail_logs, "\"reason\":\"authorization\"")
	testing.expect(t, !agent_is_connected(&agent))
	testing.expect(t, agent_has_service(&agent, sid))
}
