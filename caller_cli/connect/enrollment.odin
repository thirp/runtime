package connect

import log "../../logging"
import private_file "private_file"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

CALLER_ENROLLMENT_ROTATE_WINDOW :: 30*24*time.Hour
ENROLLMENT_ROTATE_CHECK :: 6*time.Hour
ENROLLMENT_POLL_MIN :: time.Second
ENROLLMENT_POLL_MAX :: 30*time.Second
ENROLLMENT_SLOW_POLL :: time.Minute
ENROLLMENT_GRANT_SECONDS :: 28800
ENROLLMENT_GRANT_TOKEN_PREFIX :: "thirp_cal_"

EnrollmentPlan :: struct {
	grant_id, credential_id, service_id, token: string,
	grant_end, expires_at, renew_at, rollover_at: time.Time,
}

Enrollment :: struct {
	cfg: ^EnrollmentConfig,
	token: string, // owned; never reload a competing process's token
	expires_at, self_next: time.Time,
	denied: bool,
	pending_token: string,
	pending_expiry: time.Time,
	links: []EnrollmentLink,
	http: EnrollmentHttp,
	user: rawptr,
	now: proc(rawptr) -> time.Time,
	logger: log.Logger,
	// Fake broker setup/destruction for the socket-free maintenance tests.
	new_caller: proc(^Enrollment, ^EnrollmentLink) -> (^EnrollmentCaller, bool),
	destroy_caller: proc(^EnrollmentCaller),
}

enrollment_now :: proc(e: ^Enrollment) -> time.Time {
	if e.now != nil {return e.now(e.user)}
	return time.now()
}

enrollment_intervals :: proc() -> (poll_min, poll_max, slow, rotate: time.Duration) {
	when #config(THIRP_LAB_TIMERS, false) {
		return 100*time.Millisecond, time.Second, time.Second, time.Second
	} else {return ENROLLMENT_POLL_MIN, ENROLLMENT_POLL_MAX, ENROLLMENT_SLOW_POLL, ENROLLMENT_ROTATE_CHECK}
}

enrollment_log :: proc(e: ^Enrollment, event: string, p: ^EnrollmentPlan = nil) {
	fields := log.LogFields{organization_id = e.cfg.org, principal_id = e.cfg.enrollment,
		reason = fmt.tprintf("expiry_unix=%d", time.time_to_unix(e.expires_at))}
	if p != nil {
		fields.principal_id = p.grant_id
		fields.credential_label = p.credential_id
		fields.reason = fmt.tprintf("expiry_unix=%d grant_end_unix=%d", time.time_to_unix(p.expires_at), time.time_to_unix(p.grant_end))
	}
	log.log_event(&e.logger, .Info, event, fields)
}

enrollment_call :: proc(e: ^Enrollment, method, suffix: string, body := "") -> (json.Value, EnrollmentError) {
	fn := e.http
	if fn == nil {fn = enrollment_network_http}
	path := fmt.aprintf("%s%s%s", ENROLLMENT_ORGS, e.cfg.org, suffix)
	defer delete(path)
	r, err := fn(e.user, e.cfg, {method, path, e.token, body})
	defer delete(r.body)
	if err != .None {return {}, err}
	if r.status == ENROLLMENT_STATUS_UNAUTHORIZED || r.status == ENROLLMENT_STATUS_FORBIDDEN {return {}, .Denied}
	expected := ENROLLMENT_STATUS_OK
	if method == ENROLLMENT_POST && (suffix == ENROLLMENT_REQUESTS || strings.has_suffix(suffix, ENROLLMENT_CREDENTIALS)) {expected = ENROLLMENT_STATUS_CREATED}
	if r.status != expected {return {}, .Retry}
	v, jerr := json.parse(r.body, .JSON)
	if jerr != .None {return {}, .Retry}
	if _, ok := v.(json.Object); !ok {json.destroy_value(v); return {}, .Retry}
	return v, .None
}

enrollment_write_token :: private_file.write_token

enrollment_self :: proc(e: ^Enrollment) -> EnrollmentError {
	now := enrollment_now(e)
	_, _, slow, rotate := enrollment_intervals()
	e.self_next = time.time_add(now, slow)
	if len(e.pending_token) > 0 {
		if !enrollment_write_token(e.cfg.token_file, e.pending_token) {return .Retry}
		delete(e.token)
		e.token, e.expires_at = e.pending_token, e.pending_expiry
		e.pending_token, e.pending_expiry = "", {}
		e.denied = false
		enrollment_log(e, "enrollment rotated")
	}
	v, err := enrollment_call(e, ENROLLMENT_GET, ENROLLMENT_SELF)
	if err != .None {return err}
	defer json.destroy_value(v)
	if enrollment_string(v, ENROLLMENT_ID) != e.cfg.enrollment {return .Config}
	exp := enrollment_time(v, ENROLLMENT_EXPIRES_AT)
	if exp == {} {return .Retry}
	e.expires_at = exp
	if exp._nsec <= now._nsec {return .Expired}
	if enrollment_string(v, ENROLLMENT_STATE) == ENROLLMENT_REVOKED {return .Denied}
	e.denied = false
	if time.diff(now, exp) <= CALLER_ENROLLMENT_ROTATE_WINDOW {
		r, rerr := enrollment_call(e, ENROLLMENT_POST, ENROLLMENT_SELF+ENROLLMENT_ROTATE, ENROLLMENT_EMPTY_OBJECT)
		if rerr != .None {return rerr}
		defer json.destroy_value(r)
		token := enrollment_string(r, ENROLLMENT_TOKEN)
		expires := enrollment_time(r, ENROLLMENT_EXPIRES_AT)
		previous := enrollment_time(r, ENROLLMENT_PREVIOUS_EXPIRES_AT)
		if !enrollment_token_ok(token) || expires._nsec <= now._nsec || previous == {} || !enrollment_id_ok(enrollment_string(r, ENROLLMENT_CREDENTIAL_ID)) {return .Retry}
		e.pending_token = strings.clone(token)
		e.pending_expiry = expires
		// Until persistence succeeds, the old credential is bounded by overlap.
		e.expires_at = previous
		if !enrollment_write_token(e.cfg.token_file, e.pending_token) {return .Retry}
		delete(e.token)
		e.token, e.expires_at = e.pending_token, expires
		e.pending_token, e.pending_expiry = "", {}
		enrollment_log(e, "enrollment rotated")
	}
	e.self_next = time.time_add(now, rotate)
	return .None
}

enrollment_plan_destroy :: proc(p: ^EnrollmentPlan) {
	delete(p.grant_id); delete(p.credential_id); delete(p.service_id); delete(p.token)
	p^ = {}
}

enrollment_renew_at :: proc(now, expires: time.Time) -> time.Time {
	return time.Time{_nsec = now._nsec+(expires._nsec-now._nsec)/2}
}

enrollment_grant :: proc(e: ^Enrollment, l: ^EnrollmentLink, v: json.Value, p: ^EnrollmentPlan) -> bool {
	now := enrollment_now(e)
	state := enrollment_string(v, ENROLLMENT_STATE)
	if state != ENROLLMENT_ACTIVE && !(len(e.cfg.environment) == 0 && state == ENROLLMENT_APPROVED) {return false}
	if enrollment_string(v, ENROLLMENT_CATALOG_SERVICE_ID) != l.cfg.service || enrollment_string(v, ENROLLMENT_ENVIRONMENT_ID) != e.cfg.environment {return false}
	from, until := enrollment_time(v, ENROLLMENT_VALID_FROM), enrollment_time(v, ENROLLMENT_VALID_UNTIL)
	if from == {} || now._nsec < from._nsec || now._nsec >= until._nsec {return false}
	id, service := enrollment_string(v, ENROLLMENT_ID), enrollment_string(v, ENROLLMENT_SERVICE_ID)
	if !enrollment_id_ok(id) || len(service) == 0 {return false}
	// When preparing a rollover, the current grant cannot replace itself.
	if id == l.plan.grant_id {return false}
	p.grant_id, p.service_id = strings.clone(id), strings.clone(service)
	p.grant_end = until
	margin := min(2*time.Minute, time.Duration((until._nsec-now._nsec)/4))
	p.rollover_at = time.time_add(until, -margin)
	return true
}

enrollment_pick_grant :: proc(e: ^Enrollment, l: ^EnrollmentLink) -> (bool, EnrollmentError) {
	suffix := ENROLLMENT_GRANTS
	separator := "?"
	if len(e.cfg.environment) > 0 {
		suffix = fmt.tprintf("%s?%s=%s", suffix, ENROLLMENT_ENVIRONMENT_ID, e.cfg.environment)
		separator = "&"
	}
	// List all pages and match the catalog id locally: caller.conf contains
	// catalog ids, while the API's service_id query accepts broker wire ids.
	cursor := ""
	defer delete(cursor)
	for page in 0..<1024 {
		query := suffix
		if len(cursor) > 0 {query = fmt.tprintf("%s%s%s=%s", suffix, separator, ENROLLMENT_CURSOR, cursor)}
		v, err := enrollment_call(e, ENROLLMENT_GET, query)
		if err != .None {return false, err}
		defer json.destroy_value(v)
		items, ok := enrollment_array(v, ENROLLMENT_ITEMS)
		if !ok {return false, .Retry}
		for item in items {if enrollment_grant(e, l, item, &l.pending) {return true, .None}}
		next := enrollment_string(v, ENROLLMENT_NEXT_CURSOR)
		if len(next) == 0 {return false, .None}
		if next == cursor {return false, .Retry}
		delete(cursor)
		cursor = enrollment_query_escape(next)
	}
	return false, .Retry
}

enrollment_query_escape :: proc(s: string) -> string {
	buf: [dynamic]u8
	defer delete(buf)
	HEX :: "0123456789ABCDEF"
	hex := HEX
	for b in transmute([]u8)s {
		if b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '-' || b == '_' || b == '.' || b == '~' {append(&buf, b)}
		else {append(&buf, u8('%'), hex[b>>4], hex[b&15])}
	}
	return strings.clone(string(buf[:]))
}

enrollment_create_grant :: proc(e: ^Enrollment, l: ^EnrollmentLink) -> EnrollmentError {
	if len(e.cfg.environment) > 0 {return .Denied}
	v, err := enrollment_call(e, ENROLLMENT_GET, "")
	if err != .None {return err}
	platforms := enrollment_string(v, ENROLLMENT_PLAN_ID) == ENROLLMENT_PLATFORMS
	json.destroy_value(v)
	if !platforms {return .None}
	if len(l.request_id) == 0 {
		request := make(json.Object)
		services := make(json.Array)
		append(&services, json.String(l.cfg.service))
		defer delete(services)
		request[ENROLLMENT_CATALOG_SERVICE_IDS] = services
		request[ENROLLMENT_REASON] = "Connecting to my Service"
		request[ENROLLMENT_DURATION_SECONDS] = ENROLLMENT_GRANT_SECONDS
		defer delete(request)
		body, jerr := json.marshal(request)
		if jerr != nil {return .Retry}
		defer delete(body)
		created, cerr := enrollment_call(e, ENROLLMENT_POST, ENROLLMENT_REQUESTS, string(body))
		if cerr != .None {return cerr}
		id := enrollment_string(created, ENROLLMENT_ID)
		if enrollment_id_ok(id) {l.request_id = strings.clone(id)}
		json.destroy_value(created)
		if len(l.request_id) == 0 {return .Retry}
	}
	approved, aerr := enrollment_call(e, ENROLLMENT_POST, fmt.tprintf("%s/%s%s", ENROLLMENT_REQUESTS, l.request_id, ENROLLMENT_APPROVE), ENROLLMENT_EMPTY_OBJECT)
	if aerr != .None {return aerr}
	defer json.destroy_value(approved)
	grants, ok := enrollment_array(approved, ENROLLMENT_GRANT_ITEMS)
	if !ok {return .Retry}
	delete(l.request_id); l.request_id = ""
	for item in grants {if enrollment_grant(e, l, item, &l.pending) {return .None}}
	return .Retry
}

enrollment_mint :: proc(e: ^Enrollment, p: ^EnrollmentPlan) -> EnrollmentError {
	v, err := enrollment_call(e, ENROLLMENT_POST, fmt.tprintf("%s/%s%s", ENROLLMENT_GRANTS, p.grant_id, ENROLLMENT_CREDENTIALS), ENROLLMENT_EMPTY_OBJECT)
	if err != .None {return err}
	defer json.destroy_value(v)
	token, id := enrollment_string(v, ENROLLMENT_TOKEN), enrollment_string(v, ENROLLMENT_CREDENTIAL_ID)
	exp := enrollment_time(v, ENROLLMENT_EXPIRES_AT)
	if !strings.has_prefix(token, ENROLLMENT_GRANT_TOKEN_PREFIX) || strings.contains_any(token, "\r\n \t") || !enrollment_id_ok(id) || exp._nsec <= enrollment_now(e)._nsec || exp._nsec > p.grant_end._nsec {return .Retry}
	p.token, p.credential_id, p.expires_at = strings.clone(token), strings.clone(id), exp
	p.renew_at = enrollment_renew_at(enrollment_now(e), exp)
	if exp == p.grant_end {p.renew_at = p.grant_end}
	return .None
}

enrollment_renew :: proc(e: ^Enrollment, p: ^EnrollmentPlan) -> EnrollmentError {
	v, err := enrollment_call(e, ENROLLMENT_POST, fmt.tprintf("%s/%s%s/%s%s", ENROLLMENT_GRANTS, p.grant_id, ENROLLMENT_CREDENTIALS, p.credential_id, ENROLLMENT_RENEW), ENROLLMENT_EMPTY_OBJECT)
	if err != .None {return err}
	defer json.destroy_value(v)
	exp := enrollment_time(v, ENROLLMENT_EXPIRES_AT)
	if enrollment_string(v, ENROLLMENT_CREDENTIAL_ID) != p.credential_id || exp._nsec <= enrollment_now(e)._nsec || exp._nsec > p.grant_end._nsec {return .Retry}
	p.expires_at = exp
	p.renew_at = enrollment_renew_at(enrollment_now(e), exp)
	if exp == p.grant_end {p.renew_at = p.grant_end}
	return .None
}
