package connect

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import log "../../logging"
import trans "../../transport"
import private_file "private_file"

@(test)
test_enrollment_failure_log_limits_each_source_and_reason :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f)
	defer enrollment_fixture_destroy(&f)
	start := time.tick_now()
	for i in 0..<100 {
		enrollment_failure(&f.e, "api", "tls_verify", at = time.tick_add(start, time.Duration(i)*time.Millisecond))
	}
	before_limit := time.tick_add(start, 10*time.Second-time.Nanosecond)
	enrollment_failure(&f.e, "api", "tls_verify", at = before_limit)
	enrollment_failure(&f.e, "stream", "unauthorized_or_revoked", at = before_limit)
	enrollment_failure(&f.e, "api", "unauthorized_or_revoked", at = before_limit)
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"tls_verify","phase":"api"`), 1)
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"unauthorized_or_revoked","phase":"stream"`), 1)
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"unauthorized_or_revoked","phase":"api"`), 1)
	enrollment_failure(&f.e, "api", "tls_verify", at = time.tick_add(start, 10*time.Second))
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"tls_verify","phase":"api"`), 2)

	enrollment_setup_failure(&f.e, "svc-a", "dns", "timeout", at = start)
	enrollment_setup_failure(&f.e, "svc-b", "authenticate", "timeout", at = before_limit)
	enrollment_setup_failure(&f.e, "svc-b", "authenticate", "unauthorized_or_revoked", at = before_limit)
	enrollment_failure(&f.e, "api", "timeout", at = before_limit)
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"timeout","phase":"dns"`), 1)
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"timeout","phase":"authenticate"`), 0)
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"unauthorized_or_revoked","phase":"authenticate"`), 1)
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"timeout","phase":"api"`), 1)
	enrollment_setup_failure(&f.e, "svc-b", "authenticate", "timeout", at = time.tick_add(start, 10*time.Second))
	testing.expect_value(t, strings.count(string(f.logs[:]), `"reason":"timeout","phase":"authenticate"`), 1)
}

ENROLLMENT_TEST_CONF :: `api = https://api.example.test
org = org-a
environment =
enrollment = enrollment-a
token_file = caller.token
broker = broker.example.test:443
tls_ca =
tls_server_name =
service = svc-a listen = 127.0.0.1:9001 # first link
service = svc-b listen = 127.0.0.1:9002
`
ENROLLMENT_TEST_TOKEN :: "thirp_cen_test_secret"
ENROLLMENT_TEST_NEW_TOKEN :: "thirp_cen_rotated_secret"
ENROLLMENT_TEST_GRANT_TOKEN :: "thirp_cal_grant_secret"

EnrollmentTestGrant :: struct {id, catalog, environment: string, from, until: time.Time}
EnrollmentTestRequest :: struct {method, path, bearer, body: string}
EnrollmentFixture :: struct {
	e: Enrollment,
	cfg: EnrollmentConfig,
	at, expiry, overlap_end: time.Time,
	grants: [dynamic]EnrollmentTestGrant,
	requests: [dynamic]EnrollmentTestRequest,
	logs: [dynamic]u8,
	active_token: string,
	wire_service: string,
	deny_self, deny_grant, unavailable, paginate: bool,
	unique_mints: bool,
	created, approved, minted, renewed, rotated, destroyed: int,
	dir: string,
	connection: trans.Connection,
}

enrollment_test_stamp :: proc(t: time.Time) -> string {
	s, _ := time.time_to_rfc3339(t, 0, true, context.temp_allocator)
	return s
}

enrollment_test_now :: proc(user: rawptr) -> time.Time {return (^EnrollmentFixture)(user).at}

enrollment_test_http :: proc(user: rawptr, _: ^EnrollmentConfig, req: EnrollmentRequest) -> (EnrollmentResponse, EnrollmentError) {
	f := (^EnrollmentFixture)(user)
	append(&f.requests, EnrollmentTestRequest{strings.clone(req.method), strings.clone(req.path), strings.clone(req.bearer), strings.clone(req.body)})
	if f.unavailable {return {failure = "connect"}, .Retry}
	ROOT :: ENROLLMENT_ORGS+"org-a"
	if req.bearer != f.active_token && !(req.bearer == ENROLLMENT_TEST_TOKEN && f.at._nsec < f.overlap_end._nsec) {return {status = 401, body = strings.clone(`{}`)}, .None}
	if req.path == ROOT+ENROLLMENT_SELF {
		if f.deny_self {return {status = 401, body = strings.clone(`{}`)}, .None}
		return {status = 200, body = fmt.aprintf(`{{"id":"enrollment-a","state":"active","expires_at":%q}}`, enrollment_test_stamp(f.expiry))}, .None
	}
	if req.path == ROOT+ENROLLMENT_SELF+ENROLLMENT_ROTATE {
		f.rotated += 1
		f.overlap_end = time.time_add(f.at, 24*time.Hour)
		f.expiry = time.time_add(f.at, 90*24*time.Hour)
		f.active_token = ENROLLMENT_TEST_NEW_TOKEN
		return {status = 200, body = fmt.aprintf(`{{"token":%q,"credential_id":"enrollment-credential-b","expires_at":%q,"previous_expires_at":%q}}`, f.active_token, enrollment_test_stamp(f.expiry), enrollment_test_stamp(f.overlap_end))}, .None
	}
	if f.deny_grant {return {status = 403, body = strings.clone(`{}`)}, .None}
	if req.path == ROOT {return {status = 200, body = strings.clone(`{"plan_id":"platforms"}`)}, .None}
	if strings.has_prefix(req.path, ROOT+ENROLLMENT_GRANTS) && req.method == ENROLLMENT_GET {
		if f.paginate && !strings.contains(req.path, "cursor=") {return {status = 200, body = strings.clone(`{"items":[],"next_cursor":"page /+2"}`)}, .None}
		parts: [dynamic]string
		defer {for part in parts {delete(part)}; delete(parts)}
		for g in f.grants {
			append(&parts, fmt.aprintf(`{{"id":%q,"catalog_service_id":%q,"service_id":%q,"environment_id":%q,"state":"active","valid_from":%q,"valid_until":%q}}`, g.id, g.catalog, f.wire_service, g.environment, enrollment_test_stamp(g.from), enrollment_test_stamp(g.until)))
		}
		joined := strings.join(parts[:], ",")
		defer delete(joined)
		return {status = 200, body = fmt.aprintf(`{{"items":[%s]}}`, joined)}, .None
	}
	if req.path == ROOT+ENROLLMENT_REQUESTS {
		f.created += 1
		return {status = 201, body = strings.clone(`{"id":"request-a"}`)}, .None
	}
	if req.path == ROOT+ENROLLMENT_REQUESTS+"/request-a"+ENROLLMENT_APPROVE {
		f.approved += 1
		g := EnrollmentTestGrant{id = "grant-new", catalog = "svc-a", from = f.at, until = time.time_add(f.at, 8*time.Hour)}
		append(&f.grants, g)
		return {status = 200, body = fmt.aprintf(`{{"grants":[{{"id":%q,"catalog_service_id":%q,"service_id":"demo/service","environment_id":"","state":"active","valid_from":%q,"valid_until":%q}}]}}`, g.id, g.catalog, enrollment_test_stamp(g.from), enrollment_test_stamp(g.until))}, .None
	}
	for g in f.grants {
		base := fmt.tprintf("%s%s/%s%s", ROOT, ENROLLMENT_GRANTS, g.id, ENROLLMENT_CREDENTIALS)
		if req.path == base {
			f.minted += 1
			exp := time.time_add(f.at, 15*time.Minute)
			if exp._nsec > g.until._nsec {exp = g.until}
			token, id := ENROLLMENT_TEST_GRANT_TOKEN, "credential-a"
			if f.unique_mints {
				token = fmt.tprintf("%s%d", ENROLLMENT_TEST_GRANT_TOKEN, f.minted)
				id = fmt.tprintf("credential-%d", f.minted)
			}
			return {status = 201, body = fmt.aprintf(`{{"token":%q,"credential_id":%q,"expires_at":%q}}`, token, id, enrollment_test_stamp(exp))}, .None
		}
		if req.path == fmt.tprintf("%s/credential-a%s", base, ENROLLMENT_RENEW) {
			f.renewed += 1
			exp := time.time_add(f.at, 15*time.Minute)
			if exp._nsec > g.until._nsec {exp = g.until}
			return {status = 200, body = fmt.aprintf(`{{"credential_id":"credential-a","expires_at":%q}}`, enrollment_test_stamp(exp))}, .None
		}
	}
	return {status = 404, body = strings.clone(`{}`)}, .None
}

enrollment_fixture_init :: proc(t: ^testing.T, f: ^EnrollmentFixture, support := false) {
	f.at = time.unix(1_794_787_200, 0)
	f.expiry = time.time_add(f.at, 90*24*time.Hour)
	f.active_token = ENROLLMENT_TEST_TOKEN
	f.wire_service = "demo/service"
	ok: bool
	f.cfg, ok = enrollment_config_parse(ENROLLMENT_TEST_CONF, "/tmp/caller.conf")
	testing.expect(t, ok)
	if support {f.cfg.environment = "env-a"}
	f.e.cfg, f.e.token = &f.cfg, strings.clone(ENROLLMENT_TEST_TOKEN)
	f.e.http, f.e.now, f.e.user = enrollment_test_http, enrollment_test_now, f
	f.e.links = make([]EnrollmentLink, 1)
	f.e.links[0].cfg = f.cfg.links[0]
	f.e.new_caller = proc(e: ^Enrollment, l: ^EnrollmentLink) -> (^EnrollmentCaller, bool) {
		c := new(EnrollmentCaller)
		c.grant_end, c.run.live = l.pending.grant_end, 1
		c.run.c.conn = &(^EnrollmentFixture)(e.user).connection
		c.run.c.connected = true
		return c, true
	}
	f.e.destroy_caller = proc(c: ^EnrollmentCaller) {
		(^EnrollmentFixture)(context.user_ptr).destroyed += 1
		free(c)
	}
	log.logger_init(&f.e.logger, .Info, proc(s: string) {append(&(^EnrollmentFixture)(context.user_ptr).logs, ..transmute([]u8)s)})
}

enrollment_fixture_destroy :: proc(f: ^EnrollmentFixture) {
	for &l in f.e.links {sync.atomic_store(&l.stop, true)}
	for &l in f.e.links {
		if l.accept_th != nil {thread.join(l.accept_th); thread.destroy(l.accept_th)}
		if l.job != nil {
			thread.join(l.job.th); thread.destroy(l.job.th)
			if l.job.caller != nil {l.job.caller.force = true; append(&l.retired, l.job.caller)}
			free(l.job); l.job = nil
		}
		enrollment_drop(&f.e, &l)
		enrollment_reap(&f.e, &l)
		delete(l.retired)
		if l.opened {trans.listener_close(&l.ln)}
	}
	delete(f.e.links); delete(f.e.token); delete(f.e.pending_token); delete(f.e.failure_next)
	for r in f.requests {delete(r.method); delete(r.path); delete(r.bearer); delete(r.body)}
	delete(f.requests); delete(f.grants); delete(f.logs)
	if len(f.dir) > 0 {
		_ = os.remove(f.cfg.token_file)
		_ = os.remove(f.dir)
		delete(f.dir)
	}
	enrollment_config_destroy(&f.cfg)
}

enrollment_test_grant :: proc(f: ^EnrollmentFixture, until: time.Time) {
	append(&f.grants, EnrollmentTestGrant{"grant-old", "svc-a", f.cfg.environment, f.at, until})
}

@(test)
test_enrollment_resume_recovers_lost_admission :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	enrollment_test_grant(&f, time.time_add(f.at, time.Hour))
	if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
	l := &f.e.links[0]
	if !testing.expect(t, l.current != nil, "initial admission") {return}
	f.at = time.time_add(l.plan.expires_at, time.Second)
	if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
	if !testing.expect(t, l.current != nil && f.minted == 2, "fresh admission after expiry") {return}
	// The resumed transport admitted us once, then dropped. The grant is
	// still valid and a fresh mint can be used immediately.
	l.current.run.c.connected = false
	if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
	testing.expectf(t, f.minted == 3, "lost admission must trigger a fresh mint immediately, got %d total mints", f.minted)
}

@(test)
test_enrollment_fallback_requires_a_valid_credential_and_grant :: proc(t: ^testing.T) {
	FallbackCase :: enum {Mint_Unavailable, Credential_Expired, Grant_Expired, Denied, Grant_Removed, API_Untrusted}
	for mode in FallbackCase {
		f: EnrollmentFixture
		context.user_ptr = &f
		enrollment_fixture_init(t, &f, true)
		defer enrollment_fixture_destroy(&f)
		enrollment_test_grant(&f, time.time_add(f.at, time.Hour))
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		l := &f.e.links[0]
		original := l.current
		if !testing.expect(t, original != nil, "initial admission") {return}
		original.run.c.connected = false
		switch mode {
		case .Mint_Unavailable:
			f.e.http = proc(user: rawptr, cfg: ^EnrollmentConfig, req: EnrollmentRequest) -> (EnrollmentResponse, EnrollmentError) {
				if req.method == ENROLLMENT_POST && strings.has_suffix(req.path, ENROLLMENT_CREDENTIALS) {
					return {status = 503}, .None
				}
				return enrollment_test_http(user, cfg, req)
			}
		case .Credential_Expired:
			f.at, f.unavailable = l.plan.expires_at, true
		case .Grant_Expired:
			f.at, f.unavailable = l.plan.grant_end, true
		case .Denied:
			f.deny_grant = true
		case .Grant_Removed:
			clear(&f.grants)
		case .API_Untrusted:
			f.e.http = proc(_: rawptr, _: ^EnrollmentConfig, _: EnrollmentRequest) -> (EnrollmentResponse, EnrollmentError) {
				return {failure = "tls_verify"}, .Retry
			}
		}
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		testing.expect_value(t, f.minted, 1)
		if mode == .Mint_Unavailable {
			testing.expect(t, l.current != nil && l.current != original, "a transient mint failure permits fallback")
			testing.expect_value(t, l.plan.credential_id, "credential-a")
		} else {
			testing.expectf(t, l.current == nil && len(l.pending.token) == 0, "%v must not reuse a credential", mode)
		}
	}
}

// Write a fixture file the way enrollment expects it on disk: mode 0600 on
// POSIX, the owner-only protected DACL (current user + SYSTEM) on Windows.
enrollment_test_write_private :: proc(path, contents: string) -> bool {
	when ODIN_OS == .Windows {
		if os.write_entire_file(path, contents) != nil {return false}
		f, err := os.open(path, {.Read})
		if err != nil {return false}
		defer os.close(f)
		return private_file.protect(f, path)
	} else {
		return os.write_entire_file(path, contents, CALLER_FILE_MODE) == nil
	}
}

@(test)
test_enrollment_conf_parse_permissions_and_flags :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-enrollment-*", context.allocator)
	testing.expect_value(t, err, os.Error(nil))
	if err != nil {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.conf", dir)
	// caller.conf names a relative token_file; it resolves with the native separator.
	tokpath := fmt.aprintf("%s%vcaller.token", dir, os.Path_Separator)
	defer {delete(path); delete(tokpath); os.remove(path); os.remove(tokpath)}
	testing.expect(t, enrollment_test_write_private(path, ENROLLMENT_TEST_CONF))
	testing.expect(t, enrollment_test_write_private(tokpath, ENROLLMENT_TEST_TOKEN+"\n"))
	c, token, ok := enrollment_config_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, len(c.links), 2)
	testing.expect_value(t, c.token_file, tokpath)
	testing.expect_value(t, token, ENROLLMENT_TEST_TOKEN)
	enrollment_config_destroy(&c); delete(token)
	when ODIN_OS != .Windows {
		for mode in ([]os.Permissions{CALLER_FILE_MODE+{.Read_Group}, CALLER_FILE_MODE+{.Write_Other}, CALLER_FILE_MODE+{.Execute_User}}) {
			_ = os.chmod(tokpath, mode)
			bad, secret, accepted := enrollment_config_load(path)
			testing.expect(t, !accepted)
			enrollment_config_destroy(&bad); delete(secret)
		}
	} else {
		// A token file with the folder's inherited DACL is refused. Each loose
		// DACL shape is covered in private_file/file_windows_test.odin.
		_ = os.remove(tokpath)
		testing.expect(t, os.write_entire_file(tokpath, ENROLLMENT_TEST_TOKEN+"\n") == nil)
		testing.expect(t, !enrollment_file_private(tokpath))
		bad, secret, accepted := enrollment_config_load(path)
		testing.expect(t, !accepted)
		enrollment_config_destroy(&bad); delete(secret)
	}
	for suffix in ([]string{"org = duplicate\n", "unknown = x\n", "service = bad listen = hostname:4\n", "service = svc-c listen = 127.0.0.1:9001\n"}) {
		bad, accepted := enrollment_config_parse(fmt.tprintf("%s%s", ENROLLMENT_TEST_CONF, suffix), path)
		testing.expect(t, !accepted)
		if accepted {enrollment_config_destroy(&bad)}
	}
	for flag in ([]string{"--token", "--token-file", "--broker", "--service", "--listen"}) {
		testing.expect_value(t, connect_main({"--caller-conf", path, flag, ""}), 1)
	}
	testing.expect_value(t, connect_main({"--caller-conf"}), 1)
}

@(test)
test_enrollment_renew_half_lifetime_and_fractional_expiry :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f)
	defer enrollment_fixture_destroy(&f)
	enrollment_test_grant(&f, time.time_add(f.at, 8*time.Hour))
	testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None)
	l := &f.e.links[0]
	healthy := l.current
	testing.expect_value(t, l.plan.renew_at, time.time_add(f.at, 450*time.Second))
	f.at = time.time_add(f.at, 449*time.Second)
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.renewed, 0)
	f.at = time.time_add(f.at, time.Second)
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.renewed, 1)
	testing.expect(t, healthy != nil && l.current == healthy && f.minted == 1, "normal renewal keeps the admitted caller")
	testing.expect_value(t, time.diff(f.at, l.plan.expires_at), 15*time.Minute)
	v, err := json.parse(`{"expires_at":"2026-11-16T00:00:00.123456789Z"}`, .JSON)
	testing.expect_value(t, err, json.Error.None)
	defer json.destroy_value(v)
	testing.expect_value(t, enrollment_time(v, ENROLLMENT_EXPIRES_AT)._nsec%1_000_000_000, i64(123456789))
}

@(test)
test_enrollment_platforms_regrant_keeps_listener_and_old_streams :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f)
	defer enrollment_fixture_destroy(&f)
	end := time.time_add(f.at, 10*time.Minute)
	enrollment_test_grant(&f, end)
	_ = enrollment_step(&f.e)
	l := &f.e.links[0]
	old := l.current
	listener := l.ln
	f.at = l.plan.rollover_at
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.created, 1)
	testing.expect_value(t, f.approved, 1)
	testing.expect_value(t, l.plan.grant_id, "grant-new")
	testing.expect(t, l.current != old)
	testing.expect_value(t, l.ln, listener)
	testing.expect_value(t, len(l.retired), 1)
	enrollment_reap(&f.e, l)
	testing.expect_value(t, f.destroyed, 0)
	f.at = end
	enrollment_reap(&f.e, l)
	testing.expect_value(t, f.destroyed, 1)
	testing.expect(t, l.current != nil)
	// The create body uses a catalog id, never the broker wire id.
	for r in f.requests {if r.path == ENROLLMENT_ORGS+"org-a"+ENROLLMENT_REQUESTS {testing.expect(t, strings.contains(r.body, "svc-a"))}}
}

@(test)
test_enrollment_failed_rollover_keeps_healthy_caller :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	enrollment_test_grant(&f, time.time_add(f.at, 10*time.Minute))
	if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
	l := &f.e.links[0]
	original := l.current
	if !testing.expect(t, original != nil, "initial caller admitted") {return}
	sync.atomic_store(&original.run.live, 0)
	bridge := BridgeArg{run = &original.run}
	run_track(&original.run, &bridge)
	defer {
		run_untrack(&original.run, &bridge)
		run_bridge_done(&original.run)
		delete(original.run.bridges)
	}
	l.opened = true // Model the listener owned by enrollment_main.
	defer l.opened = false
	f.at = l.plan.rollover_at
	append(&f.grants, EnrollmentTestGrant{"grant-replacement", "svc-a", "env-a", f.at, time.time_add(f.at, time.Hour)})
	f.e.new_caller = proc(_: ^Enrollment, _: ^EnrollmentLink) -> (^EnrollmentCaller, bool) {return nil, false}

	for attempt in 1..=3 {
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		testing.expect(t, l.current == original && original.run.c.connected && len(l.retired) == 0,
			"failed replacement keeps the original session admitted")
		testing.expect(t, l.opened && !l.stop && len(original.run.bridges) == 1 &&
			original.run.bridges[0] == &bridge && original.run.live == 1 && !bridge.kick,
			"failed replacement keeps the listener and bridge active")
		testing.expect_value(t, f.minted, 1+attempt)
		f.at = l.next
	}
	testing.expect(t, !strings.contains(string(f.logs[:]), "broker_setup_exhausted"))

	// Losing admission starts a fresh recovery budget for this Service.
	original.run.c.connected = false
	for _ in 0..<2 {
		if !testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None) {return}
		f.at = l.next
	}
	testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.Broker_Setup_Exhausted)
	testing.expect_value(t, strings.count(string(f.logs[:]), "broker_setup_exhausted"), 1)
}

@(test)
test_enrollment_support_stops_and_waits_without_post_approval :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	end := time.time_add(f.at, 10*time.Minute)
	enrollment_test_grant(&f, end)
	_ = enrollment_step(&f.e)
	l := &f.e.links[0]
	testing.expect(t, l.current != nil)
	f.at = end
	_ = enrollment_step(&f.e)
	enrollment_reap(&f.e, l)
	testing.expect(t, l.current == nil)
	testing.expect(t, strings.contains(string(f.logs[:]), "waiting for approval"))
	for _ in 0..<10 {f.at = l.next; _ = enrollment_step(&f.e)}
	testing.expect_value(t, f.created, 0)
	testing.expect_value(t, f.approved, 0)
	for r in f.requests {testing.expect(t, r.method != ENROLLMENT_POST || strings.has_suffix(r.path, ENROLLMENT_CREDENTIALS))}
	append(&f.grants, EnrollmentTestGrant{"grant-human", "svc-a", "env-a", f.at, time.time_add(f.at, time.Hour)})
	f.at = l.next
	_ = enrollment_step(&f.e)
	testing.expect_value(t, l.plan.grant_id, "grant-human")
	testing.expect(t, l.current != nil)
}

@(test)
test_enrollment_rotation_overlap_atomic_file_mode_and_no_secrets_in_logs :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f)
	defer enrollment_fixture_destroy(&f)
	dir, err := os.make_directory_temp("", "thirp-enrollment-rotate-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	f.dir = dir
	delete(f.cfg.token_file)
	f.cfg.token_file = fmt.aprintf("%s/caller.token", dir)
	testing.expect(t, enrollment_test_write_private(f.cfg.token_file, ENROLLMENT_TEST_TOKEN+"\n"))
	f.expiry = time.time_add(f.at, CALLER_ENROLLMENT_ROTATE_WINDOW)
	enrollment_test_grant(&f, time.time_add(f.at, time.Hour))
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.rotated, 1)
	testing.expect_value(t, f.e.token, ENROLLMENT_TEST_NEW_TOKEN)
	contents, rerr := os.read_entire_file(f.cfg.token_file, context.allocator)
	testing.expect(t, rerr == nil)
	defer delete(contents)
	testing.expect_value(t, string(contents), ENROLLMENT_TEST_NEW_TOKEN+"\n")
	testing.expect(t, enrollment_file_private(f.cfg.token_file))
	when ODIN_OS != .Windows {
		fi, _ := os.stat(f.cfg.token_file, context.allocator)
		testing.expect_value(t, fi.mode, CALLER_FILE_MODE)
		os.file_info_delete(fi, context.allocator)
	}
	old := EnrollmentRequest{ENROLLMENT_GET, ENROLLMENT_ORGS+"org-a"+ENROLLMENT_SELF, ENROLLMENT_TEST_TOKEN, ""}
	r, _ := enrollment_test_http(&f, &f.cfg, old)
	testing.expect_value(t, r.status, 200); delete(r.body)
	f.at = f.overlap_end
	r, _ = enrollment_test_http(&f, &f.cfg, old)
	testing.expect_value(t, r.status, 401); delete(r.body)
	for secret in ([]string{ENROLLMENT_TEST_TOKEN, ENROLLMENT_TEST_NEW_TOKEN, ENROLLMENT_TEST_GRANT_TOKEN}) {testing.expect(t, !strings.contains(string(f.logs[:]), secret))}
	testing.expect(t, strings.contains(string(f.logs[:]), "enrollment rotated"))
	for r in f.requests {if strings.contains(r.path, ENROLLMENT_CREDENTIALS) {testing.expect_value(t, r.bearer, ENROLLMENT_TEST_NEW_TOKEN)}}
}

@(test)
test_enrollment_revoke_drops_callers_and_polls_slowly :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	enrollment_test_grant(&f, time.time_add(f.at, 8*time.Hour))
	_ = enrollment_step(&f.e)
	l := &f.e.links[0]
	f.deny_grant = true
	f.at = l.plan.renew_at
	_ = enrollment_step(&f.e)
	testing.expect(t, l.current == nil)
	enrollment_reap(&f.e, l)
	testing.expect_value(t, f.destroyed, 1)
	_, _, slow, _ := enrollment_intervals()
	testing.expect_value(t, time.diff(f.at, l.next), slow)
	before := len(f.requests)
	_ = enrollment_step(&f.e)
	testing.expect_value(t, len(f.requests), before)
	f.at = l.next
	_ = enrollment_step(&f.e)
	testing.expect(t, len(f.requests) > before)
	testing.expect_value(t, f.approved, 0)
	f.deny_grant = false
	f.at = l.next
	_ = enrollment_step(&f.e)
	testing.expect(t, l.current != nil)
	f.deny_self = true
	f.e.self_next = f.at
	_ = enrollment_step(&f.e)
	testing.expect(t, l.current == nil && f.e.denied)
}

@(test)
test_enrollment_http_framing_and_https_only :: proc(t: ^testing.T) {
	for api in ([]string{"http://api.test", "https://user@api.test", "https://api.test/a", "https://api.test\r\nX:bad"}) {
		_, _, _, ok := enrollment_api_address(api)
		testing.expect(t, !ok)
	}
	for raw in ([]string{
		"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
	}) {
		r, err := enrollment_http_response(raw)
		testing.expect_value(t, err, EnrollmentError.None)
		testing.expect_value(t, r.body, "{}")
		delete(r.body)
	}
	for raw in ([]string{
		"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}",
		"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{",
	}) {
		r, err := enrollment_http_response(raw)
		testing.expect_value(t, err, EnrollmentError.Retry)
		delete(r.body)
	}
}

@(test)
test_enrollment_rotation_failed_write_retains_response_until_persisted :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	dir, err := os.make_directory_temp("", "thirp-enrollment-persist-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	f.dir = dir
	delete(f.cfg.token_file)
	f.cfg.token_file = fmt.aprintf("%s/missing/caller.token", dir)
	f.expiry = time.time_add(f.at, CALLER_ENROLLMENT_ROTATE_WINDOW)
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.rotated, 1)
	testing.expect_value(t, f.e.token, ENROLLMENT_TEST_TOKEN)
	testing.expect_value(t, f.e.pending_token, ENROLLMENT_TEST_NEW_TOKEN)
	// Repair persistence while the old token remains valid in its overlap.
	delete(f.cfg.token_file)
	f.cfg.token_file = fmt.aprintf("%s/caller.token", dir)
	f.at = f.e.self_next
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.rotated, 1)
	testing.expect_value(t, f.e.token, ENROLLMENT_TEST_NEW_TOKEN)
	testing.expect_value(t, f.e.pending_token, "")
	testing.expect(t, enrollment_file_private(f.cfg.token_file))
}

@(test)
test_enrollment_multiple_links_and_grant_scope_pagination :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	delete(f.e.links)
	f.e.links = make([]EnrollmentLink, 2)
	for &l, i in f.e.links {l.cfg = f.cfg.links[i]}
	f.paginate = true
	end := time.time_add(f.at, 8*time.Hour)
	// Wrong environment, future and expired grants must all be skipped.
	append(&f.grants,
		EnrollmentTestGrant{"grant-other", "svc-a", "env-other", f.at, end},
		EnrollmentTestGrant{"grant-future", "svc-a", "env-a", time.time_add(f.at, time.Hour), end},
		EnrollmentTestGrant{"grant-ended", "svc-a", "env-a", time.time_add(f.at, -time.Hour), f.at},
		EnrollmentTestGrant{"grant-a", "svc-a", "env-a", f.at, end},
		EnrollmentTestGrant{"grant-b", "svc-b", "env-a", f.at, end})
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.minted, 2)
	testing.expect_value(t, f.e.links[0].plan.grant_id, "grant-a")
	testing.expect_value(t, f.e.links[1].plan.grant_id, "grant-b")
	testing.expect(t, f.e.links[0].current != f.e.links[1].current)
	testing.expect_value(t, f.created, 0)
	pages := 0
	for r in f.requests {if strings.has_suffix(r.path, "&cursor=page%20%2F%2B2") {pages += 1}}
	testing.expect_value(t, pages, 2)
}

@(test)
test_enrollment_expiry_config_and_transient_failures :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	f.unavailable = true
	testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.None)
	testing.expect(t, f.e.links[0].current == nil)
	f.unavailable = false
	f.at = f.e.self_next
	f.cfg.enrollment = "wrong-enrollment"
	testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.Config)
	f.cfg.enrollment = "enrollment-a"
	f.expiry = f.at
	f.e.self_next = f.at
	testing.expect_value(t, enrollment_step(&f.e), EnrollmentError.Expired)
}

@(test)
test_enrollment_expiry_reaper_closes_streams_without_control_tick :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	enrollment_test_grant(&f, time.time_add(f.at, 8*time.Hour))
	_ = enrollment_step(&f.e)
	l := &f.e.links[0]
	f.at = l.plan.expires_at
	// Model another link's delayed HTTP call: no maintenance step occurs.
	enrollment_reap(&f.e, l)
	testing.expect(t, l.current == nil)
	testing.expect_value(t, f.destroyed, 1)
	_ = enrollment_step(&f.e)
	testing.expect(t, l.current != nil)
	testing.expect_value(t, f.minted, 2)
}

@(test)
test_enrollment_repeated_service_listeners_share_grant_credential :: proc(t: ^testing.T) {
	f: EnrollmentFixture
	context.user_ptr = &f
	enrollment_fixture_init(t, &f, true)
	defer enrollment_fixture_destroy(&f)
	delete(f.e.links)
	f.e.links = make([]EnrollmentLink, 2)
	f.e.links[0].cfg = f.cfg.links[0]
	f.e.links[1].cfg = {service = f.cfg.links[0].service, listen = f.cfg.links[1].listen}
	enrollment_share_links(f.e.links)
	enrollment_test_grant(&f, time.time_add(f.at, 8*time.Hour))
	_ = enrollment_step(&f.e)
	testing.expect_value(t, f.minted, 1)
	testing.expect_value(t, f.e.links[1].owner, &f.e.links[0])
	testing.expect(t, f.e.links[0].current != nil)
}
