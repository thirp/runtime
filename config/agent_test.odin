package config

import "core:testing"

@(test)
test_agent_example_conf_has_two_maps :: proc(t: ^testing.T) {
	path := EXAMPLES_DIR + "agent.conf"
	doc, err := parse_ini_file(path)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := agent_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer agent_settings_destroy(&settings)
	verr := agent_settings_validate(settings, &issues)
	testing.expect_value(t, verr, ConfigError.None)
	testing.expect_value(t, len(issues), 0)
	testing.expect_value(t, len(settings.maps), 2)
	testing.expect_value(t, settings.maps[0].value, "acme/site-17/reporting-api=127.0.0.1:7000")
	testing.expect_value(t, settings.maps[1].value, "acme/site-17/inventory=127.0.0.1:7001")
}

@(test)
test_agent_duplicate_service_id_fails :: proc(t: ^testing.T) {
	text :=
		"broker = 127.0.0.1:9000\ntoken_file = /tmp/agent.token\nmap = demo/echo=127.0.0.1:7000\nmap = demo/echo=127.0.0.1:7001\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := agent_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer agent_settings_destroy(&settings)
	verr := agent_settings_validate(settings, &issues)
	testing.expect(t, verr != .None)
	expect_issue_contains(t, issues[:], "duplicate service id")
}

@(test)
test_agent_port_zero_target_fails :: proc(t: ^testing.T) {
	text := "broker = 127.0.0.1:9000\ntoken_file = /tmp/agent.token\nmap = demo/echo=127.0.0.1:0\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := agent_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer agent_settings_destroy(&settings)
	verr := agent_settings_validate(settings, &issues)
	testing.expect(t, verr != .None)
	expect_issue_contains(t, issues[:], "invalid target address")
}

@(test)
test_agent_map_flag_adds_and_overrides :: proc(t: ^testing.T) {
	text :=
		"broker = 127.0.0.1:9000\ntoken_file = /tmp/agent.token\nmap = demo/echo=127.0.0.1:7000\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	file, ferr := agent_settings_from_ini(doc, &issues)
	testing.expect_value(t, ferr, ConfigError.None)
	defer agent_settings_destroy(&file)
	flags: AgentSettings
	agent_settings_init(&flags)
	defer agent_settings_destroy(&flags)
	testing.expect_value(
		t,
		append_sourced_string(&flags.maps, "demo/echo=127.0.0.1:7002", 0, "--map"),
		ConfigError.None,
	)
	testing.expect_value(
		t,
		append_sourced_string(&flags.maps, "demo/other=127.0.0.1:7001", 0, "--map"),
		ConfigError.None,
	)
	merged, merr := settings_merge_agent(file, flags)
	testing.expect_value(t, merr, ConfigError.None)
	defer agent_settings_destroy(&merged)
	testing.expect_value(t, len(merged.maps), 2)
	testing.expect_value(t, merged.maps[0].value, "demo/echo=127.0.0.1:7002")
	testing.expect_value(t, merged.maps[1].value, "demo/other=127.0.0.1:7001")
	verr := agent_settings_validate(merged, &issues)
	testing.expect_value(t, verr, ConfigError.None)
}

@(test)
test_production_examples_acceptance_shape :: proc(t: ^testing.T) {
	broker_path := EXAMPLES_DIR + "broker.conf"
	doc, err := parse_ini_file(broker_path)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	broker_settings, berr := broker_settings_from_ini(doc, &issues)
	testing.expect_value(t, berr, ConfigError.None)
	defer broker_settings_destroy(&broker_settings)
	testing.expect_value(t, broker_settings_validate(broker_settings, &issues), ConfigError.None)
	testing.expect_value(t, broker_settings.policy_mode.value, "production")
	testing.expect_value(t, len(broker_settings.allow_register), 1)
	testing.expect(t, broker_settings.allow_register[0].value == "agent-site-17=acme/site-17/*")
	testing.expect_value(t, len(broker_settings.allow_connect), 2)
	testing.expect(t, broker_settings.allow_connect[0].value == "reporting-client=acme/site-17/reporting-api")
	testing.expect(t, broker_settings.allow_connect[1].value == "web-ingress-a=acme/site-17/portfolio-ui")

	agent_path := EXAMPLES_DIR + "agent.conf"
	adoc, aerr := parse_ini_file(agent_path)
	testing.expect_value(t, aerr, ConfigError.None)
	defer ini_document_destroy(&adoc)
	agent_settings, serr := agent_settings_from_ini(adoc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer agent_settings_destroy(&agent_settings)
	testing.expect_value(t, agent_settings_validate(agent_settings, &issues), ConfigError.None)
	testing.expect_value(t, len(agent_settings.maps), 2)
	has_reporting := false
	has_inventory := false
	for m in agent_settings.maps {
		if m.value == "acme/site-17/reporting-api=127.0.0.1:7000" {
			has_reporting = true
		}
		if m.value == "acme/site-17/inventory=127.0.0.1:7001" {
			has_inventory = true
		}
	}
	testing.expect(t, has_reporting)
	testing.expect(t, has_inventory)
}
