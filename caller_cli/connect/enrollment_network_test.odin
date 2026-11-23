package connect

// Run outside the workspace sandbox: this is the real verified HTTPS client,
// broker TLS setup and two real listeners. Maintenance policy is also covered
// separately by the socket-free fake-clock/HTTP tests.
import auth "../../auth"
import cl "../../caller"
import log "../../logging"
import trans "../../transport"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Allow a synchronous HTTPS timeout, a broker dial timeout, and retry/scheduling slack.
ENROLLMENT_TEST_CONVERGE :: ENROLLMENT_HTTP_TIMEOUT + cl.DEFAULT_DIAL_TIMEOUT + 5*time.Second
ENROLLMENT_TEST_FAILURE_BOUND :: 2*time.Second
// Test-only certificate for DNS:localhost. The broker's 127.0.0.1 identity is absent.
ENROLLMENT_API_TEST_CERT :: string(#load("testdata/api-localhost.crt"))
ENROLLMENT_API_TEST_KEY :: string(#load("testdata/api-localhost.key"))

EnrollmentTestApi :: struct {
	f: ^EnrollmentFixture,
	ln: trans.Listener,
	tls: ^trans.TlsServerContext,
	allocator: mem.Allocator,
	stop: bool,
	drop_first: int,
	delay: time.Duration,
	dropped: int, // atomic; only the API thread increments it
	tls_rejected: int, // atomic
	localhost_sni: bool, // atomic
}

enrollment_test_api_connection :: proc(a: ^EnrollmentTestApi, c: ^trans.Connection) {
	defer trans.connection_destroy(c)
	if sync.atomic_load(&a.dropped) < a.drop_first {
		sync.atomic_add(&a.dropped, 1)
		return
	}
	if err := trans.connection_tls_accept(c, a.tls, 10*time.Second); err != .None {
		if err == .Tls {sync.atomic_add(&a.tls_rejected, 1)}
		return
	}
	if trans.connection_tls_servername(c) == "localhost" {sync.atomic_store(&a.localhost_sni, true)}
	_ = trans.connection_set_recv_timeout(c, 10*time.Second)
	_ = trans.connection_set_send_timeout(c, 10*time.Second)
	raw: [dynamic]u8
	defer delete(raw)
	buf: [4096]u8
	for len(raw) < ENROLLMENT_HTTP_MAX {
		n, err := trans.connection_read(c, buf[:])
		if err != .None {return}
		append(&raw, ..buf[:n])
		text := string(raw[:])
		end := strings.index(text, "\r\n\r\n")
		if end < 0 {continue}
		lines := strings.split(text[:end], "\r\n")
		defer delete(lines)
		first := strings.fields(lines[0])
		defer delete(first)
		if len(first) != 3 {return}
		req := EnrollmentRequest{method = first[0], path = first[1]}
		length := -1
		for line in lines[1:] {
			split := strings.index_byte(line, ':')
			if split < 0 {return}
			value := strings.trim_space(line[split+1:])
			if strings.equal_fold(line[:split], ENROLLMENT_HEADER_CONTENT_LENGTH) {length, _ = strconv.parse_int(value)}
			if strings.equal_fold(line[:split], ENROLLMENT_HEADER_AUTHORIZATION) {req.bearer = strings.trim_prefix(value, ENROLLMENT_BEARER)}
		}
		if length < 0 {return}
		if len(text)-end-4 < length {continue}
		req.body = text[end+4:]
		r, _ := enrollment_test_http(a.f, &a.f.cfg, req)
		defer delete(r.body)
		wire := fmt.aprintf("%s %d OK\r\n%s: %s\r\n%s: %d\r\n%s: %s\r\n\r\n%s",
			ENROLLMENT_HTTP_VERSION, r.status, ENROLLMENT_HEADER_CONTENT_TYPE, ENROLLMENT_JSON,
			ENROLLMENT_HEADER_CONTENT_LENGTH, len(r.body), ENROLLMENT_HEADER_CONNECTION, ENROLLMENT_CLOSE, r.body)
		defer delete(wire)
		if a.delay > 0 {time.sleep(a.delay)}
		_ = trans.connection_write(c, transmute([]u8)wire)
		return
	}
}

enrollment_test_api_serve :: proc(a: ^EnrollmentTestApi) {
	context.allocator = a.allocator
	for !sync.atomic_load(&a.stop) {
		if trans.listener_wait_acceptable(&a.ln, ACCEPT_POLL) != .None {continue}
		c, err := trans.listener_accept(&a.ln)
		if err == .None {enrollment_test_api_connection(a, c)}
	}
}

enrollment_test_api_hostname_mismatch :: proc(t: ^testing.T, f: ^EnrollmentFixture, ln: trans.Listener) {
	// This certificate is trusted below and covers 127.0.0.1 and secure.test.
	// localhost still resolves to this listener and must fail DNS verification.
	cert, cert_ok := connect_write_temp_pem("wrong-name-cert", string(#load("../../web_ingress/testdata/origin.crt")))
	defer {if cert_ok {_ = os.remove(cert); delete(cert)}}
	key, key_ok := connect_write_temp_pem("wrong-name-key", string(#load("../../web_ingress/testdata/origin.key")))
	defer {if key_ok {_ = os.remove(key); delete(key)}}
	if !testing.expect(t, cert_ok && key_ok, "mismatched hostname certificate fixture") {return}
	tls, terr := trans.tls_server_context_init(cert, key)
	testing.expect_value(t, terr, trans.TransportError.None)
	if terr != .None {return}
	defer trans.tls_server_context_destroy(tls)
	a := EnrollmentTestApi{f = f, ln = ln, tls = tls, allocator = context.allocator}
	th := thread.create_and_start_with_poly_data(&a, enrollment_test_api_serve)
	if !testing.expect(t, th != nil, "mismatched hostname API server started") {return}
	defer {sync.atomic_store(&a.stop, true); thread.join(th); thread.destroy(th)}

	cfg := f.cfg
	cfg.api_tls_ca = cert
	req := EnrollmentRequest{ENROLLMENT_GET, ENROLLMENT_ORGS+"org-a"+ENROLLMENT_SELF, f.e.token, ""}
	r, err := enrollment_network_http(nil, &cfg, req)
	testing.expect_value(t, err, EnrollmentError.Retry)
	testing.expect_value(t, r.failure, "tls_verify")
	if err == .Retry && r.failure == "tls_verify" {
		fmt.println("A3: correct API CA rejected the localhost hostname mismatch as tls_verify")
	}
	delete(r.body)

	// The same CA, server, and request work through the certificate's IP SAN.
	ep, _ := trans.listener_endpoint(ln)
	cfg.api = fmt.tprintf("https://127.0.0.1:%d", ep.port)
	r, err = enrollment_network_http(nil, &cfg, req)
	defer delete(r.body)
	testing.expect_value(t, err, EnrollmentError.None)
	testing.expect_value(t, r.status, ENROLLMENT_STATUS_OK)
	if err == .None && r.status == ENROLLMENT_STATUS_OK {
		fmt.println("A3: the same API CA and server accepted the certificate's IP SAN")
	}
}

@(test)
test_enrollment_network_verified_https_and_multiple_listeners :: proc(t: ^testing.T) {
	enrollment_test_network_case(t)
}

@(test)
test_enrollment_network_converges_after_dropped_api_requests :: proc(t: ^testing.T) {
	enrollment_test_network_case(t, dropped_requests = true)
}

enrollment_test_network_case :: proc(t: ^testing.T, dropped_requests := false) {
	fx: Fixture
	if !fixture_start(t, &fx, use_tls = true) {return}
	defer fixture_stop(&fx)
	testing.expect_value(t, auth.auth_add_token(&fx.store, ENROLLMENT_TEST_GRANT_TOKEN, "client-a"), auth.AuthError.None)
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	// A caller/bridge logger is called on several runtime threads.
	log.logger_init(&f.e.logger, .Info)
	defer enrollment_fixture_destroy(&f)
	f.at = time.now()
	f.expiry = time.time_add(f.at, 90*24*time.Hour)
	f.wire_service = T_SERVICE
	f.cfg.broker, f.cfg.tls_server_name = fx.broker, "127.0.0.1"
	f.cfg.tls_ca = strings.clone(fx.tls_cert)
	if dropped_requests {
		// Authenticate in the fixture first so all injected failures exercise
		// link backoff, rather than the separate GET-self polling schedule.
		f.e.now = nil
		testing.expect_value(t, enrollment_self(&f.e), EnrollmentError.None)
		f.e.self_next = time.time_add(time.now(), ENROLLMENT_TEST_CONVERGE)
	}
	f.e.http, f.e.new_caller, f.e.destroy_caller = nil, nil, nil
	delete(f.e.links)
	f.e.links = make([]EnrollmentLink, 2)
	defer {
		for &l in f.e.links {sync.atomic_store(&l.stop, true)}
		for &l in f.e.links {
			if l.accept_th != nil {thread.join(l.accept_th); thread.destroy(l.accept_th)}
			if l.job != nil {
				thread.join(l.job.th); thread.destroy(l.job.th)
				if l.job.caller != nil {l.job.caller.force = true; append(&l.retired, l.job.caller)}
				free(l.job); l.job = nil
			}
			if l.opened {trans.listener_close(&l.ln)}
		}
	}
	for &l, i in f.e.links {
		l.cfg, l.stall = f.cfg.links[i], time.Second
		var_err: trans.TransportError
		l.ln, var_err = trans.listener_listen(trans.loopback_endpoint(0))
		testing.expect_value(t, var_err, trans.TransportError.None)
		if var_err != .None {return}
		l.opened = true
		append(&f.grants, EnrollmentTestGrant{fmt.tprintf("grant-%d", i), l.cfg.service, "env-a", f.at, time.time_add(f.at, time.Hour)})
	}
	cert, cert_ok := connect_write_temp_pem("api-cert", ENROLLMENT_API_TEST_CERT)
	defer {if cert_ok {_ = os.remove(cert); delete(cert)}}
	key, key_ok := connect_write_temp_pem("api-key", ENROLLMENT_API_TEST_KEY)
	defer {if key_ok {_ = os.remove(key); delete(key)}}
	testing.expect(t, cert_ok && key_ok, "API certificate fixture")
	if !cert_ok || !key_ok {return}
	f.cfg.api_tls_ca = strings.clone(cert)
	tls, terr := trans.tls_server_context_init(cert, key)
	testing.expect_value(t, terr, trans.TransportError.None)
	if terr != .None {return}
	defer trans.tls_server_context_destroy(tls)
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	if lerr != .None {return}
	defer trans.listener_close(&ln)
	ep, _ := trans.listener_endpoint(ln)
	api := fmt.aprintf("https://localhost:%d", ep.port)
	defer delete(api)
	f.cfg.api = api
	if !dropped_requests {enrollment_test_api_hostname_mismatch(t, &f, ln)}
	a := EnrollmentTestApi{f = &f, ln = ln, tls = tls, allocator = context.allocator}
	minimum_retry_time: time.Duration
	if dropped_requests {
		when #config(THIRP_LAB_TIMERS, false) {
			// Two links share the drops: at least one gets eight retries.
			a.drop_first = 16
		} else {
			// Production backoff starts at 1s; keep this variant short.
			a.drop_first = 2
		}
		a.delay = 300*time.Millisecond
		backoff, maximum, _, _ := enrollment_intervals()
		for _ in 0..<(a.drop_first+len(f.e.links)-1)/len(f.e.links) {
			minimum_retry_time += backoff
			backoff = min(backoff*2, maximum)
		}
		when #config(THIRP_LAB_TIMERS, false) {
			// 100ms + 200 + 400 + 800 + 1s + 1s + 1s + 1s = 5.5s.
			testing.expect(t, minimum_retry_time > 5*time.Second, "retry schedule exceeds the old convergence budget")
		}
	}
	th := thread.create_and_start_with_poly_data(&a, enrollment_test_api_serve)
	testing.expect(t, th != nil)
	if th == nil {return}
	defer {sync.atomic_store(&a.stop, true); thread.join(th); thread.destroy(th)}
	if !dropped_requests {
		req := EnrollmentRequest{ENROLLMENT_GET, ENROLLMENT_ORGS+"org-a"+ENROLLMENT_SELF, f.e.token, ""}
		// The broker CA cannot verify this API. Putting it in the API slot
		// must fail even though the HTTPS URL and the broker config are valid.
		wrong_ca := f.cfg
		wrong_ca.api_tls_ca = f.cfg.tls_ca
		r, err := enrollment_network_http(nil, &wrong_ca, req)
		testing.expect_value(t, err, EnrollmentError.Retry)
		testing.expect_value(t, r.failure, "tls_verify")
		if err == .Retry && r.failure == "tls_verify" {
			fmt.println("A3: the broker CA was rejected for the API as tls_verify")
		}
		delete(r.body)
	}
	start := time.now()
	for f.e.links[0].current == nil || f.e.links[1].current == nil {
		testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None)
		if time.since(start) >= ENROLLMENT_TEST_CONVERGE {
			for l, i in f.e.links {
				fmt.eprintf("enrollment convergence timeout: link %d current=%p job=%p next=%v backoff=%v\n", i, l.current, l.job, l.next, l.backoff)
			}
			break
		}
		time.sleep(5*time.Millisecond)
	}
	elapsed := time.since(start)
	testing.expectf(t, elapsed < ENROLLMENT_TEST_CONVERGE, "enrollment convergence took %v (bound %v)", elapsed, ENROLLMENT_TEST_CONVERGE)
	testing.expect(t, sync.atomic_load(&a.localhost_sni), "API saw the URL hostname as SNI")
	if dropped_requests {
		testing.expect(t, sync.atomic_load(&a.dropped) >= a.drop_first, "API requests were dropped")
		testing.expectf(t, elapsed >= minimum_retry_time, "convergence %v was shorter than injected retry backoff %v", elapsed, minimum_retry_time)
	}
	for &l in f.e.links {
		testing.expect(t, l.current != nil)
		if l.current == nil {return}
		l.accept_th = thread.create_and_start_with_poly_data(&l, enrollment_accept)
		testing.expect(t, l.accept_th != nil)
		bound, _ := trans.listener_endpoint(l.ln)
		ctl := RunControl{bound = bound}
		expect_echo(t, &ctl, "enrolled-link")
	}
	if !dropped_requests && !testing.failed(t) {
		fmt.println("A3: API saw localhost as SNI and both listeners carried echo bytes end to end")
	}
}

EnrollmentFailureCase :: enum {Untrusted_API, Unauthorized_API, Unauthorized_Broker, Unknown_Service}

// LogSink has no user argument. These cases hold the mutex until all their
// caller threads have joined, so other tests can still run in parallel.
enrollment_failure_test_mutex: sync.Mutex
enrollment_failure_test_expected: string
enrollment_failure_test_count, enrollment_failure_test_connected: int

enrollment_failure_test_sink :: proc(line: string) {
	if strings.contains(line, enrollment_failure_test_expected) {
		sync.atomic_add(&enrollment_failure_test_count, 1)
	}
	if strings.contains(line, `"event":"caller connected"`) {
		sync.atomic_add(&enrollment_failure_test_connected, 1)
	}
}

@(test)
test_enrollment_caller_conf_untrusted_api_closes_local :: proc(t: ^testing.T) {
	enrollment_failure_network_case(t, .Untrusted_API, `"reason":"tls_verify","phase":"api"`)
}

@(test)
test_enrollment_caller_conf_unauthorized_api_closes_local :: proc(t: ^testing.T) {
	enrollment_failure_network_case(t, .Unauthorized_API, `"error_code":"401","reason":"unauthorized_or_revoked","phase":"api"`)
}

@(test)
test_enrollment_caller_conf_unauthorized_broker_closes_local :: proc(t: ^testing.T) {
	enrollment_failure_network_case(t, .Unauthorized_Broker, `"reason":"unauthorized_or_revoked","phase":"handshake"`)
}

@(test)
test_enrollment_caller_conf_unknown_service_closes_local :: proc(t: ^testing.T) {
	enrollment_failure_network_case(t, .Unknown_Service, `"reason":"unknown_service","phase":"stream"`)
}

enrollment_failure_network_case :: proc(t: ^testing.T, scenario: EnrollmentFailureCase, expected: string) {
	sync.mutex_lock(&enrollment_failure_test_mutex)
	defer sync.mutex_unlock(&enrollment_failure_test_mutex)
	enrollment_failure_test_expected = expected
	sync.atomic_store(&enrollment_failure_test_count, 0)
	sync.atomic_store(&enrollment_failure_test_connected, 0)
	fx: Fixture
	if !fixture_start(t, &fx, use_tls = true) {return}
	defer fixture_stop(&fx)
	if scenario == .Unknown_Service {
		testing.expect_value(t, auth.auth_add_token(&fx.store, ENROLLMENT_TEST_GRANT_TOKEN, "client-a"), auth.AuthError.None)
	}
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, support = true)
	defer enrollment_fixture_destroy(&f)
	f.at = time.now()
	f.expiry = time.time_add(f.at, 90*24*time.Hour)
	f.deny_self = scenario == .Unauthorized_API
	f.wire_service = scenario == .Unknown_Service ? "demo/not-registered" : T_SERVICE
	enrollment_test_grant(&f, time.time_add(f.at, time.Hour))
	tls, terr := trans.tls_server_context_init(fx.tls_cert, fx.tls_key)
	testing.expect_value(t, terr, trans.TransportError.None)
	if terr != .None {return}
	defer trans.tls_server_context_destroy(tls)
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	if lerr != .None {return}
	defer trans.listener_close(&ln)
	ep, _ := trans.listener_endpoint(ln)
	a := EnrollmentTestApi{f = &f, ln = ln, tls = tls, allocator = context.allocator}
	api_thread := thread.create_and_start_with_poly_data(&a, enrollment_test_api_serve)
	testing.expect(t, api_thread != nil)
	if api_thread == nil {return}
	defer {sync.atomic_store(&a.stop, true); thread.join(api_thread); thread.destroy(api_thread)}
	dir, dir_err := os.make_directory_temp("", "thirp-enrollment-diagnostics-*", context.allocator)
	testing.expect(t, dir_err == nil, "private file fixture directory")
	if dir_err != nil {return}
	defer { _ = os.remove_all(dir); delete(dir) }
	conf, _ := filepath.join({dir, "caller.conf"})
	defer delete(conf)
	token, _ := filepath.join({dir, "caller.token"})
	defer delete(token)
	ca := fx.tls_cert
	if scenario == .Untrusted_API {
		other, _ := filepath.join({dir, "unrelated.crt"})
		defer delete(other)
		cert_err := os.write_entire_file(other, #load("../../transport/testdata/unrelated.crt"))
		testing.expect(t, cert_err == nil, "unrelated CA fixture")
		if cert_err != nil {return}
		ca = "unrelated.crt"
	}
	contents := fmt.aprintf(`api = https://127.0.0.1:%d
org = org-a
environment = env-a
enrollment = enrollment-a
token_file = caller.token
broker = %s
tls_server_name = 127.0.0.1
tls_ca = %s
api_tls_ca = %s
service = svc-a listen = 127.0.0.1:0
`, ep.port, fx.broker, ca, ca)
	defer delete(contents)
	private := enrollment_test_write_private(token, ENROLLMENT_TEST_TOKEN+"\n") && enrollment_test_write_private(conf, contents)
	testing.expect(t, private, "write private caller.conf and token")
	if !private {return}
	ctl := RunControl{enrollment_log_sink = enrollment_failure_test_sink}
	r := RunArg{args = {"--caller-conf", conf}, ctl = &ctl}
	th := start_connect(t, &r)
	testing.expect(t, th != nil)
	if th == nil {return}
	defer stop_connect(&r, th)
	if !testing.expect(t, sync.atomic_load(&ctl.ready), "caller-conf listener bound") {return}
	if scenario == .Untrusted_API {
		if !testing.expect(t, enrollment_test_wait_count(&a.tls_rejected), "caller reached the API and the TLS handshake failed") {return}
		fmt.println("A1: API rejected the untrusted TLS handshake")
	}
	if scenario == .Unknown_Service {
		if !enrollment_test_wait_count(&enrollment_failure_test_connected) {
			testing.expect(t, false, "broker session was admitted")
			return
		}
	} else if scenario == .Untrusted_API {
		testing.expect(t, enrollment_test_wait_count(&enrollment_failure_test_count), "A1: missing TLS verification diagnostic")
	} else {
		testing.expectf(t, enrollment_test_wait_count(&enrollment_failure_test_count), "expected log fields %s", expected)
	}
	enrollment_test_local_closed(t, &ctl)
	if scenario == .Untrusted_API && !testing.failed(t) {
		fmt.println("A1: caller logged tls_verify and the local client received EOF within two seconds")
	}
	if scenario == .Unknown_Service {
		testing.expectf(t, enrollment_test_wait_count(&enrollment_failure_test_count), "expected log fields %s", expected)
		for _ in 0..<8 {enrollment_test_local_closed(t, &ctl)}
		testing.expect(t, sync.atomic_load(&enrollment_failure_test_count) == 1, "same failure logged once during the burst")
	}
}

enrollment_test_wait_count :: proc(count: ^int) -> bool {
	start := time.tick_now()
	for sync.atomic_load(count) == 0 && time.tick_since(start) < ENROLLMENT_TEST_FAILURE_BOUND {
		time.sleep(5*time.Millisecond)
	}
	return sync.atomic_load(count) > 0
}

enrollment_test_local_closed :: proc(t: ^testing.T, ctl: ^RunControl) {
	start := time.tick_now()
	conn, err := trans.connection_dial_timeout(ctl.bound, ENROLLMENT_TEST_FAILURE_BOUND)
	testing.expect_value(t, err, trans.TransportError.None)
	if conn == nil {return}
	defer connect_test_connection_destroy(conn)
	if !testing.expect_value(t, trans.connection_set_recv_timeout(conn, ENROLLMENT_TEST_FAILURE_BOUND), trans.TransportError.None) {return}
	buf: [1]u8
	n, read_err := trans.connection_read(conn, buf[:])
	if n == 0 && read_err == .Timeout {
		testing.expect(t, false, "local socket was held open until receive timeout")
		return
	}
	testing.expect_value(t, n, 0)
	testing.expect_value(t, read_err, trans.TransportError.Closed)
	testing.expect(t, time.tick_since(start) < ENROLLMENT_TEST_FAILURE_BOUND, "client received EOF within 2 seconds")
}
