package web_ingress

import trans "../transport"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_ingress_ready_transitions :: proc(t: ^testing.T) {
	server: IngressServer
	ready, reason := ingress_ready(&server)
	testing.expect(t, !ready)
	testing.expect_value(t, reason, READYZ_NOT_READY)

	server.listening = true
	server.want_caller = true
	ready, reason = ingress_ready(&server)
	testing.expect(t, !ready)
	testing.expect_value(t, reason, READYZ_NOT_READY)

	server.caller_ok = true
	server.caller.connected = true
	ready, reason = ingress_ready(&server)
	testing.expect(t, ready)
	testing.expect_value(t, reason, READYZ_READY)

	term := []IngressRoute{{mode = .TerminateHttp}}
	server.config.routes = term
	ready, reason = ingress_ready(&server)
	testing.expect(t, !ready)
	testing.expect_value(t, reason, READYZ_NOT_READY)

	server.config.insecure = true
	ready, reason = ingress_ready(&server)
	testing.expect(t, ready)
	testing.expect_value(t, reason, READYZ_READY)

	server.draining = true
	ready, reason = ingress_ready(&server)
	testing.expect(t, !ready)
	testing.expect_value(t, reason, READYZ_DRAINING)
}

@(test)
test_metrics_prometheus_has_fixed_labels_only :: proc(t: ^testing.T) {
	server: IngressServer
	metrics_inc_conn(&server.metrics, .Ok)
	metrics_inc_route_failure(&server.metrics, .UnknownRoute)
	metrics_inc_tls(&server.metrics, .Timeout)
	metrics_inc_dial(&server.metrics, .Unauthorized)
	metrics_inc_bytes(&server.metrics, .BrowserToOrigin, 4)
	metrics_inc_limit(&server.metrics, .ConnectionsPerIp)
	metrics_observe(&server.metrics, .ServiceDial, 20 * time.Millisecond)

	text := metrics_write_prometheus(metrics_snapshot(&server))
	defer delete(text)
	testing.expect(t, strings.contains(text, "thirp_web_ingress_active_connections"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_connections_total{result=\"ok\"}"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_route_failures_total{reason=\"unknown_route\"}"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_tls_handshakes_total{result=\"timeout\"}"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_service_dials_total{result=\"unauthorized\"}"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_bytes_total{direction=\"browser_to_origin\"}"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_limit_exceeds_total{limit=\"connections_per_ip\"}"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_service_dial_seconds_count"))
	testing.expect(t, strings.contains(text, "thirp_web_ingress_connection_duration_seconds"))
	testing.expect(t, !strings.contains(text, "ingress.test"))
	testing.expect(t, !strings.contains(text, "demo/echo"))
	testing.expect(t, !strings.contains(text, "127.0.0.1"))
	testing.expect(t, !strings.contains(text, "rendez_"))
}

@(test)
test_metrics_http_healthz_readyz_and_404 :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress(t, &server, &stub, cert_path, key_path, metrics_listen = "127.0.0.1:0")
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	status, body, ok := http_get_path(ep, "/healthz")
	defer delete(status)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(status, "200"))
	testing.expect(t, strings.contains(body, "ok"))

	rstatus, rbody, rok := http_get_path(ep, "/readyz")
	defer delete(rstatus)
	defer delete(rbody)
	testing.expect(t, rok)
	testing.expect(t, strings.contains(rstatus, "200"))
	testing.expect(t, strings.contains(rbody, READYZ_READY))

	mstatus, mbody, mok := http_get_path(ep, "/metrics")
	defer delete(mstatus)
	defer delete(mbody)
	testing.expect(t, mok)
	testing.expect(t, strings.contains(mstatus, "200"))
	testing.expect(t, strings.contains(mbody, "thirp_web_ingress_active_connections"))
	testing.expect(t, !strings.contains(mbody, "ingress.test"))

	nstatus, nbody, nok := http_get_path(ep, "/nope")
	defer delete(nstatus)
	defer delete(nbody)
	testing.expect(t, nok)
	testing.expect(t, strings.contains(nstatus, "404"))
}
