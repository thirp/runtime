package config

import auth "../auth"
import "core:os"
import "core:testing"

@(test)
test_broker_example_conf_validates :: proc(t: ^testing.T) {
	path := EXAMPLES_DIR + "broker.conf"
	doc, err := parse_ini_file(path)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := broker_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer broker_settings_destroy(&settings)
	verr := broker_settings_validate(settings, &issues)
	testing.expect_value(t, verr, ConfigError.None)
	testing.expect_value(t, len(issues), 0)
	testing.expect(t, settings.policy_mode.set)
	testing.expect_value(t, settings.policy_mode.value, "production")
	testing.expect_value(t, len(settings.allow_register), 1)
	testing.expect_value(t, settings.allow_register[0].value, "agent-site-17=acme/site-17/*")
	testing.expect_value(t, len(settings.allow_connect), 2)
	testing.expect_value(t, settings.allow_connect[0].value, "reporting-client=acme/site-17/reporting-api")
	testing.expect_value(t, settings.allow_connect[1].value, "web-ingress-a=acme/site-17/portfolio-ui")
	testing.expect_value(t, len(settings.org_namespace), 1)
}

@(test)
test_broker_flags_override_file_listen :: proc(t: ^testing.T) {
	text := "listen = 127.0.0.1:9000\ninsecure = true\ntoken = host-dev-token=host-a\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	file, ferr := broker_settings_from_ini(doc, &issues)
	testing.expect_value(t, ferr, ConfigError.None)
	defer broker_settings_destroy(&file)
	flags: BrokerSettings
	broker_settings_init(&flags)
	defer broker_settings_destroy(&flags)
	testing.expect_value(t, assign_sourced_string(&flags.listen, "127.0.0.1:9443", 0, "--listen"), ConfigError.None)
	merged, merr := settings_merge_broker(file, flags)
	testing.expect_value(t, merr, ConfigError.None)
	defer broker_settings_destroy(&merged)
	testing.expect_value(t, merged.listen.value, "127.0.0.1:9443")
	testing.expect_value(t, merged.listen.flag, "--listen")
}

@(test)
test_broker_production_plus_insecure_rejected :: proc(t: ^testing.T) {
	text := "listen = 127.0.0.1:9000\npolicy_mode = production\ninsecure = true\ntoken = host-dev-token=host-a\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := broker_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer broker_settings_destroy(&settings)
	verr := broker_settings_validate(settings, &issues)
	testing.expect_value(t, verr, ConfigError.InsecureProduction)
	expect_issue_contains(t, issues[:], "production mode cannot enable insecure")
}

@(test)
test_broker_malformed_allow_register_is_not_allow_all :: proc(t: ^testing.T) {
	text :=
		"listen = 127.0.0.1:9000\ninsecure = true\ntoken = host-dev-token=host-a\nallow_register = not-a-grant\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := broker_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer broker_settings_destroy(&settings)
	verr := broker_settings_validate(settings, &issues)
	testing.expect(t, verr != .None)
	expect_issue_contains(t, issues[:], "invalid grant")
	testing.expect_value(t, len(settings.allow_register), 1)
}

@(test)
test_broker_missing_tls_without_insecure_fails :: proc(t: ^testing.T) {
	text := "listen = 127.0.0.1:9000\ntoken = host-dev-token=host-a\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := broker_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer broker_settings_destroy(&settings)
	verr := broker_settings_validate(settings, &issues)
	testing.expect(t, verr != .None)
	expect_issue_contains(t, issues[:], "tls required unless insecure")
}

@(test)
test_broker_collect_all_bad_listen_and_log_level :: proc(t: ^testing.T) {
	text := "listen = not-an-endpoint\nlog_level = verbose\ninsecure = true\ntoken = host-dev-token=host-a\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := broker_settings_from_ini(doc, &issues)
	testing.expect_value(t, serr, ConfigError.None)
	defer broker_settings_destroy(&settings)
	_ = broker_settings_validate(settings, &issues)
	expect_issue_contains(t, issues[:], "invalid address")
	expect_issue_contains(t, issues[:], "invalid log level")
}

@(test)
test_broker_example_tokens_are_least_privilege :: proc(t: ^testing.T) {
	path := EXAMPLES_DIR + "broker.tokens"
	testing.expect(t, os.exists(path))
	loaded, err := auth.load_credential_file(path)
	testing.expect_value(t, err, auth.AuthError.None)
	defer auth.credential_specs_destroy(loaded)
	testing.expect_value(t, len(loaded), 3)
	register_only := false
	connect_only := false
	ingress_only := false
	for spec in loaded {
		if spec.principal_id == "agent-site-17" {
			testing.expect(t, .RegisterService in spec.capabilities)
			testing.expect(t, .ConnectService not_in spec.capabilities)
			register_only = true
		}
		if spec.principal_id == "reporting-client" {
			testing.expect(t, .ConnectService in spec.capabilities)
			testing.expect(t, .RegisterService not_in spec.capabilities)
			connect_only = true
		}
		if spec.principal_id == "web-ingress-a" {
			testing.expect(t, .ConnectService in spec.capabilities)
			testing.expect(t, .RegisterService not_in spec.capabilities)
			ingress_only = true
		}
	}
	testing.expect(t, register_only)
	testing.expect(t, connect_only)
	testing.expect(t, ingress_only)
}
