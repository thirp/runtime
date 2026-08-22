package web_ingress

import cfg "../config"
import "core:testing"
import "core:time"

expect_issue_contains :: proc(t: ^testing.T, issues: []cfg.ValidationIssue, message: string) -> bool {
	for issue in issues {
		if issue.message == message {
			return true
		}
	}
	testing.expectf(t, false, "missing issue: %s", message)
	return false
}

settings_from_text :: proc(
	t: ^testing.T,
	text: string,
) -> (
	settings: IngressSettings,
	issues: [dynamic]cfg.ValidationIssue,
) {
	doc, err := cfg.parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, cfg.ConfigError.None)
	issues = make([dynamic]cfg.ValidationIssue)
	loaded, serr := settings_from_ini(doc, &issues)
	cfg.ini_document_destroy(&doc)
	testing.expect_value(t, serr, cfg.ConfigError.None)
	return loaded, issues
}

MINIMAL_TLS ::
	"listen = 127.0.0.1:8443\n" +
	"broker = 127.0.0.1:9000\n" +
	"token_file = /tmp/web-ingress.token\n" +
	"tls_cert = /tmp/cert.pem\n" +
	"tls_key = /tmp/key.pem\n" +
	"route = portfolio-k7m4x2.web.example.com=acme/site-17/portfolio-ui\n"

@(test)
test_validate_ingress_config_accepts_minimal_tls :: proc(t: ^testing.T) {
	settings, issues := settings_from_text(t, MINIMAL_TLS)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	config, err := validate_ingress_config(settings, &issues)
	testing.expect_value(t, err, IngressError.None)
	testing.expect_value(t, len(issues), 0)
	defer ingress_config_destroy(&config)
	testing.expect_value(t, config.listen, "127.0.0.1:8443")
	testing.expect_value(t, config.broker, "127.0.0.1:9000")
	testing.expect_value(t, len(config.routes), 1)
	testing.expect_value(t, string(config.routes[0].public_host), "portfolio-k7m4x2.web.example.com")
	testing.expect_value(t, string(config.routes[0].service_id), "acme/site-17/portfolio-ui")
	testing.expect_value(t, config.routes[0].mode, IngressMode.TerminateHttp)
	testing.expect_value(t, config.limits.max_connections, DEFAULT_MAX_CONNECTIONS)
	testing.expect_value(t, config.limits.max_connections_per_ip, DEFAULT_MAX_CONNECTIONS_PER_IP)
	testing.expect_value(t, config.limits.max_client_hello_bytes, DEFAULT_MAX_CLIENT_HELLO_BYTES)
	testing.expect_value(t, config.limits.client_hello_timeout, DEFAULT_CLIENT_HELLO_TIMEOUT_SECONDS * time.Second)
	testing.expect_value(t, config.limits.broker_dial_timeout, DEFAULT_BROKER_DIAL_TIMEOUT_SECONDS * time.Second)
	testing.expect_value(t, config.limits.idle_timeout, DEFAULT_IDLE_TIMEOUT_SECONDS * time.Second)
	testing.expect_value(t, config.shutdown_grace, DEFAULT_SHUTDOWN_GRACE_SECONDS * time.Second)
	testing.expect(t, !ingress_config_has_passthrough(config))
}

@(test)
test_validate_ingress_config_passthrough_only_does_not_require_cert :: proc(t: ^testing.T) {
	text :=
		"listen = 0.0.0.0:443\n" +
		"broker = broker.example.com:8443\n" +
		"token_file = /tmp/web-ingress.token\n" +
		"route = secure-k9p3.web.example.com=acme/site-17/secure-ui:tls_passthrough\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	config, err := validate_ingress_config(settings, &issues)
	testing.expect_value(t, err, IngressError.None)
	testing.expect_value(t, len(issues), 0)
	defer ingress_config_destroy(&config)
	testing.expect(t, ingress_config_has_passthrough(config))
	testing.expect_value(t, config.routes[0].mode, IngressMode.TlsPassthrough)
}

@(test)
test_validate_ingress_config_mixed_routes_require_cert :: proc(t: ^testing.T) {
	text :=
		"listen = 0.0.0.0:443\n" +
		"broker = 127.0.0.1:9000\n" +
		"token = dev-token\n" +
		"route = a.web.example.com=acme/a:http\n" +
		"route = b.web.example.com=acme/b:tls_passthrough\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "tls required unless insecure")
}

@(test)
test_validate_ingress_config_http_requires_tls_unless_insecure :: proc(t: ^testing.T) {
	text :=
		"listen = 127.0.0.1:8443\n" +
		"broker = 127.0.0.1:9000\n" +
		"token = dev-token\n" +
		"route = localhost=demo/echo\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "tls required unless insecure")
}

@(test)
test_validate_ingress_config_insecure_loopback_one_route :: proc(t: ^testing.T) {
	text :=
		"listen = 127.0.0.1:8443\n" +
		"broker = 127.0.0.1:9000\n" +
		"token = dev-token\n" +
		"insecure = true\n" +
		"insecure_broker = true\n" +
		"route = localhost=demo/echo\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	config, err := validate_ingress_config(settings, &issues)
	testing.expect_value(t, err, IngressError.None)
	testing.expect_value(t, len(issues), 0)
	defer ingress_config_destroy(&config)
	testing.expect(t, config.insecure)
	testing.expect(t, config.insecure_broker)
}

@(test)
test_validate_ingress_config_insecure_rejects_non_loopback :: proc(t: ^testing.T) {
	text :=
		"listen = 0.0.0.0:8443\n" +
		"broker = 127.0.0.1:9000\n" +
		"token = dev-token\n" +
		"insecure = true\n" +
		"route = localhost=demo/echo\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "insecure requires a loopback listen address")
}

@(test)
test_validate_ingress_config_insecure_rejects_two_routes :: proc(t: ^testing.T) {
	text :=
		"listen = 127.0.0.1:8443\n" +
		"broker = 127.0.0.1:9000\n" +
		"token = dev-token\n" +
		"insecure = true\n" +
		"route = a.example.com=demo/a\n" +
		"route = b.example.com=demo/b\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "insecure requires exactly one route")
}

@(test)
test_validate_ingress_config_rejects_duplicate_canonical_hosts :: proc(t: ^testing.T) {
	text :=
		MINIMAL_TLS +
		"route = PORTFOLIO-k7m4x2.web.example.com.=acme/site-17/other\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "duplicate route")
}

@(test)
test_validate_ingress_config_rejects_invalid_host_and_service :: proc(t: ^testing.T) {
	text :=
		"listen = 127.0.0.1:8443\n" +
		"broker = 127.0.0.1:9000\n" +
		"token = dev-token\n" +
		"insecure = true\n" +
		"route = *.example.com=demo echo:tcp\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "invalid public host")
	expect_issue_contains(t, issues[:], "invalid service id")
	expect_issue_contains(t, issues[:], "invalid mode")
}

@(test)
test_settings_from_ini_unknown_key_reports_line :: proc(t: ^testing.T) {
	text := MINIMAL_TLS + "not_a_key = yes\n"
	doc, err := cfg.parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, cfg.ConfigError.None)
	defer cfg.ini_document_destroy(&doc)
	issues := make([dynamic]cfg.ValidationIssue)
	defer cfg.issues_destroy(issues)
	settings, serr := settings_from_ini(doc, &issues)
	defer settings_destroy(&settings)
	testing.expect_value(t, serr, cfg.ConfigError.UnknownKey)
	testing.expect(t, len(issues) >= 1)
	testing.expect_value(t, issues[0].line, 7)
	testing.expect_value(t, issues[0].message, "unknown key")
}

@(test)
test_settings_from_ini_duplicate_listen_reports_line :: proc(t: ^testing.T) {
	text := MINIMAL_TLS + "listen = 127.0.0.1:9443\n"
	doc, err := cfg.parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, cfg.ConfigError.None)
	defer cfg.ini_document_destroy(&doc)
	issues := make([dynamic]cfg.ValidationIssue)
	defer cfg.issues_destroy(issues)
	settings, serr := settings_from_ini(doc, &issues)
	defer settings_destroy(&settings)
	testing.expect_value(t, serr, cfg.ConfigError.DuplicateKey)
	expect_issue_contains(t, issues[:], "duplicate key")
}

@(test)
test_settings_merge_flag_route_replaces_canonical_host :: proc(t: ^testing.T) {
	text :=
		MINIMAL_TLS +
		"route = other.example.com=acme/other:http\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	flags: IngressSettings
	settings_init(&flags)
	defer settings_destroy(&flags)
	testing.expect_value(
		t,
		cfg.append_sourced_string(
			&flags.routes,
			"PORTFOLIO-k7m4x2.web.example.com.=acme/site-17/replaced:http",
			0,
			"--route",
		),
		cfg.ConfigError.None,
	)
	merged, merr := settings_merge(settings, flags)
	testing.expect_value(t, merr, cfg.ConfigError.None)
	defer settings_destroy(&merged)
	config, verr := validate_ingress_config(merged, &issues)
	testing.expect_value(t, verr, IngressError.None)
	defer ingress_config_destroy(&config)
	testing.expect_value(t, len(config.routes), 2)
	replaced := false
	kept := false
	for route in config.routes {
		if string(route.public_host) == "portfolio-k7m4x2.web.example.com" {
			testing.expect_value(t, string(route.service_id), "acme/site-17/replaced")
			replaced = true
		}
		if string(route.public_host) == "other.example.com" {
			kept = true
		}
	}
	testing.expect(t, replaced)
	testing.expect(t, kept)
}

@(test)
test_validate_ingress_config_token_xor :: proc(t: ^testing.T) {
	neither :=
		"listen = 127.0.0.1:8443\n" +
		"broker = 127.0.0.1:9000\n" +
		"tls_cert = /tmp/cert.pem\n" +
		"tls_key = /tmp/key.pem\n" +
		"route = localhost=demo/echo\n"
	settings, issues := settings_from_text(t, neither)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "exactly one of token or token_file is required")

	both :=
		"listen = 127.0.0.1:8443\n" +
		"broker = 127.0.0.1:9000\n" +
		"tls_cert = /tmp/cert.pem\n" +
		"tls_key = /tmp/key.pem\n" +
		"route = localhost=demo/echo\n" +
		"token = a\n" +
		"token_file = /tmp/t\n"
	settings2, issues2 := settings_from_text(t, both)
	defer settings_destroy(&settings2)
	defer cfg.issues_destroy(issues2)
	_, err = validate_ingress_config(settings2, &issues2)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues2[:], "exactly one of token or token_file is required")
}

@(test)
test_validate_ingress_config_numeric_bounds :: proc(t: ^testing.T) {
	text :=
		MINIMAL_TLS +
		"max_connections = 0\n" +
		"idle_timeout = 0\n" +
		"client_hello_timeout = 0\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	count := 0
	for issue in issues {
		if issue.message == "invalid value" {
			count += 1
		}
	}
	testing.expect(t, count >= 2)
}

@(test)
test_validate_ingress_config_applies_numeric_overrides :: proc(t: ^testing.T) {
	text :=
		MINIMAL_TLS +
		"max_connections = 16\n" +
		"idle_timeout = 0\n" +
		"shutdown_grace = 5\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	config, err := validate_ingress_config(settings, &issues)
	testing.expect_value(t, err, IngressError.None)
	testing.expect_value(t, len(issues), 0)
	defer ingress_config_destroy(&config)
	testing.expect_value(t, config.limits.max_connections, 16)
	testing.expect_value(t, config.limits.idle_timeout, 0)
	testing.expect_value(t, config.shutdown_grace, 5 * time.Second)
}

@(test)
test_validate_ingress_config_missing_listen_and_bad_log_level :: proc(t: ^testing.T) {
	text :=
		"broker = 127.0.0.1:9000\n" +
		"token = dev-token\n" +
		"insecure = true\n" +
		"log_level = verbose\n" +
		"route = localhost=demo/echo\n"
	settings, issues := settings_from_text(t, text)
	defer settings_destroy(&settings)
	defer cfg.issues_destroy(issues)
	_, err := validate_ingress_config(settings, &issues)
	testing.expect(t, err != .None)
	expect_issue_contains(t, issues[:], "listen is required")
	expect_issue_contains(t, issues[:], "invalid log level")
}
