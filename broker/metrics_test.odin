package broker

import auth "../auth"
import trans "../transport"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

prom_reason :: proc(metric, value: string, n := "") -> string {
	if len(n) == 0 {
		return fmt.tprintf("%s{{reason=\"%s\"}}", metric, value)
	}
	return fmt.tprintf("%s{{reason=\"%s\"}} %s", metric, value, n)
}

prom_limit :: proc(metric, value: string, n := "") -> string {
	if len(n) == 0 {
		return fmt.tprintf("%s{{limit=\"%s\"}}", metric, value)
	}
	return fmt.tprintf("%s{{limit=\"%s\"}} %s", metric, value, n)
}

@(test)
test_metrics_prometheus_includes_spec_names :: proc(t: ^testing.T) {
	m: Metrics
	metrics_inc(&m.registrations_total)
	metrics_inc(&m.unregistrations_total)
	metrics_inc(&m.connection_attempts_total)
	metrics_inc(&m.connection_success_total)
	metrics_inc_connect_failure(&m, .ServiceNotFound)
	metrics_inc(&m.protocol_errors_total)
	metrics_inc(&m.authentication_failures_total)
	metrics_inc_authz(&m, .Capability)
	metrics_inc_register_failure(&m, .Namespace)
	metrics_inc_role_violation(&m)
	metrics_inc(&m.session_timeouts_total)
	metrics_inc_reset(&m, .StreamBuffer)
	metrics_inc_limit(&m, .PhysicalConnections)
	metrics_observe(&m, .ConnectOk, 40 * time.Millisecond)

	snap := metrics_snapshot_counters(&m)
	text := metrics_write_prometheus(snap)
	defer delete(text)

	testing.expect(t, strings.contains(text, "thirp_active_physical_connections"))
	testing.expect(t, strings.contains(text, "thirp_active_agent_sessions"))
	testing.expect(t, strings.contains(text, "thirp_active_caller_connections"))
	testing.expect(t, strings.contains(text, "thirp_registered_services"))
	testing.expect(t, strings.contains(text, "thirp_active_relay_streams"))
	testing.expect(t, strings.contains(text, "thirp_registrations_total 1"))
	testing.expect(t, strings.contains(text, "thirp_unregistrations_total 1"))
	testing.expect(t, strings.contains(text, "thirp_connection_attempts_total 1"))
	testing.expect(t, strings.contains(text, "thirp_connection_success_total 1"))
	testing.expect(t, strings.contains(text, prom_reason("thirp_connection_failure_total", LABEL_SERVICE_NOT_FOUND, "1")))
	testing.expect(t, strings.contains(text, "thirp_bytes_agent_to_caller_total"))
	testing.expect(t, strings.contains(text, "thirp_bytes_caller_to_agent_total"))
	testing.expect(t, strings.contains(text, "thirp_protocol_errors_total 2"))
	testing.expect(t, strings.contains(text, "thirp_authentication_failures_total 1"))
	testing.expect(t, strings.contains(text, prom_reason("thirp_authorization_failures_total", LABEL_CAPABILITY, "1")))
	testing.expect(t, strings.contains(text, prom_reason("thirp_registration_failures_total", LABEL_NAMESPACE, "1")))
	testing.expect(t, strings.contains(text, "thirp_role_violations_total 1"))
	testing.expect(t, strings.contains(text, "thirp_session_timeouts_total 1"))
	testing.expect(t, strings.contains(text, prom_limit("thirp_rate_limit_exceeds_total", LABEL_AUTHENTICATION, "0")))
	testing.expect(t, strings.contains(text, prom_reason("thirp_connection_failure_total", LABEL_RATE_LIMITED, "0")))
	testing.expect(t, strings.contains(text, prom_reason("thirp_registration_failures_total", LABEL_RATE_LIMITED, "0")))
	testing.expect(t, strings.contains(text, prom_reason("thirp_unregistration_failures_total", LABEL_RATE_LIMITED, "0")))
	testing.expect(t, strings.contains(text, prom_limit("thirp_limit_exceeds_total", LABEL_GLOBAL_BUFFER, "0")))
	testing.expect(t, strings.contains(text, prom_limit("thirp_limit_exceeds_total", LABEL_FILE_DESCRIPTORS, "0")))
	testing.expect(t, strings.contains(text, prom_reason("thirp_resets_total", LABEL_STREAM_IDLE, "0")))
	testing.expect(t, strings.contains(text, prom_reason("thirp_resets_total", LABEL_STREAM_BUFFER, "1")))
	testing.expect(t, strings.contains(text, prom_limit("thirp_limit_exceeds_total", LABEL_PHYSICAL_CONNECTIONS, "1")))
	testing.expect(t, strings.contains(text, "thirp_connect_ok_seconds_bucket{le=\"0.05\"}"))
	testing.expect(t, strings.contains(text, "thirp_connect_ok_seconds_count 1"))
	testing.expect(t, !strings.contains(text, "rendez_"))
}

@(test)
test_metrics_observe_fills_cumulative_buckets :: proc(t: ^testing.T) {
	m: Metrics
	metrics_observe(&m, .Authentication, 40 * time.Millisecond)
	h := metrics_copy_histogram(&m.latency[.Authentication])
	testing.expect_value(t, h.count, u64(1))
	testing.expect_value(t, h.buckets[0], u64(0)) // 0.001s
	testing.expect_value(t, h.buckets[3], u64(0)) // 0.025s
	testing.expect_value(t, h.buckets[4], u64(1)) // 0.05s
	testing.expect_value(t, h.buckets[HISTOGRAM_BUCKET_COUNT - 1], u64(1))
}

@(test)
test_metrics_bytes_direction :: proc(t: ^testing.T) {
	m: Metrics
	metrics_add_bytes(&m, .Agent, 10)
	metrics_add_bytes(&m, .Caller, 7)
	snap := metrics_snapshot_counters(&m)
	testing.expect_value(t, snap.bytes_agent_to_caller_total, u64(10))
	testing.expect_value(t, snap.bytes_caller_to_agent_total, u64(7))
}

@(test)
test_metrics_http_scrape_includes_counters :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, server_metrics_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_metrics_start(&server)
	ep, eerr := server_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	conn, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)

	req := "GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
	testing.expect_value(t, trans.connection_write(conn, transmute([]u8)req), trans.TransportError.None)

	buf: [8192]u8
	n := 0
	for n < len(buf) {
		got, rerr := trans.connection_read(conn, buf[n:])
		if rerr != .None || got == 0 {
			break
		}
		n += got
		if strings.contains(string(buf[:n]), "thirp_resets_total") {
			break
		}
	}
	body := string(buf[:n])
	testing.expect(t, strings.contains(body, "HTTP/1.1 200 OK"))
	testing.expect(t, strings.contains(body, "thirp_active_physical_connections"))
	testing.expect(t, strings.contains(body, prom_reason("thirp_resets_total", LABEL_STREAM_BUFFER)))
	testing.expect(t, strings.contains(body, prom_limit("thirp_limit_exceeds_total", LABEL_PHYSICAL_CONNECTIONS)))
}

@(test)
test_metrics_http_unknown_path_is_404 :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, server_metrics_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_metrics_start(&server)
	ep, eerr := server_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	conn, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
	req := "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
	testing.expect_value(t, trans.connection_write(conn, transmute([]u8)req), trans.TransportError.None)
	buf: [512]u8
	got, _ := trans.connection_read(conn, buf[:])
	testing.expect(t, strings.contains(string(buf[:got]), "HTTP/1.1 404 Not Found"))
}

metrics_http_get :: proc(t: ^testing.T, ep: net.Endpoint, path: string, loc := #caller_location) -> string {
	conn, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None, loc)
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
	req := fmt.tprintf("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", path)
	testing.expect_value(t, trans.connection_write(conn, transmute([]u8)req), trans.TransportError.None, loc)
	buf: [8192]u8
	n := 0
	need := -1
	for n < len(buf) {
		got, rerr := trans.connection_read(conn, buf[n:])
		if rerr != .None || got == 0 {
			break
		}
		n += got
		text := string(buf[:n])
		if need < 0 {
			hdr_end := strings.index(text, "\r\n\r\n")
			if hdr_end < 0 {
				continue
			}
			need = hdr_end + 4 + http_content_length(text[:hdr_end])
		}
		if need >= 0 && n >= need {
			break
		}
	}
	return strings.clone(string(buf[:n]))
}

http_content_length :: proc(headers: string) -> int {
	needle := "Content-Length: "
	idx := strings.index(headers, needle)
	if idx < 0 {
		return 0
	}
	rest := headers[idx + len(needle):]
	end := strings.index(rest, "\r\n")
	if end < 0 {
		end = len(rest)
	}
	n := 0
	for i in 0 ..< end {
		c := rest[i]
		if c < '0' || c > '9' {
			break
		}
		n = n * 10 + int(c - '0')
	}
	return n
}

@(test)
test_metrics_http_healthz_is_ok :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, server_metrics_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_metrics_start(&server)
	ep, eerr := server_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	body := metrics_http_get(t, ep, "/healthz")
	defer delete(body)
	testing.expect(t, strings.contains(body, "HTTP/1.1 200 OK"))
	testing.expect(t, strings.contains(body, "ok"))
}

@(test)
test_metrics_http_readyz_ready_while_listening :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, server_metrics_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_metrics_start(&server)
	ep, eerr := server_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	body := metrics_http_get(t, ep, "/readyz")
	defer delete(body)
	testing.expect(t, strings.contains(body, "HTTP/1.1 200 OK"))
	testing.expect(t, strings.contains(body, READYZ_READY))
}

@(test)
test_metrics_http_readyz_draining_is_503 :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, server_metrics_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_metrics_start(&server)
	ep, eerr := server_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	server_drain(&server, 0)
	body := metrics_http_get(t, ep, "/readyz")
	defer delete(body)
	testing.expect(t, strings.contains(body, "HTTP/1.1 503 Service Unavailable"))
	testing.expect(t, strings.contains(body, READYZ_DRAINING))
}

@(test)
test_metrics_http_scrape_includes_reserved_rate_limits :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, server_metrics_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_metrics_start(&server)
	ep, eerr := server_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	body := metrics_http_get(t, ep, "/metrics")
	defer delete(body)
	testing.expect(t, strings.contains(body, "HTTP/1.1 200 OK"))
	testing.expect(t, strings.contains(body, prom_limit("thirp_rate_limit_exceeds_total", LABEL_AUTHENTICATION, "0")))
	testing.expect(t, strings.contains(body, prom_limit("thirp_rate_limit_exceeds_total", LABEL_REGISTRATION, "0")))
	testing.expect(t, strings.contains(body, prom_limit("thirp_rate_limit_exceeds_total", LABEL_CONNECT, "0")))
	testing.expect(t, strings.contains(body, prom_limit("thirp_limit_exceeds_total", LABEL_GLOBAL_BUFFER, "0")))
	testing.expect(t, strings.contains(body, prom_reason("thirp_resets_total", LABEL_STREAM_IDLE, "0")))
	testing.expect(t, !strings.contains(body, "host-dev-token"))
	testing.expect(t, !strings.contains(body, "reason=\"demo/"))
}
