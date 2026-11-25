package connect

import auth "../../auth"
import cl "../../caller"
import log "../../logging"
import proto "../../protocol"
import trans "../../transport"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

ENROLLMENT_RESUME_BOUND :: 6*time.Second

ResumeAuth :: struct {
	store: ^auth.StaticTokenAuth,
	first_valid: int,
	seen: [3]int,
	pending: ^ResumePendingAuth,
}

ResumePendingAuth :: struct {
	entered, resume: sync.Sema,
	now, expires_at: time.Time, // published before resume
	expired: bool, // atomic
}

resume_authenticate :: proc(user: rawptr, token: []u8) -> (auth.AuthResult, auth.AuthError) {
	a := (^ResumeAuth)(user)
	for &count, i in a.seen {
		if string(token) == fmt.tprintf("%s%d", ENROLLMENT_TEST_GRANT_TOKEN, i+1) {
			sync.atomic_add(&count, 1)
			if i < sync.atomic_load(&a.first_valid) {return {}, .Expired}
			if i == 1 && a.pending != nil {
				pending := a.pending
				sync.sema_post(&pending.entered)
				sync.sema_wait(&pending.resume)
				if pending.now._nsec >= pending.expires_at._nsec {
					sync.atomic_store(&pending.expired, true)
					return {}, .Expired
				}
			}
			return {id = "client-a", organization = auth.DEFAULT_ORGANIZATION, capabilities = {.ConnectService}}, .None
		}
	}
	return auth.authenticate_token(a.store, token)
}

enrollment_redial_fixture :: proc(t: ^testing.T, f: ^EnrollmentFixture, broker, ca: string) {
	context.user_ptr = f
	enrollment_fixture_init(t, f, true)
	log.logger_init(&f.e.logger, .Info)
	f.at = time.now()
	f.expiry = time.time_add(f.at, 90*24*time.Hour)
	f.cfg.broker, f.cfg.tls_server_name = broker, "127.0.0.1"
	f.cfg.tls_ca = strings.clone(ca)
	f.e.new_caller, f.e.destroy_caller = nil, nil
	f.wire_service = T_SERVICE
	f.unique_mints = true
	enrollment_test_grant(f, time.time_add(f.at, time.Hour))
}

enrollment_wait_for_mint :: proc(
	t: ^testing.T, f: ^EnrollmentFixture, id: string, until: time.Tick, clock_start: time.Time = {},
) -> bool {
	l := &f.e.links[0]
	start := time.tick_now()
	for time.tick_diff(time.tick_now(), until) > 0 {
		if clock_start != {} {
			f.at = time.time_add(clock_start, time.tick_since(start))
		}
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return false}
		enrollment_reap(&f.e, l)
		if l.plan.credential_id == id && l.current != nil && cl.caller_session_admitted(&l.current.run.c) {return true}
		time.sleep(5*time.Millisecond)
	}
	return testing.expectf(t, false, "admission with %s within the recovery bound, got %d API mints", id, f.minted)
}

enrollment_redial_listener :: proc(t: ^testing.T, l: ^EnrollmentLink) -> (RunControl, bool) {
	ln, err := trans.listener_listen(trans.loopback_endpoint(0))
	if !testing.expect_value(t, err, trans.TransportError.None) {return {}, false}
	l.ln, l.opened, l.stall = ln, true, time.Second
	l.accept_th = thread.create_and_start_with_poly_data(l, enrollment_accept)
	if !testing.expect(t, l.accept_th != nil) {return {}, false}
	bound, endpoint_err := trans.listener_endpoint(ln)
	return RunControl{bound = bound}, testing.expect_value(t, endpoint_err, trans.TransportError.None)
}

enrollment_disconnect_for_test :: proc(t: ^testing.T, c: ^cl.Caller) -> bool {
	sync.mutex_lock(&c.mutex)
	trans.connection_shutdown_both(c.conn)
	sync.mutex_unlock(&c.mutex)
	start := time.tick_now()
	for cl.caller_session_admitted(c) && time.tick_since(start) < ENROLLMENT_RESUME_BOUND {
		time.sleep(5*time.Millisecond)
	}
	return testing.expect(t, !cl.caller_session_admitted(c), "original session lost admission")
}

@(test)
test_enrollment_reconnects_during_api_outage :: proc(t: ^testing.T) {
	enrollment_api_outage_reconnect_case(t, false)
}

@(test)
test_enrollment_discards_rejected_fallback :: proc(t: ^testing.T) {
	enrollment_api_outage_reconnect_case(t, true)
}

enrollment_api_outage_reconnect_case :: proc(t: ^testing.T, reject_fallback: bool) {
	fx: Fixture
	a := ResumeAuth{store = &fx.store}
	if !fixture_start(t, &fx, use_tls = true, authenticator = {ctx = &a, authenticate = resume_authenticate}) {return}
	defer fixture_stop(&fx)
	f: EnrollmentFixture
	enrollment_redial_fixture(t, &f, fx.broker, fx.tls_cert)
	defer enrollment_fixture_destroy(&f)
	l := &f.e.links[0]
	ctl, listening := enrollment_redial_listener(t, l)
	if !listening {return}
	if !enrollment_wait_for_mint(t, &f, "credential-1", time.tick_add(time.tick_now(), ENROLLMENT_RESUME_BOUND)) {return}
	expect_echo(t, &ctl, "before-api-outage")
	if testing.failed(t) {return}
	expires := l.plan.expires_at
	f.unavailable = true
	if reject_fallback {sync.atomic_store(&a.first_valid, 1)}
	if !enrollment_disconnect_for_test(t, &l.current.run.c) {return}

	start := time.tick_now()
	until := time.tick_add(start, ENROLLMENT_RESUME_BOUND)
	if !reject_fallback {
		if !enrollment_wait_for_mint(t, &f, "credential-1", until) {return}
		expect_echo(t, &ctl, "during-api-outage")
		elapsed := time.tick_since(start)
		testing.expectf(t, elapsed < ENROLLMENT_RESUME_BOUND, "fallback Service echo took %v", elapsed)
		testing.expect_value(t, f.minted, 1)
		testing.expect_value(t, l.plan.expires_at, expires)
		testing.expect_value(t, sync.atomic_load(&a.seen[0]), 2)
		if !testing.failed(t) {fmt.printf("Service echo during API outage in %v using the unexpired credential\n", elapsed)}
		return
	}

	for time.tick_diff(time.tick_now(), until) > 0 {
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		if l.job == nil && sync.atomic_load(&a.seen[0]) == 2 {break}
		time.sleep(5*time.Millisecond)
	}
	if !testing.expect(t, l.current == nil && l.job == nil && sync.atomic_load(&a.seen[0]) == 2,
		"the broker rejected the single fallback attempt") {return}
	testing.expect_value(t, l.pending.token, "")
	for _ in 0..<3 {
		f.at = l.next
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		if !testing.expect(t, l.current == nil && l.job == nil, "rejected credential was not retried during the outage") {return}
	}
	f.unavailable = false
	f.at = l.next
	if !enrollment_wait_for_mint(t, &f, "credential-2", time.tick_add(time.tick_now(), ENROLLMENT_RESUME_BOUND)) {return}
	expect_echo(t, &ctl, "after-api-outage")
	testing.expect_value(t, f.minted, 2)
	testing.expect_value(t, sync.atomic_load(&a.seen[0]), 2)
	testing.expect_value(t, sync.atomic_load(&a.seen[1]), 1)
}

@(test)
test_enrollment_clock_jump_restores_service :: proc(t: ^testing.T) {
	fx: Fixture
	a := ResumeAuth{store = &fx.store}
	if !fixture_start(t, &fx, use_tls = true, authenticator = {ctx = &a, authenticate = resume_authenticate}) {return}
	defer fixture_stop(&fx)
	f: EnrollmentFixture
	enrollment_redial_fixture(t, &f, fx.broker, fx.tls_cert)
	defer enrollment_fixture_destroy(&f)
	l := &f.e.links[0]
	ctl, listening := enrollment_redial_listener(t, l)
	if !listening {return}
	if !enrollment_wait_for_mint(t, &f, "credential-1", time.tick_add(time.tick_now(), ENROLLMENT_RESUME_BOUND)) {return}
	expect_echo(t, &ctl, "before-pause")

	// Poll the healthy caller and verify the same session and credential are
	// still in use. The clock jump that follows replaces only the wall clock.
	healthy := l.current
	healthy_until := time.tick_add(time.tick_now(), 500*time.Millisecond)
	for time.tick_diff(time.tick_now(), healthy_until) > 0 {
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		if !testing.expect(t, l.current == healthy && l.job == nil && cl.caller_session_admitted(&healthy.run.c), "healthy caller stayed admitted") {return}
		time.sleep(10*time.Millisecond)
	}
	testing.expect_value(t, sync.atomic_load(&a.seen[0]), 1)
	testing.expect_value(t, f.minted, 1)

	resumed := time.tick_now()
	until := time.tick_add(resumed, ENROLLMENT_RESUME_BOUND)
	f.at = time.time_add(l.plan.expires_at, time.Second)
	sync.atomic_store(&a.first_valid, 1)
	if !enrollment_wait_for_mint(t, &f, "credential-2", until) {return}
	expect_echo(t, &ctl, "first-recovery")
	if testing.failed(t) {return}
	// Drop the first recovered transport. The broker now rejects reusing its
	// credential and accepts the next API mint for the still-valid grant.
	sync.atomic_store(&a.first_valid, 2)
	c := &l.current.run.c
	sync.mutex_lock(&c.mutex)
	trans.connection_shutdown_both(c.conn)
	sync.mutex_unlock(&c.mutex)
	if !enrollment_wait_for_mint(t, &f, "credential-3", until) {return}
	expect_echo(t, &ctl, "after-pause")
	elapsed := time.tick_since(resumed)
	testing.expectf(t, elapsed < ENROLLMENT_RESUME_BOUND, "Service echoed after %v (bound %v)", elapsed, ENROLLMENT_RESUME_BOUND)
	testing.expect_value(t, f.minted, 3)
	testing.expect_value(t, sync.atomic_load(&a.seen[0]), 1)
	testing.expect_value(t, sync.atomic_load(&a.seen[1]), 1)
	testing.expect_value(t, sync.atomic_load(&a.seen[2]), 1)
	if !testing.failed(t) {fmt.printf("Caller resume Service echo completed in %v with three distinct credentials\n", elapsed)}
}

@(test)
test_enrollment_pause_during_rollover_restores_first_dial :: proc(t: ^testing.T) {
	enrollment_rollover_auth_case(t, true)
}

@(test)
test_enrollment_rollover_without_expiry_admits_pending_credential :: proc(t: ^testing.T) {
	enrollment_rollover_auth_case(t, false)
}

enrollment_rollover_auth_case :: proc(t: ^testing.T, pause_past_expiry: bool) {
	fx: Fixture
	pending: ResumePendingAuth
	a := ResumeAuth{store = &fx.store, pending = &pending}
	if !fixture_start(t, &fx, use_tls = true, authenticator = {ctx = &a, authenticate = resume_authenticate}) {return}
	defer fixture_stop(&fx)
	f: EnrollmentFixture
	enrollment_redial_fixture(t, &f, fx.broker, fx.tls_cert)
	defer enrollment_fixture_destroy(&f)
	// Also release Authenticate if an assertion fails while the job is held.
	defer sync.sema_post(&pending.resume)
	f.grants[0].until = time.time_add(f.at, 10*time.Minute)
	l := &f.e.links[0]
	ctl, listening := enrollment_redial_listener(t, l)
	if !listening {return}
	if !enrollment_wait_for_mint(t, &f, "credential-1", time.tick_add(time.tick_now(), ENROLLMENT_RESUME_BOUND)) {return}
	expect_echo(t, &ctl, "before-rollover")
	if testing.failed(t) {return}

	// The next grant awaits approval during the rollover window. Advance
	// through four real scheduler retries while the original grant serves.
	original := l.current
	f.at = l.plan.rollover_at
	for _ in 0..<4 {
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		if !testing.expect(t, l.current == original && cl.caller_session_admitted(&original.run.c) && f.minted == 1,
			"approval polling kept the original session") {return}
		f.at = l.next
	}
	append(&f.grants, EnrollmentTestGrant{"grant-replacement", "svc-a", "env-a", f.at, time.time_add(f.at, time.Hour)})
	if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) ||
	   !testing.expect(t, sync.sema_wait_with_timeout(&pending.entered, ENROLLMENT_RESUME_BOUND),
		"broker received the in-flight rollover Authenticate") {return}
	pending.expires_at = l.pending.expires_at
	if !testing.expect(t, f.at._nsec < pending.expires_at._nsec && f.minted == 2, "rollover started with a valid credential") {return}

	want := "credential-2"
	if pause_past_expiry {
		// Suspend while Authenticate is in flight. The broker makes its
		// authentication decision after both issued credentials have lapsed.
		f.at = time.time_add(pending.expires_at, time.Second)
		want = "credential-3"
	}
	pending.now = f.at
	resumed := time.tick_now()
	sync.sema_post(&pending.resume)
	until := time.tick_add(resumed, ENROLLMENT_RESUME_BOUND)
	admitted := enrollment_wait_for_mint(t, &f, want, until, clock_start = f.at)
	testing.expect_value(t, sync.atomic_load(&pending.expired), pause_past_expiry)
	if !admitted {
		fmt.printf("After rollover job completion: expiry=%v retry delay=%v backoff=%v\n",
			pause_past_expiry, time.diff(f.at, l.next), l.backoff)
	}
	expect_echo(t, &ctl, "first-dial-after-rollover")
	if !admitted {return}
	elapsed := time.tick_since(resumed)
	testing.expectf(t, elapsed < ENROLLMENT_RESUME_BOUND, "first Service echo after %v (bound %v)", elapsed, ENROLLMENT_RESUME_BOUND)
	testing.expect_value(t, f.minted, pause_past_expiry ? 3 : 2)
	if !testing.failed(t) {fmt.printf("First Service echo after rollover Authenticate resumed in %v (credential expired: %v)\n", elapsed, pause_past_expiry)}
}

when ODIN_TEST {
	@(test)
	test_enrollment_bridge_keeps_service_id_after_retirement :: proc(t: ^testing.T) {
		fx: Fixture
		a := ResumeAuth{store = &fx.store}
		if !fixture_start(t, &fx, use_tls = true, authenticator = {ctx = &a, authenticate = resume_authenticate}) {return}
		defer fixture_stop(&fx)
		f: EnrollmentFixture
		enrollment_redial_fixture(t, &f, fx.broker, fx.tls_cert)
		defer enrollment_fixture_destroy(&f)
		l := &f.e.links[0]
		if !enrollment_wait_for_mint(t, &f, "credential-1", time.tick_add(time.tick_now(), ENROLLMENT_RESUME_BOUND)) {return}
		original := l.current
		client, accepted, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {return}
		defer trans.connection_destroy(client)
		// Stage a real accepted socket between run_track and bridge_local.
		bridge := new(BridgeArg)
		bridge^ = {run = &original.run, local = accepted}
		run_track(&original.run, bridge)
		defer if bridge != nil {
			run_untrack(&original.run, bridge)
			trans.connection_destroy(accepted)
			free(bridge)
			run_bridge_done(&original.run)
		}
		owns_service_id := raw_data(string(bridge.run.service_id)) != raw_data(l.plan.service_id)

		c := &original.run.c
		if !enrollment_disconnect_for_test(t, c) {return}
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		enrollment_reap(&f.e, l)
		if !testing.expect(t, l.current == nil && l.plan.service_id == "" && len(l.retired) == 1 && l.retired[0] == original,
			"the plan was freed while the just-accepted bridge kept the retired caller alive") {return}
		if !testing.expect(t, owns_service_id, "the accepted bridge holds a Service ID owned by its caller") {return}
		testing.expect_value(t, string(bridge.run.service_id), T_SERVICE)
		_, dial_err := cl.dial_on_session(c, bridge.run.service_id)
		testing.expect_value(t, dial_err, cl.CallerError.Closed)
		bridge_local(bridge)
		bridge = nil
		enrollment_reap(&f.e, l)
		testing.expect_value(t, len(l.retired), 0)
	}
}

SetupReplyPeer :: struct {
	ln: trans.Listener,
	tls: ^trans.TlsServerContext,
	allocator: mem.Allocator,
	stop: bool,
	reject: bool,
	attempts, fresh: int,
	first_closed: bool,
}

setup_reply_connection :: proc(p: ^SetupReplyPeer, c: ^trans.Connection, attempt: int) {
	defer trans.connection_destroy(c)
	if trans.connection_tls_accept(c, p.tls, 3*time.Second) != .None {return}
	_ = trans.connection_set_recv_timeout(c, cl.DEFAULT_DIAL_TIMEOUT + 2*time.Second)
	decoder: proto.FrameDecoder
	if proto.decoder_init(&decoder) != .None {return}
	defer proto.decoder_destroy(&decoder)
	hello, terr, perr := trans.read_frame(c, &decoder)
	defer proto.frame_destroy(&hello)
	if terr != .None || perr != .None || hello.header.opcode != .Hello {return}
	ack, _ := proto.encode_hello_ack({major = proto.PROTOCOL_MAJOR, minor = proto.PROTOCOL_MINOR, implementation = "redial-fixture"})
	defer delete(ack)
	if write_err, _ := trans.write_frame(c, .HelloAck, ack); write_err != .None {return}
	request, read_err, decode_err := trans.read_frame(c, &decoder)
	defer proto.frame_destroy(&request)
	if read_err != .None || decode_err != .None || request.header.opcode != .Authenticate {return}
	authn, auth_err := proto.decode_authenticate(request.payload)
	defer delete(authn.token)
	if auth_err != .None {return}
	if string(authn.token) == fmt.tprintf("%s%d", ENROLLMENT_TEST_GRANT_TOKEN, attempt) {sync.atomic_add(&p.fresh, 1)}
	if p.reject {
		failure, _ := proto.encode_wire_failure({code = proto.wire_error_to_u16(.AuthenticationFailed)})
		defer delete(failure)
		_, _ = trans.write_frame(c, .AuthenticateFailed, failure)
		return
	}
	if attempt == 1 {
		// Withhold this Authenticate reply for the lifetime of the socket.
		// The fallback read deadline is longer than the caller's setup bound.
		buf: [1]u8
		_, closed := trans.connection_read(c, buf[:])
		sync.atomic_store(&p.first_closed, closed != .None && closed != .Timeout)
		return
	}
	admit, _ := proto.encode_authenticate_ok({principal_id = "client-a"})
	defer delete(admit)
	_, _ = trans.write_frame(c, .AuthenticateOk, admit)
	buf: [1]u8
	_ = trans.connection_set_recv_timeout(c, 50*time.Millisecond)
	for !sync.atomic_load(&p.stop) {
		_, poll := trans.connection_read(c, buf[:])
		if poll != .Timeout && poll != .None {break}
	}
}

setup_reply_serve :: proc(p: ^SetupReplyPeer) {
	context.allocator = p.allocator
	for !sync.atomic_load(&p.stop) {
		if trans.listener_wait_acceptable(&p.ln, 50*time.Millisecond) != .None {continue}
		conn, err := trans.listener_accept(&p.ln)
		if err != .None {continue}
		attempt := sync.atomic_add(&p.attempts, 1)+1
		setup_reply_connection(p, conn, attempt)
		free_all(context.temp_allocator)
	}
}

@(test)
test_enrollment_setup_timeout_redials_from_scratch :: proc(t: ^testing.T) {
	_ = enrollment_setup_reply_case(t, false)
}

enrollment_setup_reply_case :: proc(t: ^testing.T, reject: bool) -> (status: int) {
	cert, cert_ok := connect_write_temp_pem("redial-cert", CONNECT_TEST_CERT)
	defer {if cert_ok {_ = os.remove(cert); delete(cert)}}
	key, key_ok := connect_write_temp_pem("redial-key", CONNECT_TEST_KEY)
	defer {if key_ok {_ = os.remove(key); delete(key)}}
	if !testing.expect(t, cert_ok && key_ok, "certificate fixture") {return}
	tls, terr := trans.tls_server_context_init(cert, key)
	if !testing.expect_value(t, terr, trans.TransportError.None) {return}
	defer trans.tls_server_context_destroy(tls)
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	if !testing.expect_value(t, lerr, trans.TransportError.None) {return}
	defer trans.listener_close(&ln)
	ep, _ := trans.listener_endpoint(ln)
	broker := net.endpoint_to_string(ep, context.temp_allocator)
	p := SetupReplyPeer{ln = ln, tls = tls, allocator = context.allocator, reject = reject}
	th := thread.create_and_start_with_poly_data(&p, setup_reply_serve)
	if !testing.expect(t, th != nil) {return}
	defer {sync.atomic_store(&p.stop, true); thread.join(th); thread.destroy(th)}

	f: EnrollmentFixture
	enrollment_redial_fixture(t, &f, broker, cert)
	defer enrollment_fixture_destroy(&f)
	if reject {
		status = enrollment_run_rejected_caller(t, &f, tls)
		testing.expect_value(t, sync.atomic_load(&p.attempts), 3)
		testing.expect_value(t, sync.atomic_load(&p.fresh), 3)
		return
	}
	enrollment_assert_setup_timeout(t, &f, &p)
	return
}

enrollment_timeout_logs: int

enrollment_timeout_sink :: proc(line: string) {
	if strings.contains(line, `"reason":"timeout","phase":"authenticate"`) {
		sync.atomic_add(&enrollment_timeout_logs, 1)
	}
}

enrollment_assert_setup_timeout :: proc(t: ^testing.T, f: ^EnrollmentFixture, p: ^SetupReplyPeer) {
	sync.atomic_store(&enrollment_timeout_logs, 0)
	f.e.logger.sink = enrollment_timeout_sink
	f.e.now = nil
	started := time.tick_now()
	bound := cl.DEFAULT_DIAL_TIMEOUT + 4*time.Second
	if !enrollment_wait_for_mint(t, f, "credential-2", time.tick_add(started, bound)) {return}
	elapsed := time.tick_since(started)
	testing.expectf(t, elapsed >= cl.DEFAULT_DIAL_TIMEOUT && elapsed < bound, "second admission after %v (bound %v)", elapsed, bound)
	testing.expect(t, sync.atomic_load(&p.first_closed), "caller closed the first socket before the second setup")
	testing.expect_value(t, sync.atomic_load(&p.attempts), 2)
	testing.expect_value(t, sync.atomic_load(&p.fresh), 2)
	testing.expect_value(t, sync.atomic_load(&enrollment_timeout_logs), 1)
	if !testing.failed(t) {fmt.printf("Caller replaced the timed-out setup socket and authenticated with a fresh credential in %v\n", elapsed)}
}

ENROLLMENT_EXHAUSTION_CHILD :: "THIRP_ENROLLMENT_EXHAUSTION_TEST_CHILD"

@(test)
test_enrollment_exhaustion_child :: proc(t: ^testing.T) {
	if os.get_env(ENROLLMENT_EXHAUSTION_CHILD, context.temp_allocator) != "1" {return}
	code := enrollment_setup_reply_case(t, true)
	os.exit(testing.failed(t) ? 2 : code)
}

enrollment_run_rejected_caller :: proc(t: ^testing.T, f: ^EnrollmentFixture, tls: ^trans.TlsServerContext) -> (status: int) {
	ln, err := trans.listener_listen(trans.loopback_endpoint(0))
	if !testing.expect_value(t, err, trans.TransportError.None) {return}
	defer trans.listener_close(&ln)
	ep, _ := trans.listener_endpoint(ln)
	a := EnrollmentTestApi{f = f, ln = ln, tls = tls, allocator = context.allocator}
	api_thread := thread.create_and_start_with_poly_data(&a, enrollment_test_api_serve)
	if !testing.expect(t, api_thread != nil) {return}
	defer {sync.atomic_store(&a.stop, true); thread.join(api_thread); thread.destroy(api_thread)}
	dir, dir_err := os.make_directory_temp("", "thirp-redial-*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, os.Error(nil)) {return}
	defer _ = os.remove_all(dir)
	conf := fmt.tprintf("%s%vcaller.conf", dir, os.Path_Separator)
	token := fmt.tprintf("%s%vcaller.token", dir, os.Path_Separator)
	contents := fmt.tprintf(`api = https://127.0.0.1:%d
org = org-a
environment = env-a
enrollment = enrollment-a
token_file = caller.token
broker = %s
tls_server_name = 127.0.0.1
tls_ca = %s
api_tls_ca = %s
service = svc-a listen = 127.0.0.1:0
`, ep.port, f.cfg.broker, f.cfg.tls_ca, f.cfg.tls_ca)
	if !testing.expect(t, enrollment_test_write_private(token, ENROLLMENT_TEST_TOKEN+"\n") && enrollment_test_write_private(conf, contents), "private caller fixture") {return}
	return connect_main({"--caller-conf", conf})
}

@(test)
test_enrollment_exits_after_failed_redials :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "thirp-redial-exit-*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, os.Error(nil)) {return}
	defer _ = os.remove_all(dir)
	log_path := fmt.tprintf("%s%vstderr.log", dir, os.Path_Separator)
	exe, exe_err := os.get_executable_path(context.temp_allocator)
	if !testing.expect_value(t, exe_err, os.Error(nil)) {return}
	env, env_err := os.environ(context.temp_allocator)
	if !testing.expect_value(t, env_err, os.Error(nil)) {return}
	child_env := make([dynamic]string, 0, len(env)+1, context.temp_allocator)
	append(&child_env, ..env)
	append(&child_env, ENROLLMENT_EXHAUSTION_CHILD+"=1")
	// Windows passes this handle directly to CreateProcessW as stderr.
	stderr, log_err := os.open(log_path, {.Write, .Create, .Excl, .Inheritable}, os.Permissions_Default_File)
	if !testing.expect_value(t, log_err, os.Error(nil)) {return}
	child, start_err := os.process_start({command = {exe, "-tests:connect.test_enrollment_exhaustion_child"}, env = child_env[:], stderr = stderr})
	_ = os.close(stderr)
	if !testing.expect_value(t, start_err, os.Error(nil)) {return}
	state, wait_err := os.process_wait(child, 20*time.Second)
	if !testing.expect_value(t, wait_err, os.Error(nil)) {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
		return
	}
	lines, read_err := os.read_entire_file(log_path, context.temp_allocator)
	if !testing.expect_value(t, read_err, os.Error(nil)) {return}
	if !testing.expectf(t, state.exit_code == 1, "caller exited %d, expected 1\n%s", state.exit_code, string(lines)) {return}
	testing.expect_value(t, strings.count(string(lines), `"reason":"broker_setup_exhausted"`), 1)
	// The child checks all three wire attempts independently of the logger.
	testing.expect(t, strings.contains(string(lines), `"reason":"unauthorized_or_revoked","phase":"authenticate"`))
	if !testing.failed(t) {fmt.println("Caller exited 1 with broker_setup_exhausted after three rejected credentials")}
}
