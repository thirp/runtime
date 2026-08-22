package web_ingress

import ag "../agent"
import auth "../auth"
import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

TEST_TOKEN_HOST :: "host-dev-token"
TEST_TOKEN_CALLER :: "caller-dev-token"
TEST_PRINCIPAL_HOST :: "host-a"
TEST_PRINCIPAL_CALLER :: "client-a"
TEST_SERVICE :: "demo/echo"
TEST_SERVICE_B :: "demo/other"
TEST_SERVICE_SECURE :: "demo/secure"
TEST_PUBLIC_HOST :: "ingress.test"
TEST_OTHER_HOST :: "other.test"
TEST_SECURE_HOST :: "secure.test"

CHUNKED_WIRE :: "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
CHUNKED_PAYLOAD :: "hello world"
SSE_EVENT_1 :: "data: one\n\n"
SSE_EVENT_2 :: "data: two\n\n"
SSE_EVENT_3 :: "data: three\n\n"
SLOW_WRITE_SIZE :: 32 * 1024
SLOW_WRITE_CHUNK :: 256
SLOW_WRITE_SLEEP :: 5 * time.Millisecond
STREAM_ECHO_SIZE :: 1024 * 1024

HttpOriginKind :: enum {
	EchoClose,
	EchoKeepAlive,
	EchoHalfClose,
	Chunked,
	Sse,
	WebSocketEcho,
	StreamEcho,
	SlowWrite,
}

INGRESS_TEST_CERT :: string(#load("testdata/ingress.crt"))
INGRESS_TEST_KEY :: string(#load("testdata/ingress.key"))
ORIGIN_TEST_CERT :: string(#load("testdata/origin.crt"))
ORIGIN_TEST_KEY :: string(#load("testdata/origin.key"))

tls_temp_seq: int

write_temp_pem :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&tls_temp_seq, 1)
	path = fmt.aprintf("/tmp/thirp-ingress-%s-%d.pem", label, n)
	err := os.write_entire_file(path, transmute([]u8)contents)
	if err != nil {
		delete(path)
		return "", false
	}
	return path, true
}

remove_temp_pem :: proc(path: string) {
	_ = os.remove(path)
	delete(path)
}

TestBroker :: struct {
	reg:    brk.Registry,
	store:  auth.StaticTokenAuth,
	server: brk.Server,
}

AgentRunArg :: struct {
	agent: ^ag.Agent,
}

HttpOriginFixture :: struct {
	allocator:     mem.Allocator,
	ln:            trans.Listener,
	th:            ^thread.Thread,
	kind:          HttpOriginKind,
	tls_ctx:       ^trans.TlsServerContext,
	mutex:         sync.Mutex,
	cond:          sync.Cond,
	requests:      int,
	method:        string,
	target:        string,
	host:          string,
	body:          [dynamic]u8,
	active_conns:  int,
	sse_got_first: bool,
}

HttpOriginWorker :: struct {
	fx: ^HttpOriginFixture,
}

HttpOriginConnArg :: struct {
	fx:   ^HttpOriginFixture,
	conn: ^trans.Connection,
}

AgentServiceTarget :: struct {
	service: string,
	target:  net.Endpoint,
}

start_test_broker :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) {
	testing.expect_value(t, brk.registry_init(&fx.reg), brk.RegistryError.None, loc)
	testing.expect_value(t, auth.auth_init(&fx.store), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(&fx.store, TEST_TOKEN_HOST, TEST_PRINCIPAL_HOST), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(&fx.store, TEST_TOKEN_CALLER, TEST_PRINCIPAL_CALLER), auth.AuthError.None, loc)
	brk.server_init(&fx.server, &fx.reg, auth.static_token_authenticator(&fx.store))
	brk.server_disable_test_hardening(&fx.server)
	fx.server.heartbeat_interval = 30 * time.Second
	fx.server.session_timeout = 30 * time.Second
	testing.expect_value(t, brk.server_listen(&fx.server, trans.loopback_endpoint(0)), trans.TransportError.None, loc)
	brk.server_start(&fx.server)
}

apply_production_policy :: proc(
	t: ^testing.T,
	fx: ^TestBroker,
	allow_connect := true,
	loc := #caller_location,
) {
	testing.expect_value(
		t,
		brk.policy_set_capabilities(&fx.server.policy, TEST_PRINCIPAL_HOST, {.RegisterService}),
		brk.PolicyError.None,
		loc,
	)
	testing.expect_value(
		t,
		brk.policy_add_namespace_grant(&fx.server.policy, TEST_PRINCIPAL_HOST, "demo/*"),
		brk.PolicyError.None,
		loc,
	)
	testing.expect_value(
		t,
		brk.policy_set_capabilities(&fx.server.policy, TEST_PRINCIPAL_CALLER, {.ConnectService}),
		brk.PolicyError.None,
		loc,
	)
	if allow_connect {
		testing.expect_value(
			t,
			brk.policy_add_connect_grant(&fx.server.policy, TEST_PRINCIPAL_CALLER, TEST_SERVICE),
			brk.PolicyError.None,
			loc,
		)
	}
	fx.server.policy_mode = .Production
}

http_get_path :: proc(ep: net.Endpoint, path: string, allocator := context.allocator) -> (status_line: string, body: string, ok: bool) {
	conn, err := trans.connection_dial(ep)
	if err != .None || conn == nil {
		return "", "", false
	}
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
	req := fmt.tprintf("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", path)
	if trans.connection_write(conn, transmute([]u8)req) != .None {
		return "", "", false
	}
	buf := make([dynamic]u8, allocator)
	defer delete(buf)
	header_end := -1
	for len(buf) < 65536 {
		tmp: [1024]u8
		got, rerr := trans.connection_read(conn, tmp[:])
		if got > 0 {
			_, _ = append(&buf, ..tmp[:got])
		}
		header_end = index_header_end(buf[:])
		if header_end >= 0 {
			break
		}
		if rerr != .None || got == 0 {
			break
		}
	}
	if header_end < 0 {
		return "", "", false
	}
	text := string(buf[:])
	line_end := strings.index(text, "\r\n")
	if line_end < 0 {
		return "", "", false
	}
	headers := string(buf[:header_end])
	clen := http_content_length(headers)
	body_off := header_end + 4
	for clen > 0 && len(buf) - body_off < clen {
		tmp: [1024]u8
		got, rerr := trans.connection_read(conn, tmp[:])
		if got > 0 {
			_, _ = append(&buf, ..tmp[:got])
		}
		if rerr != .None || got == 0 {
			break
		}
	}
	status, _ := strings.clone(string(buf[:line_end]), allocator)
	end := len(buf)
	if clen >= 0 {
		end = min(len(buf), body_off + clen)
	}
	rest, _ := strings.clone(string(buf[body_off:end]), allocator)
	return status, rest, true
}

stop_test_broker :: proc(fx: ^TestBroker) {
	brk.server_stop(&fx.server)
	_ = brk.server_wait_idle(&fx.server, 2 * time.Second)
	brk.server_destroy(&fx.server)
	auth.auth_destroy(&fx.store)
	brk.registry_destroy(&fx.reg)
}

broker_endpoint :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) -> net.Endpoint {
	ep, err := brk.server_endpoint(&fx.server)
	testing.expect_value(t, err, trans.TransportError.None, loc)
	return ep
}

broker_endpoint_string :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) -> string {
	ep := broker_endpoint(t, fx, loc)
	text := net.endpoint_to_string(ep)
	owned, _ := strings.clone(text)
	return owned
}

wait_agent_connected :: proc(t: ^testing.T, agent: ^ag.Agent, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		if ag.agent_is_connected(agent) {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, loc = loc)
}

must_service :: proc(t: ^testing.T, value: string, loc := #caller_location) -> proto.ServiceId {
	id, err := proto.make_service_id(value)
	testing.expect_value(t, err, proto.ServiceIdError.None, loc)
	return id
}

start_registered_agent :: proc(
	t: ^testing.T,
	fx: ^TestBroker,
	target: net.Endpoint,
	agent: ^ag.Agent,
	run: ^AgentRunArg,
	service := TEST_SERVICE,
	loc := #caller_location,
) -> ^thread.Thread {
	return start_registered_agent_services(
		t,
		fx,
		agent,
		run,
		[]AgentServiceTarget{{service = service, target = target}},
		loc,
	)
}

start_registered_agent_services :: proc(
	t: ^testing.T,
	fx: ^TestBroker,
	agent: ^ag.Agent,
	run: ^AgentRunArg,
	services: []AgentServiceTarget,
	loc := #caller_location,
) -> ^thread.Thread {
	testing.expect_value(
		t,
		ag.agent_init(
			agent,
			ag.AgentConfig{broker = broker_endpoint(t, fx, loc), token = TEST_TOKEN_HOST, insecure = true},
		),
		ag.AgentError.None,
		loc,
	)
	for svc in services {
		testing.expect_value(
			t,
			ag.register_service(agent, must_service(t, svc.service, loc), ag.LocalTarget{address = svc.target}),
			ag.AgentError.None,
			loc,
		)
	}
	run.agent = agent
	th := thread.create_and_start_with_poly_data(run, agent_run_proc)
	wait_agent_connected(t, agent, loc)
	return th
}

agent_run_proc :: proc(arg: ^AgentRunArg) {
	_ = ag.agent_run(arg.agent)
}

stop_agent :: proc(agent: ^ag.Agent, th: ^thread.Thread) {
	ag.agent_stop(agent)
	if th != nil {
		thread.join(th)
		thread.destroy(th)
	}
	ag.agent_destroy(agent)
}

start_http_origin :: proc(
	t: ^testing.T,
	fx: ^HttpOriginFixture,
	kind := HttpOriginKind.EchoClose,
	loc := #caller_location,
) -> net.Endpoint {
	fx.allocator = context.allocator
	fx.kind = kind
	lerr: trans.TransportError
	fx.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	_ = trans.listener_set_recv_timeout(&fx.ln, 50 * time.Millisecond)
	ep, eerr := trans.listener_endpoint(fx.ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	fx.body = make([dynamic]u8, fx.allocator)
	worker := HttpOriginWorker{fx = fx}
	fx.th = thread.create_and_start_with_poly_data(worker, http_origin_accept_loop)
	return ep
}

stop_http_origin :: proc(fx: ^HttpOriginFixture) {
	trans.listener_close(&fx.ln)
	if fx.th != nil {
		thread.join(fx.th)
		thread.destroy(fx.th)
		fx.th = nil
	}
	http_origin_wait_idle(fx)
	if fx.tls_ctx != nil {
		trans.tls_server_context_destroy(fx.tls_ctx)
		fx.tls_ctx = nil
	}
	sync.mutex_lock(&fx.mutex)
	delete(fx.method, fx.allocator)
	delete(fx.target, fx.allocator)
	delete(fx.host, fx.allocator)
	delete(fx.body)
	sync.mutex_unlock(&fx.mutex)
}

start_https_origin :: proc(
	t: ^testing.T,
	fx: ^HttpOriginFixture,
	cert_path, key_path: string,
	kind := HttpOriginKind.EchoClose,
	loc := #caller_location,
) -> net.Endpoint {
	ctx, terr := trans.tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, terr, trans.TransportError.None, loc)
	fx.tls_ctx = ctx
	return start_http_origin(t, fx, kind, loc)
}

http_origin_conn_begin :: proc(fx: ^HttpOriginFixture) {
	sync.mutex_lock(&fx.mutex)
	fx.active_conns += 1
	sync.mutex_unlock(&fx.mutex)
}

http_origin_conn_end :: proc(fx: ^HttpOriginFixture) {
	sync.mutex_lock(&fx.mutex)
	fx.active_conns -= 1
	sync.cond_signal(&fx.cond)
	sync.mutex_unlock(&fx.mutex)
}

http_origin_wait_idle :: proc(fx: ^HttpOriginFixture) {
	sync.mutex_lock(&fx.mutex)
	for fx.active_conns > 0 {
		sync.cond_wait(&fx.cond, &fx.mutex)
	}
	sync.mutex_unlock(&fx.mutex)
}

http_origin_accept_loop :: proc(w: HttpOriginWorker) {
	for {
		conn, err := trans.listener_accept(&w.fx.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		arg, aerr := new(HttpOriginConnArg, w.fx.allocator)
		if aerr != .None {
			trans.connection_destroy(conn)
			continue
		}
		arg.fx = w.fx
		arg.conn = conn
		http_origin_conn_begin(w.fx)
		thread.run_with_poly_data(arg, http_origin_conn_proc)
	}
}

http_origin_conn_proc :: proc(arg: ^HttpOriginConnArg) {
	fx := arg.fx
	alloc := fx.allocator
	defer {
		trans.connection_destroy(arg.conn)
		free(arg, alloc)
		http_origin_conn_end(fx)
	}
	if fx.tls_ctx != nil {
		if trans.connection_tls_accept(arg.conn, fx.tls_ctx) != .None {
			return
		}
	}
	http_origin_serve(fx, arg.conn)
}

http_origin_serve :: proc(fx: ^HttpOriginFixture, conn: ^trans.Connection) {
	// StreamEcho pauses after the first request bytes so the client can read
	// response headers. A 2s SO_RCVTIMEO kills that pause under load.
	recv_timeout := 2 * time.Second
	if fx.kind == .StreamEcho {
		recv_timeout = 0
	}
	_ = trans.connection_set_recv_timeout(conn, recv_timeout)
	switch fx.kind {
	case .EchoKeepAlive:
		http_origin_keep_alive(fx, conn)
	case .WebSocketEcho:
		http_origin_websocket(fx, conn)
	case .StreamEcho:
		http_origin_stream_echo(fx, conn)
	case .Sse:
		http_origin_sse(fx, conn)
	case .Chunked:
		http_origin_chunked(fx, conn)
	case .EchoClose, .EchoHalfClose, .SlowWrite:
		http_origin_echo_request(fx, conn)
	}
}

HttpOriginRequest :: struct {
	method: string,
	target: string,
	host:   string,
	body:   []u8,
	close:  bool,
}

http_origin_read_headers :: proc(
	conn: ^trans.Connection,
	buf: ^[dynamic]u8,
) -> (
	headers: string,
	body_off: int,
	ok: bool,
) {
	header_end := -1
	for len(buf^) < 65536 {
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(buf, ..tmp[:n])
		}
		if err != .None && n == 0 {
			return "", 0, false
		}
		header_end = index_header_end(buf[:])
		if header_end >= 0 {
			break
		}
		if err != .None {
			return "", 0, false
		}
	}
	if header_end < 0 {
		return "", 0, false
	}
	return string(buf[:header_end]), header_end + 4, true
}

http_origin_parse_request_head :: proc(headers: string) -> (method, target, host: string, ok: bool) {
	line_end := strings.index(headers, "\r\n")
	if line_end < 0 {
		return "", "", "", false
	}
	method, target, ok = parse_request_line(headers[:line_end])
	if !ok {
		return "", "", "", false
	}
	return method, target, http_header_value(headers, "Host"), true
}

http_origin_record :: proc(fx: ^HttpOriginFixture, method, target, host: string, body: []u8) {
	sync.mutex_lock(&fx.mutex)
	delete(fx.method, fx.allocator)
	delete(fx.target, fx.allocator)
	delete(fx.host, fx.allocator)
	fx.method = strings.clone(method, fx.allocator)
	fx.target = strings.clone(target, fx.allocator)
	fx.host = strings.clone(host, fx.allocator)
	clear(&fx.body)
	if len(body) > 0 {
		_, _ = append(&fx.body, ..body)
	}
	fx.requests += 1
	sync.mutex_unlock(&fx.mutex)
}

http_origin_write_echo :: proc(
	conn: ^trans.Connection,
	method, target, host: string,
	body: []u8,
	keep_alive: bool,
) -> trans.TransportError {
	conn_token := keep_alive ? "keep-alive" : "close"
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\n" +
		"Content-Type: application/octet-stream\r\n" +
		"X-Echo-Method: %s\r\n" +
		"X-Echo-Target: %s\r\n" +
		"X-Echo-Host: %s\r\n" +
		"Content-Length: %d\r\n" +
		"Connection: %s\r\n" +
		"\r\n",
		method,
		target,
		host,
		len(body),
		conn_token,
	)
	defer delete(resp)
	if err := trans.connection_write(conn, transmute([]u8)resp); err != .None {
		return err
	}
	if len(body) > 0 {
		return trans.connection_write(conn, body)
	}
	return .None
}

http_origin_slow_write :: proc(conn: ^trans.Connection, target: string) {
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\n" +
		"Content-Type: application/octet-stream\r\n" +
		"X-Echo-Target: %s\r\n" +
		"Content-Length: %d\r\n" +
		"Connection: close\r\n" +
		"\r\n",
		target,
		SLOW_WRITE_SIZE,
	)
	_ = trans.connection_write(conn, transmute([]u8)resp)
	delete(resp)
	chunk: [SLOW_WRITE_CHUNK]u8
	for i in 0 ..< SLOW_WRITE_CHUNK {
		chunk[i] = 'S'
	}
	remaining := SLOW_WRITE_SIZE
	for remaining > 0 {
		n := min(remaining, SLOW_WRITE_CHUNK)
		if trans.connection_write(conn, chunk[:n]) != .None {
			return
		}
		remaining -= n
		time.sleep(SLOW_WRITE_SLEEP)
	}
}

http_origin_echo_request :: proc(fx: ^HttpOriginFixture, conn: ^trans.Connection) {
	buf := make([dynamic]u8)
	defer delete(buf)
	headers, body_off, ok := http_origin_read_headers(conn, &buf)
	if !ok {
		return
	}
	method, target, host, pok := http_origin_parse_request_head(headers)
	if !pok {
		return
	}
	clen := http_content_length(headers)
	for len(buf) - body_off < clen {
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		if err != .None {
			return
		}
	}
	body := buf[body_off:body_off + clen]
	http_origin_record(fx, method, target, host, body)
	if target == "/slow" || fx.kind == .SlowWrite {
		http_origin_slow_write(conn, target)
		return
	}
	_ = http_origin_write_echo(conn, method, target, host, body, false)
	if fx.kind == .EchoHalfClose {
		_ = trans.connection_shutdown_write(conn)
	}
}

http_origin_keep_alive :: proc(fx: ^HttpOriginFixture, conn: ^trans.Connection) {
	for {
		buf := make([dynamic]u8)
		headers, body_off, ok := http_origin_read_headers(conn, &buf)
		if !ok {
			delete(buf)
			return
		}
		method, target, host, pok := http_origin_parse_request_head(headers)
		if !pok {
			delete(buf)
			return
		}
		clen := http_content_length(headers)
		for len(buf) - body_off < clen {
			tmp: [1024]u8
			n, err := trans.connection_read(conn, tmp[:])
			if n > 0 {
				_, _ = append(&buf, ..tmp[:n])
			}
			if err != .None {
				delete(buf)
				return
			}
		}
		body := buf[body_off:body_off + clen]
		http_origin_record(fx, method, target, host, body)
		close := http_header_has_close(headers)
		_ = http_origin_write_echo(conn, method, target, host, body, !close)
		delete(buf)
		if close {
			return
		}
	}
}

http_origin_chunked :: proc(fx: ^HttpOriginFixture, conn: ^trans.Connection) {
	buf := make([dynamic]u8)
	defer delete(buf)
	headers, _, ok := http_origin_read_headers(conn, &buf)
	if !ok {
		return
	}
	method, target, host, pok := http_origin_parse_request_head(headers)
	if !pok {
		return
	}
	http_origin_record(fx, method, target, host, nil)
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\n" +
		"Content-Type: text/plain\r\n" +
		"X-Echo-Target: %s\r\n" +
		"Transfer-Encoding: chunked\r\n" +
		"Connection: close\r\n" +
		"\r\n" +
		"%s",
		target,
		CHUNKED_WIRE,
	)
	_ = trans.connection_write(conn, transmute([]u8)resp)
	delete(resp)
}

http_origin_sse :: proc(fx: ^HttpOriginFixture, conn: ^trans.Connection) {
	buf := make([dynamic]u8)
	defer delete(buf)
	headers, _, ok := http_origin_read_headers(conn, &buf)
	if !ok {
		return
	}
	method, target, host, pok := http_origin_parse_request_head(headers)
	if !pok {
		return
	}
	http_origin_record(fx, method, target, host, nil)
	head := "HTTP/1.1 200 OK\r\n" +
		"Content-Type: text/event-stream\r\n" +
		"Cache-Control: no-cache\r\n" +
		"Connection: keep-alive\r\n" +
		"\r\n"
	if trans.connection_write(conn, transmute([]u8)head) != .None {
		return
	}
	if trans.connection_write(conn, transmute([]u8)string(SSE_EVENT_1)) != .None {
		return
	}
	sync.mutex_lock(&fx.mutex)
	for !fx.sse_got_first {
		if !sync.cond_wait_with_timeout(&fx.cond, &fx.mutex, 2 * time.Second) {
			sync.mutex_unlock(&fx.mutex)
			return
		}
	}
	sync.mutex_unlock(&fx.mutex)
	_ = trans.connection_write(conn, transmute([]u8)string(SSE_EVENT_2))
	_ = trans.connection_write(conn, transmute([]u8)string(SSE_EVENT_3))
}

http_origin_signal_sse_first :: proc(fx: ^HttpOriginFixture) {
	sync.mutex_lock(&fx.mutex)
	fx.sse_got_first = true
	sync.cond_signal(&fx.cond)
	sync.mutex_unlock(&fx.mutex)
}

http_origin_websocket :: proc(fx: ^HttpOriginFixture, conn: ^trans.Connection) {
	buf := make([dynamic]u8)
	defer delete(buf)
	headers, body_off, ok := http_origin_read_headers(conn, &buf)
	if !ok {
		return
	}
	method, target, host, pok := http_origin_parse_request_head(headers)
	if !pok {
		return
	}
	http_origin_record(fx, method, target, host, nil)
	upgrade := http_header_value(headers, "Upgrade")
	if !http_token_equals_ignore_case(upgrade, "websocket") {
		_ = http_origin_write_echo(conn, method, target, host, nil, false)
		return
	}
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"\r\n"
	if trans.connection_write(conn, transmute([]u8)resp) != .None {
		return
	}
	if body_off < len(buf) {
		if trans.connection_write(conn, buf[body_off:]) != .None {
			return
		}
	}
	for {
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			if trans.connection_write(conn, tmp[:n]) != .None {
				return
			}
		}
		if err != .None {
			return
		}
	}
}

http_origin_stream_echo :: proc(fx: ^HttpOriginFixture, conn: ^trans.Connection) {
	buf := make([dynamic]u8)
	defer delete(buf)
	headers, body_off, ok := http_origin_read_headers(conn, &buf)
	if !ok {
		return
	}
	method, target, host, pok := http_origin_parse_request_head(headers)
	if !pok {
		return
	}
	clen := http_content_length(headers)
	http_origin_record(fx, method, target, host, nil)
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\n" +
		"Content-Type: application/octet-stream\r\n" +
		"X-Echo-Target: %s\r\n" +
		"Content-Length: %d\r\n" +
		"Connection: close\r\n" +
		"\r\n",
		target,
		clen,
	)
	if trans.connection_write(conn, transmute([]u8)resp) != .None {
		delete(resp)
		return
	}
	delete(resp)
	copied := 0
	if body_off < len(buf) {
		avail := min(len(buf) - body_off, clen)
		if avail > 0 {
			if trans.connection_write(conn, buf[body_off:body_off + avail]) != .None {
				return
			}
			copied += avail
		}
	}
	for copied < clen {
		tmp: [INGRESS_COPY_BUF]u8
		want := min(len(tmp), clen - copied)
		n, err := trans.connection_read(conn, tmp[:want])
		if n > 0 {
			if trans.connection_write(conn, tmp[:n]) != .None {
				return
			}
			copied += n
		}
		if err != .None {
			return
		}
	}
}

index_header_end :: proc(buf: []u8) -> int {
	return strings.index(string(buf), "\r\n\r\n")
}

parse_request_line :: proc(line: string) -> (method, target: string, ok: bool) {
	sp1 := strings.index_byte(line, ' ')
	if sp1 <= 0 {
		return "", "", false
	}
	rest := line[sp1 + 1:]
	sp2 := strings.index_byte(rest, ' ')
	if sp2 <= 0 {
		return "", "", false
	}
	return line[:sp1], rest[:sp2], true
}

http_header_value :: proc(headers, name: string) -> string {
	needle := fmt.tprintf("\r\n%s:", name)
	idx := strings.index(headers, needle)
	if idx < 0 {
		lowered := strings.to_lower(headers)
		defer delete(lowered)
		lname := strings.to_lower(name)
		defer delete(lname)
		needle = fmt.tprintf("\r\n%s:", lname)
		idx = strings.index(lowered, needle)
		if idx < 0 {
			return ""
		}
	}
	rest := headers[idx + 2:]
	colon := strings.index_byte(rest, ':')
	if colon < 0 {
		return ""
	}
	val := strings.trim_left_space(rest[colon + 1:])
	end := strings.index(val, "\r\n")
	if end >= 0 {
		val = val[:end]
	}
	return strings.trim_space(val)
}

http_content_length :: proc(headers: string) -> int {
	val := http_header_value(headers, "Content-Length")
	if len(val) == 0 {
		return 0
	}
	n, ok := strconv.parse_int(val)
	if !ok || n < 0 {
		return 0
	}
	return n
}

http_header_has_close :: proc(headers: string) -> bool {
	val := http_header_value(headers, "Connection")
	return http_token_equals_ignore_case(val, "close")
}

http_token_equals_ignore_case :: proc(value, want: string) -> bool {
	if len(value) != len(want) {
		return false
	}
	for i in 0 ..< len(value) {
		a := value[i]
		b := want[i]
		if a >= 'A' && a <= 'Z' {
			a += 32
		}
		if b >= 'A' && b <= 'Z' {
			b += 32
		}
		if a != b {
			return false
		}
	}
	return true
}

write_http_request :: proc(
	conn: ^trans.Connection,
	method, target, host: string,
	body: []u8,
	keep_alive := false,
	extra_headers := "",
) -> trans.TransportError {
	conn_token := keep_alive ? "keep-alive" : "close"
	header := fmt.aprintf(
		"%s %s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\nConnection: %s\r\n%s\r\n",
		method,
		target,
		host,
		len(body),
		conn_token,
		extra_headers,
	)
	defer delete(header)
	if err := trans.connection_write(conn, transmute([]u8)header); err != .None {
		return err
	}
	if len(body) > 0 {
		return trans.connection_write(conn, body)
	}
	return .None
}

read_http_headers :: proc(
	conn: ^trans.Connection,
	allocator := context.allocator,
) -> (
	head: string,
	leftover: []u8,
	ok: bool,
) {
	buf := make([dynamic]u8, allocator)
	header_end := -1
	for len(buf) < 65536 {
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		header_end = index_header_end(buf[:])
		if header_end >= 0 {
			break
		}
		if err != .None {
			break
		}
	}
	if header_end < 0 {
		delete(buf)
		return "", nil, false
	}
	body_off := header_end + 4
	head, _ = strings.clone(string(buf[:body_off]), allocator)
	if body_off < len(buf) {
		owned, _ := strings.clone(string(buf[body_off:]), allocator)
		leftover = transmute([]u8)owned
	}
	delete(buf)
	return head, leftover, true
}

read_until_closed :: proc(
	conn: ^trans.Connection,
	already: []u8,
	allocator := context.allocator,
) -> (
	[]u8,
	bool,
) {
	buf := make([dynamic]u8, allocator)
	if len(already) > 0 {
		_, _ = append(&buf, ..already)
	}
	for {
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		if err != .None {
			out := buf[:]
			return out, true
		}
	}
}

read_n_bytes :: proc(
	conn: ^trans.Connection,
	already: []u8,
	n: int,
	allocator := context.allocator,
) -> (
	[]u8,
	bool,
) {
	buf := make([dynamic]u8, allocator)
	if len(already) > 0 {
		_, _ = append(&buf, ..already)
	}
	for len(buf) < n {
		tmp: [1024]u8
		want := min(len(tmp), n - len(buf))
		got, err := trans.connection_read(conn, tmp[:want])
		if got > 0 {
			_, _ = append(&buf, ..tmp[:got])
		}
		if err != .None {
			break
		}
	}
	if len(buf) < n {
		return buf[:], false
	}
	return buf[:n], true
}

read_until_contains :: proc(
	conn: ^trans.Connection,
	already: []u8,
	needle: string,
	max_bytes := 65536,
	allocator := context.allocator,
) -> (
	[]u8,
	bool,
) {
	buf := make([dynamic]u8, allocator)
	if len(already) > 0 {
		_, _ = append(&buf, ..already)
	}
	for {
		if strings.contains(string(buf[:]), needle) {
			out := buf[:]
			return out, true
		}
		if len(buf) >= max_bytes {
			delete(buf)
			return nil, false
		}
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		if err != .None {
			delete(buf)
			return nil, false
		}
	}
}

read_http_message :: proc(conn: ^trans.Connection, allocator := context.allocator) -> (string, []u8, bool) {
	buf := make([dynamic]u8, allocator)
	header_end := -1
	for len(buf) < 65536 {
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		header_end = index_header_end(buf[:])
		if header_end >= 0 {
			break
		}
		if err != .None {
			break
		}
	}
	if header_end < 0 {
		text := strings.clone(string(buf[:]), allocator)
		delete(buf)
		return text, nil, false
	}
	headers := string(buf[:header_end])
	clen := http_content_length(headers)
	body_off := header_end + 4
	for len(buf) - body_off < clen {
		tmp: [1024]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		if err != .None {
			break
		}
	}
	head, _ := strings.clone(string(buf[:body_off]), allocator)
	body_str, _ := strings.clone(string(buf[body_off:min(len(buf), body_off + clen)]), allocator)
	delete(buf)
	return head, transmute([]u8)body_str, true
}

dial_ingress_tls :: proc(
	t: ^testing.T,
	ep: net.Endpoint,
	cert_path: string,
	server_name: string,
	omit_sni := false,
	loc := #caller_location,
) -> ^trans.Connection {
	cfg := trans.TlsClientConfig {
		ca_path     = cert_path,
		server_name = server_name,
		omit_sni    = omit_sni,
	}
	client, err := trans.connection_dial_tls(ep, cfg)
	testing.expect_value(t, err, trans.TransportError.None, loc)
	testing.expect(t, client != nil, loc = loc)
	return client
}

dial_passthrough_tls :: proc(
	t: ^testing.T,
	ep: net.Endpoint,
	origin_ca_path: string,
	server_name: string,
	loc := #caller_location,
) -> ^trans.Connection {
	return dial_ingress_tls(t, ep, origin_ca_path, server_name, loc = loc)
}
