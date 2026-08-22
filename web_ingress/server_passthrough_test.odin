package web_ingress

import ag "../agent"
import log "../logging"
import trans "../transport"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

wait_stub_calls :: proc(stub: ^StubDial, want: int, timeout: time.Duration) -> int {
	start := time.now()
	for time.since(start) < timeout {
		sync.mutex_lock(&stub.mutex)
		n := stub.calls
		sync.mutex_unlock(&stub.mutex)
		if n >= want {
			return n
		}
		time.sleep(5 * time.Millisecond)
	}
	sync.mutex_lock(&stub.mutex)
	n := stub.calls
	sync.mutex_unlock(&stub.mutex)
	return n
}

wait_slot_idle :: proc(server: ^IngressServer, timeout: time.Duration) -> bool {
	start := time.now()
	for time.since(start) < timeout {
		if server.slot_count == 0 {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return server.slot_count == 0
}

@(test)
test_passthrough_unknown_sni_closes_without_dial :: proc(t: ^testing.T) {
	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress_routes(
		t,
		&server,
		&stub,
		[]string{"secure.test=demo/secure:tls_passthrough"},
		"",
		"",
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	hello := build_client_hello([]string{TEST_OTHER_HOST})
	defer delete(hello)
	testing.expect_value(t, trans.connection_write(raw, hello), trans.TransportError.None)
	testing.expect_value(t, wait_stub_calls(&stub, 1, 200 * time.Millisecond), 0)
	testing.expect(t, wait_slot_idle(&server, 1 * time.Second))
	buf: [8]u8
	_ = trans.connection_set_recv_timeout(raw, 200 * time.Millisecond)
	_, rerr := trans.connection_read(raw, buf[:])
	testing.expect(t, rerr == .Closed || rerr == .Timeout || rerr == .Network)
}

@(test)
test_passthrough_missing_sni_closes_without_dial :: proc(t: ^testing.T) {
	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress_routes(
		t,
		&server,
		&stub,
		[]string{"secure.test=demo/secure:tls_passthrough"},
		"",
		"",
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	hello := build_client_hello(nil)
	defer delete(hello)
	testing.expect_value(t, trans.connection_write(raw, hello), trans.TransportError.None)
	testing.expect_value(t, wait_stub_calls(&stub, 1, 200 * time.Millisecond), 0)
	testing.expect(t, wait_slot_idle(&server, 1 * time.Second))
}

@(test)
test_passthrough_oversized_hello_does_not_dial :: proc(t: ^testing.T) {
	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress_routes(
		t,
		&server,
		&stub,
		[]string{"secure.test=demo/secure:tls_passthrough"},
		"",
		"",
		IngressLimits{max_client_hello_bytes = 32, client_hello_timeout = 500 * time.Millisecond},
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	testing.expect_value(t, trans.connection_write(raw, []u8{0x16, 0x03, 0x03, 0x00, 0x80}), trans.TransportError.None)
	testing.expect_value(t, wait_stub_calls(&stub, 1, 300 * time.Millisecond), 0)
	testing.expect(t, server.metrics.tls_handshakes[.Error] >= 1)
	testing.expect(t, wait_slot_idle(&server, 1 * time.Second))
}

@(test)
test_passthrough_split_write_routes :: proc(t: ^testing.T) {
	stub: StubDial
	stub.err = .Unauthorized
	server: IngressServer
	_ = start_stub_ingress_routes(
		t,
		&server,
		&stub,
		[]string{"secure.test=demo/secure:tls_passthrough"},
		"",
		"",
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	hello := build_client_hello([]string{TEST_SECURE_HOST})
	defer delete(hello)
	mid := 8
	if mid >= len(hello) {
		mid = len(hello) / 2
	}
	testing.expect_value(t, trans.connection_write(raw, hello[:mid]), trans.TransportError.None)
	time.sleep(30 * time.Millisecond)
	testing.expect_value(t, trans.connection_write(raw, hello[mid:]), trans.TransportError.None)
	testing.expect_value(t, wait_stub_calls(&stub, 1, 1 * time.Second), 1)
	testing.expect(t, wait_slot_idle(&server, 1 * time.Second))
}

@(test)
test_passthrough_dial_failure_closes_without_http :: proc(t: ^testing.T) {
	stub: StubDial
	stub.err = .ServiceNotFound
	server: IngressServer
	_ = start_stub_ingress_routes(
		t,
		&server,
		&stub,
		[]string{"secure.test=demo/secure:tls_passthrough"},
		"",
		"",
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	hello := build_client_hello([]string{TEST_SECURE_HOST})
	defer delete(hello)
	testing.expect_value(t, trans.connection_write(raw, hello), trans.TransportError.None)
	testing.expect_value(t, wait_stub_calls(&stub, 1, 1 * time.Second), 1)
	_ = trans.connection_set_recv_timeout(raw, 300 * time.Millisecond)
	buf: [64]u8
	n, rerr := trans.connection_read(raw, buf[:])
	testing.expect(t, rerr == .Closed || rerr == .Timeout || n == 0)
	if n > 0 {
		testing.expect(t, !strings.has_prefix(string(buf[:n]), "HTTP/1.1"))
	}
}

@(test)
test_passthrough_get_preserves_path_and_origin_cert :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin_cert, cert_ok := write_temp_pem("origin-cert", ORIGIN_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(origin_cert)
	origin_key, key_ok := write_temp_pem("origin-key", ORIGIN_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(origin_key)

	origin: HttpOriginFixture
	origin_ep := start_https_origin(t, &origin, origin_cert, origin_key)
	defer stop_http_origin(&origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin_ep, &agent, &run, TEST_SERVICE_SECURE)
	defer stop_agent(&agent, th)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	start_full_ingress_routes(
		t,
		broker,
		"",
		"",
		&server,
		[]string{"secure.test=demo/secure:tls_passthrough"},
	)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_passthrough_tls(t, ep, origin_cert, TEST_SECURE_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/secure/path?q=1", TEST_SECURE_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head, "X-Echo-Target: /secure/path?q=1\r\n"))
	testing.expect(t, strings.contains(head, "X-Echo-Host: secure.test\r\n"))
	testing.expect_value(t, origin.requests, 1)
}

@(test)
test_passthrough_origin_cert_mismatch_when_client_trusts_ingress :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin_cert, cert_ok := write_temp_pem("origin-cert", ORIGIN_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(origin_cert)
	origin_key, key_ok := write_temp_pem("origin-key", ORIGIN_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(origin_key)
	ingress_cert, ic_ok := write_temp_pem("ingress-cert", INGRESS_TEST_CERT)
	testing.expect(t, ic_ok)
	defer remove_temp_pem(ingress_cert)

	origin: HttpOriginFixture
	origin_ep := start_https_origin(t, &origin, origin_cert, origin_key)
	defer stop_http_origin(&origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin_ep, &agent, &run, TEST_SERVICE_SECURE)
	defer stop_agent(&agent, th)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	start_full_ingress_routes(
		t,
		broker,
		"",
		"",
		&server,
		[]string{"secure.test=demo/secure:tls_passthrough"},
	)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	cfg := trans.TlsClientConfig {
		ca_path     = ingress_cert,
		server_name = TEST_SECURE_HOST,
	}
	client, err := trans.connection_dial_tls(ep, cfg)
	if client != nil {
		trans.connection_destroy(client)
	}
	testing.expect_value(t, err, trans.TransportError.Tls)
	testing.expect_value(t, origin.requests, 0)
}

PassthroughGetJob :: struct {
	ep:        net.Endpoint,
	cert_path: string,
	name:      string,
	target:    string,
	ok:        bool,
	head:      string,
}

passthrough_get_proc :: proc(job: ^PassthroughGetJob) {
	client, err := trans.connection_dial_tls(
		job.ep,
		trans.TlsClientConfig{ca_path = job.cert_path, server_name = job.name},
	)
	if err != .None || client == nil {
		return
	}
	defer trans.connection_destroy(client)
	if write_http_request(client, "GET", job.target, job.name, nil) != .None {
		return
	}
	head, body, ok := read_http_message(client)
	defer delete(body)
	job.ok = ok
	job.head = head
}

@(test)
test_mixed_terminated_and_passthrough_dispatch :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	http_origin: HttpOriginFixture
	http_ep := start_http_origin(t, &http_origin)
	defer stop_http_origin(&http_origin)

	origin_cert, oc_ok := write_temp_pem("origin-cert", ORIGIN_TEST_CERT)
	testing.expect(t, oc_ok)
	defer remove_temp_pem(origin_cert)
	origin_key, ok_ok := write_temp_pem("origin-key", ORIGIN_TEST_KEY)
	testing.expect(t, ok_ok)
	defer remove_temp_pem(origin_key)
	https_origin: HttpOriginFixture
	https_ep := start_https_origin(t, &https_origin, origin_cert, origin_key)
	defer stop_http_origin(&https_origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent_services(
		t,
		&fx,
		&agent,
		&run,
		[]AgentServiceTarget {
			{service = TEST_SERVICE, target = http_ep},
			{service = TEST_SERVICE_SECURE, target = https_ep},
		},
	)
	defer stop_agent(&agent, th)

	ingress_cert, ic_ok := write_temp_pem("ingress-cert", INGRESS_TEST_CERT)
	testing.expect(t, ic_ok)
	defer remove_temp_pem(ingress_cert)
	ingress_key, ik_ok := write_temp_pem("ingress-key", INGRESS_TEST_KEY)
	testing.expect(t, ik_ok)
	defer remove_temp_pem(ingress_key)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	start_full_ingress_routes(
		t,
		broker,
		ingress_cert,
		ingress_key,
		&server,
		[]string{"ingress.test=demo/echo:http", "secure.test=demo/secure:tls_passthrough"},
	)
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	jobs := [2]PassthroughGetJob {
		{ep = ep, cert_path = ingress_cert, name = TEST_PUBLIC_HOST, target = "/term"},
		{ep = ep, cert_path = origin_cert, name = TEST_SECURE_HOST, target = "/pass"},
	}
	th0 := thread.create_and_start_with_poly_data(&jobs[0], passthrough_get_proc)
	th1 := thread.create_and_start_with_poly_data(&jobs[1], passthrough_get_proc)
	if th0 != nil {
		thread.join(th0)
		thread.destroy(th0)
	}
	if th1 != nil {
		thread.join(th1)
		thread.destroy(th1)
	}
	testing.expect(t, jobs[0].ok, jobs[0].head)
	testing.expect(t, jobs[1].ok, jobs[1].head)
	testing.expect(t, strings.contains(jobs[0].head, "X-Echo-Target: /term\r\n"))
	testing.expect(t, strings.contains(jobs[1].head, "X-Echo-Target: /pass\r\n"))
	testing.expect(t, !strings.contains(jobs[0].head, "X-Echo-Target: /pass\r\n"))
	testing.expect(t, !strings.contains(jobs[1].head, "X-Echo-Target: /term\r\n"))
	testing.expect_value(t, http_origin.requests, 1)
	testing.expect_value(t, https_origin.requests, 1)
}

passthrough_redaction_cap: ^log.Capture

passthrough_redaction_sink :: proc(text: string) {
	if passthrough_redaction_cap != nil {
		log.capture_sink(passthrough_redaction_cap, text)
	}
}

@(test)
test_passthrough_logs_omit_client_hello_bytes :: proc(t: ^testing.T) {
	cap: log.Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	passthrough_redaction_cap = &cap
	defer {passthrough_redaction_cap = nil}
	logger: log.Logger
	log.logger_init(&logger, .Debug, passthrough_redaction_sink)

	marker := transmute([]u8)string("REDACT-CH-MARKER-WI5")
	stub: StubDial
	stub.err = .Unauthorized
	server: IngressServer
	parsed, perr := parse_ingress_route("secure.test=demo/secure:tls_passthrough")
	testing.expect_value(t, perr, IngressError.None)
	routes := make([]IngressRoute, 1)
	routes[0] = parsed
	config := IngressConfig {
		listen  = "127.0.0.1:0",
		routes  = routes,
		limits  = IngressLimits{client_hello_timeout = 1 * time.Second},
	}
	testing.expect_value(t, ingress_server_init(&server, config, &logger, false), IngressError.None)
	server.dialer.ctx = &stub
	server.dialer.dial = stub_dial
	ingress_server_start(&server)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(raw)
	hello := build_client_hello([]string{TEST_SECURE_HOST}, session = marker)
	defer delete(hello)
	testing.expect_value(t, trans.connection_write(raw, hello), trans.TransportError.None)
	_ = wait_stub_calls(&stub, 1, 1 * time.Second)
	testing.expect(t, wait_slot_idle(&server, 1 * time.Second))
	got := string(cap.text[:])
	testing.expect(t, !strings.contains(got, "REDACT-CH-MARKER-WI5"))
	testing.expect(t, strings.contains(got, "secure.test") || strings.contains(got, "route_selected"))
}
