package web_ingress

import cl "../caller"
import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

StubDial :: struct {
	mutex: sync.Mutex,
	calls: int,
	last:  string,
	err:   cl.CallerError,
}

stub_dial :: proc(ctx: rawptr, service_id: proto.ServiceId) -> (^cl.Conn, cl.CallerError) {
	s := (^StubDial)(ctx)
	sync.mutex_lock(&s.mutex)
	s.calls += 1
	s.last = string(service_id)
	err := s.err
	sync.mutex_unlock(&s.mutex)
	return nil, err
}

start_stub_ingress :: proc(
	t: ^testing.T,
	server: ^IngressServer,
	stub: ^StubDial,
	cert_path, key_path: string,
	limits := IngressLimits{},
	metrics_listen := "",
	loc := #caller_location,
) -> IngressRoute {
	return start_stub_ingress_routes(
		t,
		server,
		stub,
		[]string{"ingress.test=demo/echo"},
		cert_path,
		key_path,
		limits,
		metrics_listen,
		loc,
	)
}

start_stub_ingress_routes :: proc(
	t: ^testing.T,
	server: ^IngressServer,
	stub: ^StubDial,
	specs: []string,
	cert_path, key_path: string,
	limits := IngressLimits{},
	metrics_listen := "",
	loc := #caller_location,
) -> IngressRoute {
	routes := make([]IngressRoute, len(specs))
	for spec, i in specs {
		parsed, perr := parse_ingress_route(spec)
		testing.expect_value(t, perr, IngressError.None, loc)
		routes[i] = parsed
	}
	config := IngressConfig {
		listen         = "127.0.0.1:0",
		tls_cert       = cert_path,
		tls_key        = key_path,
		routes         = routes,
		limits         = limits,
		metrics_listen = metrics_listen,
	}
	testing.expect_value(t, ingress_server_init(server, config, nil, false), IngressError.None, loc)
	server.dialer.ctx = stub
	server.dialer.dial = stub_dial
	ingress_server_start(server)
	time.sleep(20 * time.Millisecond)
	if len(routes) > 0 {
		return routes[0]
	}
	return {}
}

stop_stub_ingress :: proc(server: ^IngressServer) {
	routes := server.config.routes
	ingress_server_destroy(server)
	for route in routes {
		ingress_route_destroy(route)
	}
	delete(routes)
}

@(test)
test_unknown_sni_does_not_dial :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	stub.err = .Unauthorized
	server: IngressServer
	_ = start_stub_ingress(t, &server, &stub, cert_path, key_path)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_OTHER_HOST)
	defer trans.connection_destroy(client)

	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 421 Misdirected Request\r\n"))
	testing.expect(t, strings.contains(head, "Connection: close\r\n"))
	testing.expect_value(t, stub.calls, 0)
}

@(test)
test_missing_sni_does_not_dial :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	stub.err = .Unauthorized
	server: IngressServer
	_ = start_stub_ingress(t, &server, &stub, cert_path, key_path)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, "127.0.0.1", true)
	defer trans.connection_destroy(client)

	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 421 Misdirected Request\r\n"))
	testing.expect_value(t, stub.calls, 0)
}

@(test)
test_known_host_dials_once_and_maps_unauthorized :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	stub.err = .Unauthorized
	server: IngressServer
	_ = start_stub_ingress(t, &server, &stub, cert_path, key_path)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 403 Forbidden\r\n"))
	testing.expect_value(t, stub.calls, 1)
	testing.expect_value(t, stub.last, "demo/echo")
}

@(test)
test_one_dial_failure_does_not_stop_next_connection :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	stub.err = .Unauthorized
	server: IngressServer
	_ = start_stub_ingress(t, &server, &stub, cert_path, key_path)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	a := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	head_a, body_a, ok_a := read_http_message(a)
	trans.connection_destroy(a)
	defer delete(head_a)
	defer delete(body_a)
	testing.expect(t, ok_a)
	testing.expect(t, strings.has_prefix(head_a, "HTTP/1.1 403 Forbidden\r\n"))

	stub.err = .RateLimited
	b := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	head_b, body_b, ok_b := read_http_message(b)
	trans.connection_destroy(b)
	defer delete(head_b)
	defer delete(body_b)
	testing.expect(t, ok_b)
	testing.expect(t, strings.has_prefix(head_b, "HTTP/1.1 429 Too Many Requests\r\n"))
	testing.expect_value(t, stub.calls, 2)
}

@(test)
test_stub_broker_draining_maps_to_503 :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	stub.err = .BrokerDraining
	server: IngressServer
	_ = start_stub_ingress(t, &server, &stub, cert_path, key_path)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 503 Service Unavailable\r\n"))
}
