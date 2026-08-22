package web_ingress

import ag "../agent"
import log "../logging"
import trans "../transport"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

start_full_ingress_routes :: proc(
	t: ^testing.T,
	broker: string,
	cert_path, key_path: string,
	server: ^IngressServer,
	specs: []string,
	limits := IngressLimits{},
	shutdown_grace := time.Duration(0),
	logger: ^log.Logger = nil,
	loc := #caller_location,
) {
	routes := make([]IngressRoute, len(specs))
	for spec, i in specs {
		parsed, perr := parse_ingress_route(spec)
		testing.expect_value(t, perr, IngressError.None, loc)
		routes[i] = parsed
	}
	resolved := limits
	if resolved.broker_dial_timeout == 0 {
		resolved.broker_dial_timeout = 2 * time.Second
	}
	config := IngressConfig {
		listen          = "127.0.0.1:0",
		broker          = broker,
		token           = TEST_TOKEN_CALLER,
		tls_cert        = cert_path,
		tls_key         = key_path,
		insecure_broker = true,
		routes          = routes,
		limits          = resolved,
		shutdown_grace  = shutdown_grace,
	}
	testing.expect_value(t, ingress_server_init(server, config, logger, true), IngressError.None, loc)
	ingress_server_start(server)
	start := time.now()
	ready := false
	for time.since(start) < 2 * time.Second {
		ready, _ = ingress_ready(server)
		if ready {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, ready, loc = loc)
}

start_full_ingress :: proc(
	t: ^testing.T,
	broker: string,
	cert_path, key_path: string,
	server: ^IngressServer,
	loc := #caller_location,
) -> IngressRoute {
	start_full_ingress_routes(
		t,
		broker,
		cert_path,
		key_path,
		server,
		[]string{"ingress.test=demo/echo"},
		loc = loc,
	)
	if len(server.config.routes) > 0 {
		return server.config.routes[0]
	}
	return {}
}

stop_full_ingress :: proc(server: ^IngressServer) {
	routes := server.config.routes
	ingress_server_destroy(server)
	for route in routes {
		ingress_route_destroy(route)
	}
	delete(routes)
}

@(test)
test_terminated_get_preserves_path_query_and_host :: proc(t: ^testing.T) {
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

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	testing.expect_value(
		t,
		write_http_request(client, "GET", "/invite/demo?x=1", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head, "X-Echo-Method: GET\r\n"))
	testing.expect(t, strings.contains(head, "X-Echo-Target: /invite/demo?x=1\r\n"))
	testing.expect(t, strings.contains(head, "X-Echo-Host: ingress.test\r\n"))
	testing.expect_value(t, origin.requests, 1)
	testing.expect_value(t, origin.target, "/invite/demo?x=1")
	testing.expect_value(t, origin.host, "ingress.test")
}

@(test)
test_terminated_post_binary_body_round_trip :: proc(t: ^testing.T) {
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

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	payload := []u8{0, 1, 255, 10, 'a'}
	testing.expect_value(
		t,
		write_http_request(client, "POST", "/upload", TEST_PUBLIC_HOST, payload),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect_value(t, len(body), len(payload))
	testing.expect_value(t, string(body), string(payload))
	testing.expect_value(t, string(origin.body[:]), string(payload))
}

@(test)
test_unknown_sni_does_not_reach_origin :: proc(t: ^testing.T) {
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

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_OTHER_HOST)
	defer trans.connection_destroy(client)

	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 421 Misdirected Request\r\n"))
	testing.expect_value(t, origin.requests, 0)
}

@(test)
test_two_sequential_connections_on_same_caller :: proc(t: ^testing.T) {
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

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	targets := [2]string{"/one", "/two"}
	for target in targets {
		client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
		testing.expect_value(
			t,
			write_http_request(client, "GET", target, TEST_PUBLIC_HOST, nil),
			trans.TransportError.None,
		)
		head, body, ok := read_http_message(client)
		trans.connection_destroy(client)
		testing.expect(t, ok)
		testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
		testing.expect(t, strings.contains(head, fmt.tprintf("X-Echo-Target: %s\r\n", target)))
		delete(head)
		delete(body)
	}
	testing.expect_value(t, origin.requests, 2)
}
