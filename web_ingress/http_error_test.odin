package web_ingress

import "core:strings"
import "core:testing"

@(test)
test_http_error_format_is_fixed_and_closes :: proc(t: ^testing.T) {
	text := format_http_error(http_status_misdirected())
	defer delete(text)
	testing.expect(t, strings.has_prefix(text, "HTTP/1.1 421 Misdirected Request\r\n"))
	testing.expect(t, strings.contains(text, "Connection: close\r\n"))
	testing.expect(t, strings.contains(text, "Content-Type: text/plain; charset=utf-8\r\n"))
	testing.expect(t, strings.has_suffix(text, "\r\n\r\nMisdirected Request\n"))
	testing.expect(t, !strings.contains(text, "demo/echo"))
	testing.expect(t, !strings.contains(text, "token"))
}

@(test)
test_http_status_for_caller_error_table :: proc(t: ^testing.T) {
	testing.expect_value(t, http_status_for_caller_error(.Unauthorized).code, 403)
	testing.expect_value(t, http_status_for_caller_error(.RateLimited).code, 429)
	testing.expect_value(t, http_status_for_caller_error(.BrokerDraining).code, 503)
	testing.expect_value(t, http_status_for_caller_error(.ServiceNotFound).code, 503)
	testing.expect_value(t, http_status_for_caller_error(.AgentUnavailable).code, 503)
	testing.expect_value(t, http_status_for_caller_error(.LocalServiceUnavailable).code, 503)
	testing.expect_value(t, http_status_for_caller_error(.QuotaExceeded).code, 503)
	testing.expect_value(t, http_status_for_caller_error(.Transport).code, 502)
	testing.expect_value(t, http_status_for_caller_error(.Closed).code, 502)
	testing.expect_value(t, http_status_for_caller_error(.Timeout).code, 502)
	testing.expect_value(t, http_status_for_caller_error(.Internal).code, 502)
	testing.expect_value(t, http_status_for_caller_error(.AuthFailed).code, 502)
}

@(test)
test_http_status_for_ingress_error_table :: proc(t: ^testing.T) {
	testing.expect_value(t, http_status_for_ingress_error(.UnknownRoute).code, 421)
	testing.expect_value(t, http_status_for_ingress_error(.MissingSni).code, 421)
	testing.expect_value(t, http_status_for_ingress_error(.InvalidPublicHost).code, 421)
	testing.expect_value(t, http_status_for_ingress_error(.BrokerUnauthorized).code, 403)
	testing.expect_value(t, http_status_for_ingress_error(.RateLimited).code, 429)
	testing.expect_value(t, http_status_for_ingress_error(.ServiceUnavailable).code, 503)
	testing.expect_value(t, http_status_for_ingress_error(.Draining).code, 503)
	testing.expect_value(t, http_status_for_ingress_error(.BrokerUnavailable).code, 502)
	testing.expect_value(t, http_status_for_ingress_error(.DialTimeout).code, 502)
	testing.expect_value(t, http_status_for_ingress_error(.ConnectionIdle).code, 502)
}
