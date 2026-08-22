package web_ingress

import ag "../agent"
import brk "../broker"
import trans "../transport"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_slow_client_hello_times_out_without_dial :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress(
		t,
		&server,
		&stub,
		cert_path,
		key_path,
		IngressLimits{client_hello_timeout = 200 * time.Millisecond},
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	testing.expect_value(t, trans.connection_write(raw, []u8{0x16, 0x03, 0x01, 0x00, 0x80}), trans.TransportError.None)
	time.sleep(500 * time.Millisecond)
	testing.expect_value(t, stub.calls, 0)
	testing.expect(t, server.metrics.tls_handshakes[.Timeout] >= 1)
	testing.expect_value(t, server.slot_count, 0)
}

@(test)
test_malformed_handshake_does_not_dial :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress(t, &server, &stub, cert_path, key_path)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	junk: [2048]u8
	for i in 0 ..< len(junk) {
		junk[i] = 0x41
	}
	_ = trans.connection_write(raw, junk[:])
	time.sleep(100 * time.Millisecond)
	testing.expect_value(t, stub.calls, 0)
	testing.expect_value(t, server.slot_count, 0)
}

@(test)
test_broker_unavailable_returns_502_and_not_ready :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	parsed, perr := parse_ingress_route("ingress.test=demo/echo")
	testing.expect_value(t, perr, IngressError.None)
	routes := make([]IngressRoute, 1)
	routes[0] = parsed
	config := IngressConfig {
		listen          = "127.0.0.1:0",
		broker          = "127.0.0.1:1",
		token           = TEST_TOKEN_CALLER,
		tls_cert        = cert_path,
		tls_key         = key_path,
		insecure_broker = true,
		routes          = routes,
		metrics_listen  = "127.0.0.1:0",
	}
	server: IngressServer
	testing.expect_value(t, ingress_server_init(&server, config, nil, true), IngressError.None)
	defer stop_full_ingress(&server)
	ingress_server_start(&server)
	time.sleep(20 * time.Millisecond)

	ready, reason := ingress_ready(&server)
	testing.expect(t, !ready)
	testing.expect_value(t, reason, READYZ_NOT_READY)
	mep, merr := ingress_metrics_endpoint(&server)
	testing.expect_value(t, merr, trans.TransportError.None)
	rstatus, rbody, rok := http_get_path(mep, "/readyz")
	defer delete(rstatus)
	defer delete(rbody)
	testing.expect(t, rok)
	testing.expect(t, strings.contains(rstatus, "503"))

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 502 Bad Gateway\r\n"))
}

@(test)
test_unauthorized_connect_returns_403 :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	apply_production_policy(t, &fx, false)

	origin: HttpOriginFixture
	origin_ep := start_http_origin(t, &origin)
	defer stop_http_origin(&origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin_ep, &agent, &run)
	defer stop_agent(&agent, th)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	_ = start_full_ingress(t, broker, cert_path, key_path, &server)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok, head)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 403 Forbidden\r\n"), head)
	testing.expect(t, !strings.contains(head, "demo/echo"))
	testing.expect_value(t, origin.requests, 0)
}

@(test)
test_service_absent_returns_503 :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	_ = start_full_ingress(t, broker, cert_path, key_path, &server)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 503 Service Unavailable\r\n"))
}

@(test)
test_local_target_unavailable_returns_503 :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	agent: ag.Agent
	run: AgentRunArg
	closed := net.Endpoint{address = net.IP4_Loopback, port = 1}
	th := start_registered_agent(t, &fx, closed, &agent, &run)
	defer stop_agent(&agent, th)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	_ = start_full_ingress(t, broker, cert_path, key_path, &server)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 503 Service Unavailable\r\n"))
}

@(test)
test_broker_draining_returns_503 :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin: HttpOriginFixture
	origin_ep := start_http_origin(t, &origin)
	defer stop_http_origin(&origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin_ep, &agent, &run)
	defer stop_agent(&agent, th)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	_ = start_full_ingress(t, broker, cert_path, key_path, &server)
	defer stop_full_ingress(&server)

	dth := thread.create_and_start_with_poly_data(&fx.server, broker_drain_proc)
	time.sleep(30 * time.Millisecond)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(
		t,
		strings.has_prefix(head, "HTTP/1.1 503 Service Unavailable\r\n") ||
		strings.has_prefix(head, "HTTP/1.1 502 Bad Gateway\r\n"),
	)
	if dth != nil {
		thread.join(dth)
		thread.destroy(dth)
	}
}

@(test)
test_idle_browser_closes_without_affecting_sibling :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin: HttpOriginFixture
	origin_ep := start_http_origin(t, &origin, .EchoKeepAlive)
	defer stop_http_origin(&origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin_ep, &agent, &run)
	defer stop_agent(&agent, th)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	start_full_ingress_routes(
		t,
		broker,
		cert_path,
		key_path,
		&server,
		[]string{"ingress.test=demo/echo"},
		limits = IngressLimits{idle_timeout = 200 * time.Millisecond},
	)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	idle := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(idle)
	time.sleep(500 * time.Millisecond)

	sib := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(sib)
	testing.expect_value(
		t,
		write_http_request(sib, "GET", "/sib", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(sib)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
}

@(test)
test_idle_origin_closes_after_response :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin: HttpOriginFixture
	origin_ep := start_http_origin(t, &origin, .EchoKeepAlive)
	defer stop_http_origin(&origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin_ep, &agent, &run)
	defer stop_agent(&agent, th)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	start_full_ingress_routes(
		t,
		broker,
		cert_path,
		key_path,
		&server,
		[]string{"ingress.test=demo/echo"},
		limits = IngressLimits{idle_timeout = 200 * time.Millisecond},
	)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/idle-origin", TEST_PUBLIC_HOST, nil, keep_alive = true),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))

	_ = trans.connection_set_recv_timeout(client, 800 * time.Millisecond)
	buf: [32]u8
	_, rerr := trans.connection_read(client, buf[:])
	testing.expect(t, rerr == .Closed || rerr == .Timeout || rerr == .Tls)
}

broker_drain_proc :: proc(s: ^brk.Server) {
	brk.server_drain(s, 2 * time.Second)
}
