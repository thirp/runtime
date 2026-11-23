package connect

import trans "../../transport"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

ENROLLMENT_HTTP_TIMEOUT :: 15*time.Second
ENROLLMENT_HTTP_MAX :: 1 << 20
ENROLLMENT_HEADER_MAX :: 16 << 10

EnrollmentError :: enum {None, Retry, Denied, Config, Expired}
EnrollmentRequest :: struct {method, path, bearer, body: string}
EnrollmentResponse :: struct {
	status: int,
	body: string,
	failure: string, // local reason class for transport failures
}
EnrollmentHttp :: proc(rawptr, ^EnrollmentConfig, EnrollmentRequest) -> (EnrollmentResponse, EnrollmentError)

// OS DNS APIs have no portable cancellation. The request holds one reference;
// the resolver holds the other and frees its owned input after a late result.
// No stack pointer or socket outlives the bounded request.
EnrollmentResolve :: struct {
	address: string,
	endpoint: net.Endpoint,
	ok: bool,
	ready: sync.Sema,
	refs: int,
	allocator: mem.Allocator,
}

enrollment_resolve_release :: proc(r: ^EnrollmentResolve) {
	if sync.atomic_sub(&r.refs, 1) == 1 {
		delete(r.address, r.allocator)
		free(r, r.allocator)
	}
}

enrollment_resolve_worker :: proc(r: ^EnrollmentResolve) {
	context.allocator = r.allocator
	ep, err := trans.resolve_endpoint(r.address)
	r.endpoint, r.ok = ep, err == .None
	sync.sema_post(&r.ready)
	enrollment_resolve_release(r)
}

enrollment_resolve :: proc(address: string, until: time.Time) -> (net.Endpoint, bool) {
	if ep, err := trans.parse_endpoint(address); err == .None {return ep, true}
	r := new(EnrollmentResolve)
	r.address, r.refs, r.allocator = strings.clone(address), 2, context.allocator
	th := thread.create_and_start_with_poly_data(r, enrollment_resolve_worker, self_cleanup = true)
	if th == nil {enrollment_resolve_release(r); enrollment_resolve_release(r); return {}, false}
	defer enrollment_resolve_release(r)
	if !sync.sema_wait_with_timeout(&r.ready, max(0, time.diff(time.now(), until))) {return {}, false}
	return r.endpoint, r.ok
}

// The conf names an HTTPS origin. Paths and queries are constructed here.
enrollment_api_address :: proc(api: string) -> (hostport, host, address: string, ok: bool) {
	if !strings.has_prefix(api, ENROLLMENT_HTTPS) {return}
	hostport = strings.trim_suffix(api[len(ENROLLMENT_HTTPS):], "/")
	if len(hostport) == 0 || strings.contains_any(hostport, "/?#@\r\n\t \x00") {return}
	address = hostport
	if strings.has_prefix(hostport, "[") {
		end := strings.index_byte(hostport, ']')
		if end < 0 {return}
		if end == len(hostport)-1 {address = fmt.tprintf("%s:443", hostport)}
	} else if !strings.contains(hostport, ":") {address = fmt.tprintf("%s:443", hostport)}
	host, _, ok = net.split_port(address)
	_, port, port_ok := net.split_port(address)
	if !port_ok || port <= 0 || len(host) == 0 {ok = false}
	return
}

EnrollmentDeadline :: struct {
	mutex: sync.Mutex,
	cond: sync.Cond,
	until: time.Time,
	conn: ^trans.Connection,
	cancelled: bool,
}

enrollment_deadline_watch :: proc(d: ^EnrollmentDeadline) {
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	for !d.cancelled {
		left := time.diff(time.now(), d.until)
		if left <= 0 {trans.connection_close(d.conn); return}
		_ = sync.cond_wait_with_timeout(&d.cond, &d.mutex, left)
	}
}

enrollment_network_http :: proc(_: rawptr, cfg: ^EnrollmentConfig, req: EnrollmentRequest) -> (EnrollmentResponse, EnrollmentError) {
	hostport, host, address, ok := enrollment_api_address(cfg.api)
	if !ok {return {}, .Config}
	until := time.time_add(time.now(), ENROLLMENT_HTTP_TIMEOUT)
	ep, resolved := enrollment_resolve(address, until)
	if !resolved {return {failure = "dns"}, .Retry}
	trans.openssl_ensure_init()
	left := time.diff(time.now(), until)
	if left <= 0 {return {failure = "timeout"}, .Retry}
	conn, derr := trans.connection_dial_timeout(ep, left)
	if derr != .None {return {failure = derr == .Timeout ? "timeout" : "connect"}, .Retry}
	defer trans.connection_destroy(conn)
	d := EnrollmentDeadline{until = until, conn = conn}
	th := thread.create_and_start_with_poly_data(&d, enrollment_deadline_watch)
	if th == nil {return {failure = "internal"}, .Retry}
	defer {
		sync.mutex_lock(&d.mutex)
		d.cancelled = true
		sync.cond_signal(&d.cond)
		sync.mutex_unlock(&d.mutex)
		thread.join(th); thread.destroy(th)
	}
	left = time.diff(time.now(), until)
	if left <= 0 {return {failure = "timeout"}, .Retry}
	verify_failed: bool
	if trans.connection_tls_connect(conn, {ca_path = cfg.api_tls_ca, server_name = host}, left,
		&verify_failed, verify_ip = net.parse_address(host) != nil) != .None {
		if verify_failed {return {failure = "tls_verify"}, .Retry}
		if time.now()._nsec >= until._nsec {return {failure = "timeout"}, .Retry}
		return {failure = "tls_handshake"}, .Retry
	}
	_ = trans.connection_set_recv_timeout(conn, ENROLLMENT_HTTP_TIMEOUT)
	_ = trans.connection_set_send_timeout(conn, ENROLLMENT_HTTP_TIMEOUT)
	wire := enrollment_http_request(hostport, req)
	defer delete(wire)
	if err := trans.connection_write(conn, transmute([]u8)wire); err != .None {
		return {failure = err == .Timeout || time.now()._nsec >= until._nsec ? "timeout" : "http_io"}, .Retry
	}
	raw: [dynamic]u8
	defer delete(raw)
	buf: [4096]u8
	for {
		n, err := trans.connection_read(conn, buf[:])
		if len(raw)+n > ENROLLMENT_HTTP_MAX {return {failure = "invalid_response"}, .Retry}
		append(&raw, ..buf[:n])
		if time.now()._nsec >= until._nsec || err == .Timeout {return {failure = "timeout"}, .Retry}
		if err == .Closed {break}
		if err != .None {return {failure = "http_io"}, .Retry}
	}
	return enrollment_http_response(string(raw[:]))
}

enrollment_http_request :: proc(host: string, req: EnrollmentRequest) -> string {
	return fmt.aprintf("%s %s %s\r\n%s: %s\r\n%s: %s%s\r\n%s: %s\r\n%s: %s\r\n%s: %d\r\n\r\n%s",
		req.method, req.path, ENROLLMENT_HTTP_VERSION, ENROLLMENT_HEADER_HOST, host,
		ENROLLMENT_HEADER_AUTHORIZATION, ENROLLMENT_BEARER, req.bearer,
		ENROLLMENT_HEADER_CONTENT_TYPE, ENROLLMENT_JSON, ENROLLMENT_HEADER_CONNECTION, ENROLLMENT_CLOSE,
		ENROLLMENT_HEADER_CONTENT_LENGTH, len(req.body), req.body)
}

// Connection: close supplies framing when Content-Length is absent. Never
// accept a truncated length or chunk, or two competing framing headers.
enrollment_http_response :: proc(raw: string) -> (EnrollmentResponse, EnrollmentError) {
	end := strings.index(raw, "\r\n\r\n")
	if end < 0 || end > ENROLLMENT_HEADER_MAX || len(raw) > ENROLLMENT_HTTP_MAX {return {}, .Retry}
	head, body := raw[:end], raw[end+4:]
	lines := strings.split(head, "\r\n")
	defer delete(lines)
	if len(lines) == 0 || !strings.has_prefix(lines[0], ENROLLMENT_HTTP_VERSION+" ") || len(lines[0]) < 12 {return {}, .Retry}
	if len(lines[0]) > 12 && lines[0][12] != ' ' {return {}, .Retry}
	status, ok := strconv.parse_int(lines[0][9:12])
	if !ok || status < 200 || status > 599 {return {}, .Retry}
	length := -1
	chunked := false
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {return {}, .Retry}
		key, value := line[:colon], strings.trim_space(line[colon+1:])
		if strings.equal_fold(key, ENROLLMENT_HEADER_CONTENT_LENGTH) {
			if length >= 0 {return {}, .Retry}
			length, ok = strconv.parse_int(value)
			if !ok || length < 0 {return {}, .Retry}
		} else if strings.equal_fold(key, ENROLLMENT_HEADER_TRANSFER_ENCODING) {
			if chunked || !strings.equal_fold(value, ENROLLMENT_CHUNKED) {return {}, .Retry}
			chunked = true
		}
	}
	if chunked {
		if length >= 0 {return {}, .Retry}
		decoded: [dynamic]u8
		defer delete(decoded)
		for {
			nl := strings.index(body, "\r\n")
			if nl < 0 {return {}, .Retry}
			size := body[:nl]
			if semi := strings.index_byte(size, ';'); semi >= 0 {size = size[:semi]}
			n, valid := strconv.parse_int(size, 16)
			body = body[nl+2:]
			if !valid || n < 0 || n > len(body)-2 {return {}, .Retry}
			if n == 0 {
				// Trailers may be present; the terminating empty line is required.
				if body != "\r\n" && !strings.has_suffix(body, "\r\n\r\n") {return {}, .Retry}
				return {status = status, body = strings.clone(string(decoded[:]))}, .None
			}
			if body[n:n+2] != "\r\n" {return {}, .Retry}
			append(&decoded, ..transmute([]u8)body[:n])
			body = body[n+2:]
		}
	}
	if length >= 0 && length != len(body) {return {}, .Retry}
	return {status = status, body = strings.clone(body)}, .None
}

enrollment_string :: proc(v: json.Value, key: string) -> string {
	obj, ok := v.(json.Object)
	if !ok {return ""}
	s, _ := obj[key].(json.String)
	return s
}

enrollment_array :: proc(v: json.Value, key: string) -> (json.Array, bool) {
	obj, ok := v.(json.Object)
	if !ok {return {}, false}
	a, aok := obj[key].(json.Array)
	return a, aok
}

enrollment_time :: proc(v: json.Value, key: string) -> time.Time {
	s := enrollment_string(v, key)
	// Preserve all fractional nanoseconds (core:time's parser reads hundredths).
	dot := strings.index_byte(s, '.')
	if dot < 0 {
		ts, n := time.rfc3339_to_time_utc(s)
		if n != len(s) {return {}}
		return ts
	}
	i := dot+1
	nanos: i64
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		if i-dot > 9 {return {}}
		nanos = nanos*10+i64(s[i]-'0')
		i += 1
	}
	if i == dot+1 {return {}}
	for _ in 0..<9-(i-dot-1) {nanos *= 10}
	base := fmt.tprintf("%s%s", s[:dot], s[i:])
	ts, n := time.rfc3339_to_time_utc(base)
	if n != len(base) {return {}}
	ts._nsec += nanos
	return ts
}
