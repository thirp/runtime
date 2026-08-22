package web_ingress

import ag "../agent"
import trans "../transport"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_ingress_drain_sets_readyz_and_rejects_new :: proc(t: ^testing.T) {
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
		metrics_listen = "127.0.0.1:0",
	)
	server.config.shutdown_grace = 50 * time.Millisecond

	ep, eerr := ingress_metrics_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	listen_ep, lerr := ingress_server_endpoint(&server)
	testing.expect_value(t, lerr, trans.TransportError.None)

	ingress_server_drain(&server)
	defer stop_stub_ingress(&server)

	ready, reason := ingress_ready(&server)
	testing.expect(t, !ready)
	testing.expect_value(t, reason, READYZ_DRAINING)

	rstatus, rbody, rok := http_get_path(ep, "/readyz")
	defer delete(rstatus)
	defer delete(rbody)
	testing.expect(t, rok)
	testing.expect(t, strings.contains(rstatus, "503"))
	testing.expect(t, strings.contains(rbody, READYZ_DRAINING))

	hstatus, hbody, hok := http_get_path(ep, "/healthz")
	defer delete(hstatus)
	defer delete(hbody)
	testing.expect(t, hok)
	testing.expect(t, strings.contains(hstatus, "200"))

	client, cerr := trans.connection_dial_tls(
		listen_ep,
		trans.TlsClientConfig{ca_path = cert_path, server_name = TEST_PUBLIC_HOST},
	)
	if client != nil {
		trans.connection_destroy(client)
	}
	testing.expect(t, cerr != .None)
	testing.expect_value(t, stub.calls, 0)
}

@(test)
test_ingress_drain_waits_then_closes_established :: proc(t: ^testing.T) {
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
		shutdown_grace = 150 * time.Millisecond,
	)
	defer stop_full_ingress(&server)

	listen_ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, listen_ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/hold", TEST_PUBLIC_HOST, nil, keep_alive = true),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))

	ingress_server_drain(&server)
	start := time.now()
	for time.since(start) < 2 * time.Second {
		if server.active_conns == 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, server.active_conns, 0)
}
