package agent

import trans "../transport"
import "core:testing"

@(test)
test_register_service_rejects_port_zero :: proc(t: ^testing.T) {
	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig{broker = trans.loopback_endpoint(1), token = TEST_TOKEN_HOST, insecure = true},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	err := register_service(&agent, must_service(t, TEST_SERVICE), LocalTarget{address = trans.loopback_endpoint(0)})
	testing.expect_value(t, err, AgentError.InvalidConfig)
}

@(test)
test_host_ephemeral_rejects_port_zero :: proc(t: ^testing.T) {
	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig{broker = trans.loopback_endpoint(1), token = TEST_TOKEN_HOST, insecure = true},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	_, err := host_ephemeral(&agent, EphemeralConfig{namespace = "game", local_address = trans.loopback_endpoint(0)})
	testing.expect_value(t, err, AgentError.InvalidConfig)
}

@(test)
test_agent_init_rejects_unreadable_tls_ca :: proc(t: ^testing.T) {
	agent: Agent
	err := agent_init(
		&agent,
		AgentConfig {
			broker          = trans.loopback_endpoint(1),
			token           = TEST_TOKEN_HOST,
			tls_ca          = "/no/such/thirp-ca-9f3a.pem",
			tls_server_name = "localhost",
		},
	)
	testing.expect_value(t, err, AgentError.InvalidConfig)
}
