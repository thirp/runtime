package web_ingress

import ag "../agent"
import trans "../transport"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

STREAM_CLIENT_HEAD_CAP :: 2048

TerminatedStack :: struct {
	broker:      TestBroker,
	origin:      HttpOriginFixture,
	agent:       ag.Agent,
	run:         AgentRunArg,
	agent_th:    ^thread.Thread,
	cert_path:   string,
	key_path:    string,
	broker_addr: string,
	server:      IngressServer,
	ep:          net.Endpoint,
}

StreamClientJob :: struct {
	ep:          net.Endpoint,
	cert_path:   string,
	server_name: string,
	target:      string,
	host:        string,
	head_buf:    [STREAM_CLIENT_HEAD_CAP]u8,
	head_len:    int,
	body_buf:    [SLOW_WRITE_SIZE]u8,
	body_len:    int,
	ok:          bool,
}

StreamEchoReadJob :: struct {
	conn:     ^trans.Connection,
	leftover: []u8,
	want:     int,
	got:      int,
	ok:       bool,
}

start_terminated_stack :: proc(
	t: ^testing.T,
	st: ^TerminatedStack,
	kind := HttpOriginKind.EchoClose,
	loc := #caller_location,
) {
	start_test_broker(t, &st.broker, loc)
	origin_ep := start_http_origin(t, &st.origin, kind, loc)
	st.agent_th = start_registered_agent(t, &st.broker, origin_ep, &st.agent, &st.run, TEST_SERVICE, loc)
	cert_ok: bool
	st.cert_path, cert_ok = write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok, loc = loc)
	key_ok: bool
	st.key_path, key_ok = write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok, loc = loc)
	st.broker_addr = broker_endpoint_string(t, &st.broker, loc)
	_ = start_full_ingress(t, st.broker_addr, st.cert_path, st.key_path, &st.server, loc)
	ep, eerr := ingress_server_endpoint(&st.server)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	st.ep = ep
}

stop_terminated_stack :: proc(st: ^TerminatedStack) {
	stop_full_ingress(&st.server)
	stop_agent(&st.agent, st.agent_th)
	stop_http_origin(&st.origin)
	stop_test_broker(&st.broker)
	remove_temp_pem(st.cert_path)
	remove_temp_pem(st.key_path)
	delete(st.broker_addr)
}

stream_client_copy_result :: proc(job: ^StreamClientJob, head: string, body: []u8, ok: bool) {
	job.ok = ok
	job.head_len = min(len(head), len(job.head_buf))
	if job.head_len > 0 {
		copy(job.head_buf[:], transmute([]u8)head[:job.head_len])
	}
	job.body_len = min(len(body), len(job.body_buf))
	if job.body_len > 0 {
		copy(job.body_buf[:], body[:job.body_len])
	}
}

stream_client_head :: proc(job: ^StreamClientJob) -> string {
	return string(job.head_buf[:job.head_len])
}

stream_client_get :: proc(job: ^StreamClientJob) {
	cfg := trans.TlsClientConfig {
		ca_path     = job.cert_path,
		server_name = job.server_name,
	}
	client, err := trans.connection_dial_tls(job.ep, cfg)
	if err != .None || client == nil {
		return
	}
	defer trans.connection_destroy(client)
	if write_http_request(client, "GET", job.target, job.host, nil) != .None {
		return
	}
	head, body, ok := read_http_message(client)
	stream_client_copy_result(job, head, body, ok)
	delete(head)
	delete(body)
}

stream_pattern_byte :: proc(i: int) -> u8 {
	return u8(i % 251)
}

stream_echo_read_proc :: proc(job: ^StreamEchoReadJob) {
	body, ok := read_n_bytes(job.conn, job.leftover, job.want)
	job.got = len(body)
	defer delete(body)
	if !ok {
		return
	}
	for i in 0 ..< len(body) {
		if body[i] != stream_pattern_byte(i) {
			return
		}
	}
	job.ok = true
}

@(test)
test_terminated_http_keep_alive_two_requests :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .EchoKeepAlive)
	defer stop_terminated_stack(&st)

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	testing.expect_value(
		t,
		write_http_request(client, "GET", "/one", TEST_PUBLIC_HOST, nil, true),
		trans.TransportError.None,
	)
	head1, body1, ok1 := read_http_message(client)
	defer delete(head1)
	defer delete(body1)
	testing.expect(t, ok1)
	testing.expect(t, strings.has_prefix(head1, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head1, "X-Echo-Target: /one\r\n"))

	testing.expect_value(
		t,
		write_http_request(client, "GET", "/two", TEST_PUBLIC_HOST, nil, true),
		trans.TransportError.None,
	)
	head2, body2, ok2 := read_http_message(client)
	defer delete(head2)
	defer delete(body2)
	testing.expect(t, ok2)
	testing.expect(t, strings.has_prefix(head2, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head2, "X-Echo-Target: /two\r\n"))
	testing.expect_value(t, st.origin.requests, 2)
}

@(test)
test_terminated_chunked_response_bytes_match :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .Chunked)
	defer stop_terminated_stack(&st)

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	testing.expect_value(
		t,
		write_http_request(client, "GET", "/chunked", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, leftover, ok := read_http_headers(client)
	defer delete(head)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head, "Transfer-Encoding: chunked\r\n"))
	wire, wok := read_until_closed(client, leftover)
	defer delete(leftover)
	defer delete(wire)
	testing.expect(t, wok)
	testing.expect_value(t, string(wire), CHUNKED_WIRE)
	testing.expect(t, strings.contains(string(wire), CHUNKED_PAYLOAD[:5]))
}

@(test)
test_terminated_large_stream_echo_without_whole_body_buffer :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .StreamEcho)
	defer stop_terminated_stack(&st)

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	header := fmt.aprintf(
		"POST /stream HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		TEST_PUBLIC_HOST,
		STREAM_ECHO_SIZE,
	)
	testing.expect_value(t, trans.connection_write(client, transmute([]u8)header), trans.TransportError.None)
	delete(header)

	first: [INGRESS_COPY_BUF]u8
	for i in 0 ..< len(first) {
		first[i] = stream_pattern_byte(i)
	}
	testing.expect_value(t, trans.connection_write(client, first[:]), trans.TransportError.None)

	head, leftover, hok := read_http_headers(client)
	defer delete(head)
	testing.expect(t, hok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head, "X-Echo-Target: /stream\r\n"))
	testing.expect_value(t, http_content_length(head), STREAM_ECHO_SIZE)
	if len(leftover) == 0 {
		one: [1]u8
		n, rerr := trans.connection_read(client, one[:])
		testing.expect_value(t, rerr, trans.TransportError.None)
		testing.expect_value(t, n, 1)
		owned, _ := strings.clone(string(one[:]))
		leftover = transmute([]u8)owned
	}
	testing.expect(t, len(leftover) > 0)

	read_job := StreamEchoReadJob {
		conn     = client,
		leftover = leftover,
		want     = STREAM_ECHO_SIZE,
	}
	th := thread.create_and_start_with_poly_data(&read_job, stream_echo_read_proc)

	off := len(first)
	chunk: [INGRESS_COPY_BUF]u8
	for off < STREAM_ECHO_SIZE {
		n := min(len(chunk), STREAM_ECHO_SIZE - off)
		for i in 0 ..< n {
			chunk[i] = stream_pattern_byte(off + i)
		}
		testing.expect_value(t, trans.connection_write(client, chunk[:n]), trans.TransportError.None)
		off += n
	}

	if th != nil {
		thread.join(th)
		thread.destroy(th)
	}
	defer delete(leftover)
	testing.expect(t, read_job.ok)
	testing.expect_value(t, read_job.got, STREAM_ECHO_SIZE)
}

@(test)
test_terminated_sse_events_arrive_incrementally :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .Sse)
	defer stop_terminated_stack(&st)

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	testing.expect_value(
		t,
		write_http_request(client, "GET", "/events", TEST_PUBLIC_HOST, nil, true),
		trans.TransportError.None,
	)
	head, leftover, ok := read_http_headers(client)
	defer delete(head)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head, "Content-Type: text/event-stream\r\n"))

	first, fok := read_until_contains(client, leftover, SSE_EVENT_1)
	defer delete(leftover)
	defer delete(first)
	testing.expect(t, fok)
	testing.expect(t, strings.contains(string(first), SSE_EVENT_1))
	http_origin_signal_sse_first(&st.origin)

	rest, rok := read_until_contains(client, nil, SSE_EVENT_3)
	defer delete(rest)
	testing.expect(t, rok)
	testing.expect(t, strings.contains(string(rest), SSE_EVENT_2))
	testing.expect(t, strings.contains(string(rest), SSE_EVENT_3))
}

@(test)
test_terminated_websocket_upgrade_echo :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .WebSocketEcho)
	defer stop_terminated_stack(&st)

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	req := "GET /ws HTTP/1.1\r\n" +
		"Host: ingress.test\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"\r\n"
	testing.expect_value(t, trans.connection_write(client, transmute([]u8)req), trans.TransportError.None)

	head, leftover, ok := read_http_headers(client)
	defer delete(head)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 101 Switching Protocols\r\n"))
	testing.expect(t, strings.contains(head, "Upgrade: websocket\r\n"))

	frame := []u8{0x81, 0x05, 'h', 'e', 'l', 'l', 'o'}
	testing.expect_value(t, trans.connection_write(client, frame), trans.TransportError.None)
	echoed, eok := read_n_bytes(client, leftover, len(frame))
	defer delete(leftover)
	defer delete(echoed)
	testing.expect(t, eok)
	testing.expect_value(t, len(echoed), len(frame))
	testing.expect_value(t, string(echoed), string(frame))
}

@(test)
test_terminated_origin_eof_half_closes_browser_read :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .EchoHalfClose)
	defer stop_terminated_stack(&st)

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/half", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	tmp: [16]u8
	_, rerr := trans.connection_read(client, tmp[:])
	testing.expect(t, rerr == .Closed || rerr == .Tls)
	trans.connection_destroy(client)

	client2 := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client2)
	testing.expect_value(
		t,
		write_http_request(client2, "GET", "/still-up", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	head2, body2, ok2 := read_http_message(client2)
	defer delete(head2)
	defer delete(body2)
	testing.expect(t, ok2)
	testing.expect(t, strings.has_prefix(head2, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head2, "X-Echo-Target: /still-up\r\n"))
}

@(test)
test_terminated_browser_shutdown_write_after_request :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .EchoClose)
	defer stop_terminated_stack(&st)

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(
		t,
		write_http_request(client, "GET", "/after-shutdown", TEST_PUBLIC_HOST, nil),
		trans.TransportError.None,
	)
	start := time.now()
	for time.since(start) < 2 * time.Second {
		sync.mutex_lock(&st.origin.mutex)
		got := st.origin.requests
		sync.mutex_unlock(&st.origin.mutex)
		if got >= 1 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, st.origin.requests >= 1)
	testing.expect_value(t, trans.connection_shutdown_write(client), trans.TransportError.None)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(head, "X-Echo-Target: /after-shutdown\r\n"))
}

@(test)
test_terminated_two_simultaneous_connections_one_route :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .EchoClose)
	defer stop_terminated_stack(&st)

	jobs := [2]StreamClientJob {
		{
			ep          = st.ep,
			cert_path   = st.cert_path,
			server_name = TEST_PUBLIC_HOST,
			target      = "/alpha",
			host        = TEST_PUBLIC_HOST,
		},
		{
			ep          = st.ep,
			cert_path   = st.cert_path,
			server_name = TEST_PUBLIC_HOST,
			target      = "/beta",
			host        = TEST_PUBLIC_HOST,
		},
	}
	th0 := thread.create_and_start_with_poly_data(&jobs[0], stream_client_get)
	th1 := thread.create_and_start_with_poly_data(&jobs[1], stream_client_get)
	if th0 != nil {
		thread.join(th0)
		thread.destroy(th0)
	}
	if th1 != nil {
		thread.join(th1)
		thread.destroy(th1)
	}
	testing.expect(t, jobs[0].ok)
	testing.expect(t, jobs[1].ok)
	testing.expect(t, strings.contains(stream_client_head(&jobs[0]), "X-Echo-Target: /alpha\r\n"))
	testing.expect(t, strings.contains(stream_client_head(&jobs[1]), "X-Echo-Target: /beta\r\n"))
	testing.expect(t, !strings.contains(stream_client_head(&jobs[0]), "X-Echo-Target: /beta\r\n"))
	testing.expect(t, !strings.contains(stream_client_head(&jobs[1]), "X-Echo-Target: /alpha\r\n"))
	testing.expect_value(t, st.origin.requests, 2)
}

@(test)
test_terminated_two_routes_concurrent_without_cross_talk :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin_a: HttpOriginFixture
	ep_a := start_http_origin(t, &origin_a, .EchoClose)
	defer stop_http_origin(&origin_a)
	origin_b: HttpOriginFixture
	ep_b := start_http_origin(t, &origin_b, .EchoClose)
	defer stop_http_origin(&origin_b)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent_services(
		t,
		&fx,
		&agent,
		&run,
		[]AgentServiceTarget {
			{service = TEST_SERVICE, target = ep_a},
			{service = TEST_SERVICE_B, target = ep_b},
		},
	)
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
		[]string{"ingress.test=demo/echo", "other.test=demo/other"},
	)
	defer stop_full_ingress(&server)

	listen_ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	jobs := [2]StreamClientJob {
		{
			ep          = listen_ep,
			cert_path   = cert_path,
			server_name = TEST_PUBLIC_HOST,
			target      = "/route-a",
			host        = TEST_PUBLIC_HOST,
		},
		{
			ep          = listen_ep,
			cert_path   = cert_path,
			server_name = TEST_OTHER_HOST,
			target      = "/route-b",
			host        = TEST_OTHER_HOST,
		},
	}
	th0 := thread.create_and_start_with_poly_data(&jobs[0], stream_client_get)
	th1 := thread.create_and_start_with_poly_data(&jobs[1], stream_client_get)
	if th0 != nil {
		thread.join(th0)
		thread.destroy(th0)
	}
	if th1 != nil {
		thread.join(th1)
		thread.destroy(th1)
	}
	testing.expect(t, jobs[0].ok)
	testing.expect(t, jobs[1].ok)
	testing.expect(t, strings.contains(stream_client_head(&jobs[0]), "X-Echo-Host: ingress.test\r\n"))
	testing.expect(t, strings.contains(stream_client_head(&jobs[0]), "X-Echo-Target: /route-a\r\n"))
	testing.expect(t, strings.contains(stream_client_head(&jobs[1]), "X-Echo-Host: other.test\r\n"))
	testing.expect(t, strings.contains(stream_client_head(&jobs[1]), "X-Echo-Target: /route-b\r\n"))
	testing.expect(t, !strings.contains(stream_client_head(&jobs[0]), "other.test"))
	testing.expect(t, !strings.contains(stream_client_head(&jobs[1]), "ingress.test"))
	testing.expect_value(t, origin_a.requests, 1)
	testing.expect_value(t, origin_b.requests, 1)
}

@(test)
test_terminated_slow_writer_does_not_corrupt_sibling :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st, .EchoClose)
	defer stop_terminated_stack(&st)

	slow := StreamClientJob {
		ep          = st.ep,
		cert_path   = st.cert_path,
		server_name = TEST_PUBLIC_HOST,
		target      = "/slow",
		host        = TEST_PUBLIC_HOST,
	}
	fast := StreamClientJob {
		ep          = st.ep,
		cert_path   = st.cert_path,
		server_name = TEST_PUBLIC_HOST,
		target      = "/fast",
		host        = TEST_PUBLIC_HOST,
	}
	th_slow := thread.create_and_start_with_poly_data(&slow, stream_client_get)
	time.sleep(20 * time.Millisecond)
	th_fast := thread.create_and_start_with_poly_data(&fast, stream_client_get)
	if th_fast != nil {
		thread.join(th_fast)
		thread.destroy(th_fast)
	}
	if th_slow != nil {
		thread.join(th_slow)
		thread.destroy(th_slow)
	}
	testing.expect(t, fast.ok)
	testing.expect(t, strings.has_prefix(stream_client_head(&fast), "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(stream_client_head(&fast), "X-Echo-Target: /fast\r\n"))
	testing.expect(t, !strings.contains(stream_client_head(&fast), "X-Echo-Target: /slow\r\n"))
	testing.expect(t, slow.ok)
	testing.expect(t, strings.contains(stream_client_head(&slow), "X-Echo-Target: /slow\r\n"))
	testing.expect_value(t, slow.body_len, SLOW_WRITE_SIZE)
}
