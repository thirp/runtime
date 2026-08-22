package web_ingress

import cl "../caller"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

HISTOGRAM_FINITE_BOUNDS :: [11]f64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}
HISTOGRAM_BUCKET_COUNT :: 12

ConnResult :: enum {
	Ok,
	Error,
	Timeout,
	Limit,
	HandshakeFailed,
	Rejected,
}

RouteFailureReason :: enum {
	UnknownRoute,
	MissingSni,
	InvalidPublicHost,
	Draining,
}

TlsHandshakeResult :: enum {
	Ok,
	Error,
	Timeout,
}

DialResult :: enum {
	Ok,
	Error,
	Timeout,
	Unauthorized,
	Unavailable,
	RateLimited,
}

ByteDirection :: enum {
	BrowserToOrigin,
	OriginToBrowser,
}

LimitKind :: enum {
	Connections,
	ConnectionsPerIp,
}

LatencyKind :: enum {
	ConnectionDuration,
	ServiceDial,
}

LatencyHistogram :: struct {
	buckets: [HISTOGRAM_BUCKET_COUNT]u64,
	sum_ns:  u64,
	count:   u64,
}

IngressMetrics :: struct {
	active_connections: i64,
	connections:        [ConnResult]u64,
	route_failures:     [RouteFailureReason]u64,
	tls_handshakes:     [TlsHandshakeResult]u64,
	service_dials:      [DialResult]u64,
	bytes:              [ByteDirection]u64,
	limit_exceeds:      [LimitKind]u64,
	latency:            [LatencyKind]LatencyHistogram,
}

IngressMetricsSnapshot :: struct {
	active_connections: int,
	connections:        [ConnResult]u64,
	route_failures:     [RouteFailureReason]u64,
	tls_handshakes:     [TlsHandshakeResult]u64,
	service_dials:      [DialResult]u64,
	bytes:              [ByteDirection]u64,
	limit_exceeds:      [LimitKind]u64,
	latency:            [LatencyKind]LatencyHistogram,
}

conn_result_label :: proc(r: ConnResult) -> string {
	switch r {
	case .Ok:
		return "ok"
	case .Error:
		return "error"
	case .Timeout:
		return "timeout"
	case .Limit:
		return "limit"
	case .HandshakeFailed:
		return "handshake_failed"
	case .Rejected:
		return "rejected"
	}
	return "error"
}

route_failure_label :: proc(r: RouteFailureReason) -> string {
	switch r {
	case .UnknownRoute:
		return "unknown_route"
	case .MissingSni:
		return "missing_sni"
	case .InvalidPublicHost:
		return "invalid_public_host"
	case .Draining:
		return "draining"
	}
	return "unknown_route"
}

tls_handshake_label :: proc(r: TlsHandshakeResult) -> string {
	switch r {
	case .Ok:
		return "ok"
	case .Error:
		return "error"
	case .Timeout:
		return "timeout"
	}
	return "error"
}

dial_result_label :: proc(r: DialResult) -> string {
	switch r {
	case .Ok:
		return "ok"
	case .Error:
		return "error"
	case .Timeout:
		return "timeout"
	case .Unauthorized:
		return "unauthorized"
	case .Unavailable:
		return "unavailable"
	case .RateLimited:
		return "rate_limited"
	}
	return "error"
}

byte_direction_label :: proc(d: ByteDirection) -> string {
	switch d {
	case .BrowserToOrigin:
		return "browser_to_origin"
	case .OriginToBrowser:
		return "origin_to_browser"
	}
	return "browser_to_origin"
}

limit_kind_label :: proc(k: LimitKind) -> string {
	switch k {
	case .Connections:
		return "connections"
	case .ConnectionsPerIp:
		return "connections_per_ip"
	}
	return "connections"
}

latency_kind_name :: proc(k: LatencyKind) -> string {
	switch k {
	case .ConnectionDuration:
		return "connection_duration"
	case .ServiceDial:
		return "service_dial"
	}
	return "connection_duration"
}

metrics_inc_u64 :: proc(p: ^u64, n: u64 = 1) {
	sync.atomic_add(p, n)
}

metrics_inc_conn :: proc(m: ^IngressMetrics, result: ConnResult) {
	if m == nil {
		return
	}
	metrics_inc_u64(&m.connections[result])
}

metrics_inc_route_failure :: proc(m: ^IngressMetrics, reason: RouteFailureReason) {
	if m == nil {
		return
	}
	metrics_inc_u64(&m.route_failures[reason])
}

metrics_inc_tls :: proc(m: ^IngressMetrics, result: TlsHandshakeResult) {
	if m == nil {
		return
	}
	metrics_inc_u64(&m.tls_handshakes[result])
}

metrics_inc_dial :: proc(m: ^IngressMetrics, result: DialResult) {
	if m == nil {
		return
	}
	metrics_inc_u64(&m.service_dials[result])
}

metrics_inc_bytes :: proc(m: ^IngressMetrics, dir: ByteDirection, n: u64) {
	if m == nil || n == 0 {
		return
	}
	metrics_inc_u64(&m.bytes[dir], n)
}

metrics_inc_limit :: proc(m: ^IngressMetrics, kind: LimitKind) {
	if m == nil {
		return
	}
	metrics_inc_u64(&m.limit_exceeds[kind])
}

metrics_add_active :: proc(m: ^IngressMetrics, delta: i64) {
	if m == nil {
		return
	}
	sync.atomic_add(&m.active_connections, delta)
}

metrics_observe :: proc(m: ^IngressMetrics, kind: LatencyKind, d: time.Duration) {
	if m == nil || d < 0 {
		return
	}
	h := &m.latency[kind]
	seconds := f64(d) / f64(time.Second)
	bounds := HISTOGRAM_FINITE_BOUNDS
	for i in 0 ..< len(bounds) {
		if seconds <= bounds[i] {
			sync.atomic_add(&h.buckets[i], 1)
		}
	}
	sync.atomic_add(&h.buckets[HISTOGRAM_BUCKET_COUNT - 1], 1)
	sync.atomic_add(&h.count, 1)
	sync.atomic_add(&h.sum_ns, u64(d))
}

metrics_copy_histogram :: proc(src: ^LatencyHistogram) -> LatencyHistogram {
	out: LatencyHistogram
	for i in 0 ..< HISTOGRAM_BUCKET_COUNT {
		out.buckets[i] = sync.atomic_load(&src.buckets[i])
	}
	out.sum_ns = sync.atomic_load(&src.sum_ns)
	out.count = sync.atomic_load(&src.count)
	return out
}

metrics_snapshot :: proc(server: ^IngressServer) -> IngressMetricsSnapshot {
	snap: IngressMetricsSnapshot
	if server == nil {
		return snap
	}
	m := &server.metrics
	snap.active_connections = int(sync.atomic_load(&m.active_connections))
	for r in ConnResult {
		snap.connections[r] = sync.atomic_load(&m.connections[r])
	}
	for r in RouteFailureReason {
		snap.route_failures[r] = sync.atomic_load(&m.route_failures[r])
	}
	for r in TlsHandshakeResult {
		snap.tls_handshakes[r] = sync.atomic_load(&m.tls_handshakes[r])
	}
	for r in DialResult {
		snap.service_dials[r] = sync.atomic_load(&m.service_dials[r])
	}
	for d in ByteDirection {
		snap.bytes[d] = sync.atomic_load(&m.bytes[d])
	}
	for k in LimitKind {
		snap.limit_exceeds[k] = sync.atomic_load(&m.limit_exceeds[k])
	}
	for k in LatencyKind {
		snap.latency[k] = metrics_copy_histogram(&m.latency[k])
	}
	return snap
}

metrics_write_prometheus :: proc(snap: IngressMetricsSnapshot, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_gauge(&b, "active_connections", "Active browser connections", snap.active_connections)
	write_conn_results(&b, snap.connections)
	write_route_failures(&b, snap.route_failures)
	write_tls_handshakes(&b, snap.tls_handshakes)
	write_service_dials(&b, snap.service_dials)
	write_bytes(&b, snap.bytes)
	write_limits(&b, snap.limit_exceeds)
	write_histogram(&b, .ConnectionDuration, "Browser connection duration in seconds", snap.latency[.ConnectionDuration])
	write_histogram(&b, .ServiceDial, "Service dial duration in seconds", snap.latency[.ServiceDial])
	return strings.to_string(b)
}

write_gauge :: proc(b: ^strings.Builder, name: string, help: string, value: int) {
	fmt.sbprintf(b, "# HELP thirp_web_ingress_%s %s\n", name, help)
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_%s gauge\n", name)
	fmt.sbprintf(b, "thirp_web_ingress_%s %d\n", name, value)
}

write_conn_results :: proc(b: ^strings.Builder, values: [ConnResult]u64) {
	fmt.sbprintf(b, "# HELP thirp_web_ingress_connections_total Browser connections by result\n")
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_connections_total counter\n")
	for r in ConnResult {
		fmt.sbprintf(b, "thirp_web_ingress_connections_total{{result=\"%s\"}} %d\n", conn_result_label(r), values[r])
	}
}

write_route_failures :: proc(b: ^strings.Builder, values: [RouteFailureReason]u64) {
	fmt.sbprintf(b, "# HELP thirp_web_ingress_route_failures_total Route selection failures by reason\n")
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_route_failures_total counter\n")
	for r in RouteFailureReason {
		fmt.sbprintf(b, "thirp_web_ingress_route_failures_total{{reason=\"%s\"}} %d\n", route_failure_label(r), values[r])
	}
}

write_tls_handshakes :: proc(b: ^strings.Builder, values: [TlsHandshakeResult]u64) {
	fmt.sbprintf(b, "# HELP thirp_web_ingress_tls_handshakes_total Browser TLS handshakes by result\n")
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_tls_handshakes_total counter\n")
	for r in TlsHandshakeResult {
		fmt.sbprintf(b, "thirp_web_ingress_tls_handshakes_total{{result=\"%s\"}} %d\n", tls_handshake_label(r), values[r])
	}
}

write_service_dials :: proc(b: ^strings.Builder, values: [DialResult]u64) {
	fmt.sbprintf(b, "# HELP thirp_web_ingress_service_dials_total Caller service dials by result\n")
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_service_dials_total counter\n")
	for r in DialResult {
		fmt.sbprintf(b, "thirp_web_ingress_service_dials_total{{result=\"%s\"}} %d\n", dial_result_label(r), values[r])
	}
}

write_bytes :: proc(b: ^strings.Builder, values: [ByteDirection]u64) {
	fmt.sbprintf(b, "# HELP thirp_web_ingress_bytes_total Relayed application bytes\n")
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_bytes_total counter\n")
	for d in ByteDirection {
		fmt.sbprintf(b, "thirp_web_ingress_bytes_total{{direction=\"%s\"}} %d\n", byte_direction_label(d), values[d])
	}
}

write_limits :: proc(b: ^strings.Builder, values: [LimitKind]u64) {
	fmt.sbprintf(b, "# HELP thirp_web_ingress_limit_exceeds_total Public connection limit rejects\n")
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_limit_exceeds_total counter\n")
	for k in LimitKind {
		fmt.sbprintf(b, "thirp_web_ingress_limit_exceeds_total{{limit=\"%s\"}} %d\n", limit_kind_label(k), values[k])
	}
}

write_histogram :: proc(b: ^strings.Builder, kind: LatencyKind, help: string, h: LatencyHistogram) {
	name := latency_kind_name(kind)
	fmt.sbprintf(b, "# HELP thirp_web_ingress_%s_seconds %s\n", name, help)
	fmt.sbprintf(b, "# TYPE thirp_web_ingress_%s_seconds histogram\n", name)
	bounds := HISTOGRAM_FINITE_BOUNDS
	for i in 0 ..< len(bounds) {
		fmt.sbprintf(
			b,
			"thirp_web_ingress_%s_seconds_bucket{{le=\"%g\"}} %d\n",
			name,
			bounds[i],
			h.buckets[i],
		)
	}
	fmt.sbprintf(
		b,
		"thirp_web_ingress_%s_seconds_bucket{{le=\"+Inf\"}} %d\n",
		name,
		h.buckets[HISTOGRAM_BUCKET_COUNT - 1],
	)
	sum := f64(h.sum_ns) / 1_000_000_000.0
	fmt.sbprintf(b, "thirp_web_ingress_%s_seconds_sum %g\n", name, sum)
	fmt.sbprintf(b, "thirp_web_ingress_%s_seconds_count %d\n", name, h.count)
}

dial_result_from_caller :: proc(err: cl.CallerError) -> DialResult {
	switch err {
	case .None:
		return .Ok
	case .Timeout:
		return .Timeout
	case .Unauthorized:
		return .Unauthorized
	case .RateLimited:
		return .RateLimited
	case .ServiceNotFound, .AgentUnavailable, .LocalServiceUnavailable, .QuotaExceeded, .BrokerDraining:
		return .Unavailable
	case .InvalidConfig, .InvalidServiceId, .Transport, .AuthFailed, .Closed, .Internal, .OutOfMemory:
		return .Error
	}
	return .Error
}
