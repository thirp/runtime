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
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Allow a synchronous HTTPS timeout, a broker dial timeout, and retry/scheduling slack.
ENROLLMENT_TEST_CONVERGE :: ENROLLMENT_HTTP_TIMEOUT + cl.DEFAULT_DIAL_TIMEOUT + 5*time.Second

EnrollmentTestApi :: struct {
	f: ^EnrollmentFixture,
	ln: trans.Listener,
	tls: ^trans.TlsServerContext,
	allocator: mem.Allocator,
	stop: bool,
	drop_first: int,
	delay: time.Duration,
	dropped: int, // atomic; only the API thread increments it
}

enrollment_test_api_connection :: proc(a: ^EnrollmentTestApi, c: ^trans.Connection) {
	defer trans.connection_destroy(c)
	if sync.atomic_load(&a.dropped) < a.drop_first {
		sync.atomic_add(&a.dropped, 1)
		return
	}
	if trans.connection_tls_accept(c, a.tls, 10*time.Second) != .None {return}
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
	tls, terr := trans.tls_server_context_init(fx.tls_cert, fx.tls_key)
	testing.expect_value(t, terr, trans.TransportError.None)
	if terr != .None {return}
	defer trans.tls_server_context_destroy(tls)
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	if lerr != .None {return}
	defer trans.listener_close(&ln)
	ep, _ := trans.listener_endpoint(ln)
	api := fmt.aprintf("https://127.0.0.1:%d", ep.port)
	defer delete(api)
	f.cfg.api = api
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
		// Same CA, wrong verification name must fail without an HTTP request.
		f.cfg.tls_server_name = "wrong.example.test"
		r, err := enrollment_network_http(nil, &f.cfg, {ENROLLMENT_GET, ENROLLMENT_ORGS+"org-a"+ENROLLMENT_SELF, f.e.token, ""})
		testing.expect_value(t, err, EnrollmentError.Retry)
		delete(r.body)
		f.cfg.tls_server_name = "127.0.0.1"
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
}
