package logging

import "core:strings"
import "core:sync"
import "core:testing"

Capture :: struct {
	mutex: sync.Mutex,
	text:  [dynamic]u8,
}

capture_sink :: proc(c: ^Capture, text: string) {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	append(&c.text, ..transmute([]u8)text)
}

@(test)
test_log_event_includes_event_field :: proc(t: ^testing.T) {
	cap: Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)

	logger: Logger
	logger_init(&logger, .Info, proc(text: string) {
		// sink set below; this stub is replaced
		_ = text
	})
	context.user_ptr = &cap
	logger.sink = proc(text: string) {
		c := (^Capture)(context.user_ptr)
		capture_sink(c, text)
	}

	log_event(
		&logger,
		.Info,
		"session_authenticated",
		LogFields{principal_id = "host-a", organization_id = "acme"},
	)
	got := string(cap.text[:])
	testing.expect(t, strings.contains(got, "\"event\":\"session_authenticated\""))
	testing.expect(t, strings.contains(got, "\"principal_id\":\"host-a\""))
	testing.expect(t, strings.contains(got, "\"organization_id\":\"acme\""))
	log_event(&logger, .Info, "route_selected", LogFields{mode = "tls_passthrough"})
	got = string(cap.text[:])
	testing.expect(t, strings.contains(got, "\"mode\":\"tls_passthrough\""))
	testing.expect(t, strings.contains(got, "\"level\":\"info\""))
}

@(test)
test_log_opt_string_truncates_at_max_field :: proc(t: ^testing.T) {
	cap: Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)

	logger: Logger
	context.user_ptr = &cap
	logger_init(&logger, .Info, proc(text: string) {
		c := (^Capture)(context.user_ptr)
		capture_sink(c, text)
	})

	long: [MAX_LOG_FIELD + 40]u8
	for i in 0 ..< len(long) {
		long[i] = 'a'
	}
	log_event(&logger, .Info, "connect_failed", LogFields{reason = string(long[:])})
	got := string(cap.text[:])
	testing.expect(t, strings.contains(got, "\"event\":\"connect_failed\""))
	testing.expect(t, !strings.contains(got, string(long[:])))
	clipped := string(long[:MAX_LOG_FIELD])
	testing.expect(t, strings.contains(got, clipped))
	log_event(&logger, .Warn, "auth_failed", LogFields{reason = "a\"b"})
	got = string(cap.text[:])
	testing.expect(t, strings.contains(got, "\\\"b\""))
}

@(test)
test_log_auth_failed_does_not_emit_token :: proc(t: ^testing.T) {
	cap: Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)

	logger: Logger
	context.user_ptr = &cap
	logger_init(&logger, .Info, proc(text: string) {
		c := (^Capture)(context.user_ptr)
		capture_sink(c, text)
	})

	log_event(
		&logger,
		.Warn,
		"auth_failed",
		LogFields{remote_address = "127.0.0.1:9", error_code = "AUTHENTICATION_FAILED"},
	)
	got := string(cap.text[:])
	testing.expect(t, strings.contains(got, "\"event\":\"auth_failed\""))
	testing.expect(t, !strings.contains(got, "token"))
	testing.expect(t, !strings.contains(got, "host-dev-token"))
}

@(test)
test_log_session_authenticated_emits_label_not_token :: proc(t: ^testing.T) {
	cap: Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)

	logger: Logger
	context.user_ptr = &cap
	logger_init(&logger, .Info, proc(text: string) {
		c := (^Capture)(context.user_ptr)
		capture_sink(c, text)
	})

	log_event(
		&logger,
		.Info,
		"session_authenticated",
		LogFields{principal_id = "host-a", credential_label = "site-17-agent"},
	)
	got := string(cap.text[:])
	testing.expect(t, strings.contains(got, "\"event\":\"session_authenticated\""))
	testing.expect(t, strings.contains(got, "\"credential_label\":\"site-17-agent\""))
	testing.expect(t, !strings.contains(got, "host-dev-token"))
}

@(test)
test_log_below_min_level_is_silent :: proc(t: ^testing.T) {
	cap: Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)

	logger: Logger
	context.user_ptr = &cap
	logger_init(&logger, .Error, proc(text: string) {
		c := (^Capture)(context.user_ptr)
		capture_sink(c, text)
	})
	log_event(&logger, .Info, "session_authenticated")
	testing.expect_value(t, len(cap.text), 0)
}

@(test)
test_log_level_from_string :: proc(t: ^testing.T) {
	level, ok := log_level_from_string("debug")
	testing.expect(t, ok)
	testing.expect_value(t, level, LogLevel.Debug)
	_, bad := log_level_from_string("trace")
	testing.expect(t, !bad)
}

@(test)
test_log_nil_logger_is_silent :: proc(t: ^testing.T) {
	log_event(nil, .Error, "protocol_error")
}
