package broker

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

HISTOGRAM_FINITE_BOUNDS :: [11]f64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}
HISTOGRAM_BUCKET_COUNT :: 12

ResetReason :: enum {
	StreamBuffer,
	ConnectionBuffer,
	Peer,
	StreamNotFound,
	ProtocolError,
	CallerGone,
	AgentGone,
	IdleTimeout,
	BrokerDraining,
	StreamIdle,
	GrantExpired,
	GrantRevoked,
	LeaseExpired,
}

LimitKind :: enum {
	StreamBuffer,
	ConnectionBuffer,
	StreamsPerSession,
	RegistrationsPerSession,
	PhysicalConnections,
	ConnectionsPerIp,
	FramePayload,
	GlobalBuffer,
	FileDescriptors,
}

ConnectFailureReason :: enum {
	InvalidServiceId,
	ServiceNotFound,
	Unauthorized,
	AgentUnavailable,
	LocalServiceUnavailable,
	QuotaExceeded,
	BrokerDraining,
	ProtocolError,
	InternalError,
	RateLimited,
}

AuthzReason :: enum {
	Capability,
	Namespace,
	NotOwned,
	Unauthorized,
	Quota,
}

RegisterFailureReason :: enum {
	Capability,
	Namespace,
	Unauthorized,
	AlreadyRegistered,
	InvalidServiceId,
	QuotaExceeded,
	BrokerDraining,
	RateLimited,
}

UnregisterFailureReason :: enum {
	Capability,
	NotOwned,
	InvalidServiceId,
	RateLimited,
}

RateLimitKind :: enum {
	Authentication,
	Registration,
	Connect,
}

LatencyKind :: enum {
	Authentication,
	ServiceLookup,
	OpenOk,
	ConnectOk,
}

LatencyHistogram :: struct {
	buckets: [HISTOGRAM_BUCKET_COUNT]u64,
	sum_ns:  u64,
	count:   u64,
}

Metrics :: struct {
	active_caller_connections:     i64,
	registrations_total:           u64,
	unregistrations_total:         u64,
	connection_attempts_total:     u64,
	connection_success_total:      u64,
	bytes_agent_to_caller_total:   u64,
	bytes_caller_to_agent_total:   u64,
	protocol_errors_total:         u64,
	authentication_failures_total: u64,
	role_violations_total:         u64,
	session_timeouts_total:        u64,
	agent_sessions_total:          u64,
	connection_failures:           [ConnectFailureReason]u64,
	authorization_failures:        [AuthzReason]u64,
	registration_failures:         [RegisterFailureReason]u64,
	unregistration_failures:       [UnregisterFailureReason]u64,
	rate_limit_exceeds:            [RateLimitKind]u64,
	resets:                        [ResetReason]u64,
	limit_exceeds:                 [LimitKind]u64,
	latency:                       [LatencyKind]LatencyHistogram,
}

MetricsSnapshot :: struct {
	active_physical_connections:   int,
	active_agent_sessions:         int,
	active_caller_connections:     int,
	registered_services:           int,
	active_relay_streams:          int,
	active_organizations:          int,
	registrations_total:           u64,
	unregistrations_total:         u64,
	connection_attempts_total:     u64,
	connection_success_total:      u64,
	bytes_agent_to_caller_total:   u64,
	bytes_caller_to_agent_total:   u64,
	protocol_errors_total:         u64,
	authentication_failures_total: u64,
	role_violations_total:         u64,
	session_timeouts_total:        u64,
	agent_sessions_total:          u64,
	connection_failures:           [ConnectFailureReason]u64,
	authorization_failures:        [AuthzReason]u64,
	registration_failures:         [RegisterFailureReason]u64,
	unregistration_failures:       [UnregisterFailureReason]u64,
	rate_limit_exceeds:            [RateLimitKind]u64,
	resets:                        [ResetReason]u64,
	limit_exceeds:                 [LimitKind]u64,
	latency:                       [LatencyKind]LatencyHistogram,
}

reset_reason_label :: proc(reason: ResetReason) -> string {
	switch reason {
	case .StreamBuffer:
		return LABEL_STREAM_BUFFER
	case .ConnectionBuffer:
		return LABEL_CONNECTION_BUFFER
	case .Peer:
		return LABEL_PEER
	case .StreamNotFound:
		return LABEL_STREAM_NOT_FOUND
	case .ProtocolError:
		return LABEL_PROTOCOL_ERROR
	case .CallerGone:
		return LABEL_CALLER_GONE
	case .AgentGone:
		return LABEL_AGENT_GONE
	case .IdleTimeout:
		return LABEL_IDLE_TIMEOUT
	case .BrokerDraining:
		return LABEL_BROKER_DRAINING
	case .StreamIdle:
		return LABEL_STREAM_IDLE
	case .GrantExpired:
		return LABEL_GRANT_EXPIRED
	case .GrantRevoked:
		return LABEL_GRANT_REVOKED
	case .LeaseExpired:
		return LABEL_LEASE_EXPIRED
	}
	return LABEL_UNKNOWN
}

limit_kind_label :: proc(kind: LimitKind) -> string {
	switch kind {
	case .StreamBuffer:
		return LABEL_STREAM_BUFFER
	case .ConnectionBuffer:
		return LABEL_CONNECTION_BUFFER
	case .StreamsPerSession:
		return LABEL_STREAMS_PER_SESSION
	case .RegistrationsPerSession:
		return LABEL_REGISTRATIONS_PER_SESSION
	case .PhysicalConnections:
		return LABEL_PHYSICAL_CONNECTIONS
	case .ConnectionsPerIp:
		return LABEL_CONNECTIONS_PER_IP
	case .FramePayload:
		return LABEL_FRAME_PAYLOAD
	case .GlobalBuffer:
		return LABEL_GLOBAL_BUFFER
	case .FileDescriptors:
		return LABEL_FILE_DESCRIPTORS
	}
	return LABEL_UNKNOWN
}

connect_failure_reason_label :: proc(reason: ConnectFailureReason) -> string {
	switch reason {
	case .InvalidServiceId:
		return LABEL_INVALID_SERVICE_ID
	case .ServiceNotFound:
		return LABEL_SERVICE_NOT_FOUND
	case .Unauthorized:
		return LABEL_UNAUTHORIZED
	case .AgentUnavailable:
		return LABEL_AGENT_UNAVAILABLE
	case .LocalServiceUnavailable:
		return LABEL_LOCAL_SERVICE_UNAVAILABLE
	case .QuotaExceeded:
		return LABEL_QUOTA_EXCEEDED
	case .BrokerDraining:
		return LABEL_BROKER_DRAINING
	case .ProtocolError:
		return LABEL_PROTOCOL_ERROR
	case .InternalError:
		return LABEL_INTERNAL_ERROR
	case .RateLimited:
		return LABEL_RATE_LIMITED
	}
	return LABEL_UNKNOWN
}

authz_reason_label :: proc(reason: AuthzReason) -> string {
	switch reason {
	case .Capability:
		return LABEL_CAPABILITY
	case .Namespace:
		return LABEL_NAMESPACE
	case .NotOwned:
		return LABEL_NOT_OWNED
	case .Unauthorized:
		return LABEL_UNAUTHORIZED
	case .Quota:
		return LABEL_QUOTA
	}
	return LABEL_UNKNOWN
}

register_failure_reason_label :: proc(reason: RegisterFailureReason) -> string {
	switch reason {
	case .Capability:
		return LABEL_CAPABILITY
	case .Namespace:
		return LABEL_NAMESPACE
	case .Unauthorized:
		return LABEL_UNAUTHORIZED
	case .AlreadyRegistered:
		return LABEL_ALREADY_REGISTERED
	case .InvalidServiceId:
		return LABEL_INVALID_SERVICE_ID
	case .QuotaExceeded:
		return LABEL_QUOTA_EXCEEDED
	case .BrokerDraining:
		return LABEL_BROKER_DRAINING
	case .RateLimited:
		return LABEL_RATE_LIMITED
	}
	return LABEL_UNKNOWN
}

unregister_failure_reason_label :: proc(reason: UnregisterFailureReason) -> string {
	switch reason {
	case .Capability:
		return LABEL_CAPABILITY
	case .NotOwned:
		return LABEL_NOT_OWNED
	case .InvalidServiceId:
		return LABEL_INVALID_SERVICE_ID
	case .RateLimited:
		return LABEL_RATE_LIMITED
	}
	return LABEL_UNKNOWN
}

rate_limit_kind_label :: proc(kind: RateLimitKind) -> string {
	switch kind {
	case .Authentication:
		return LABEL_AUTHENTICATION
	case .Registration:
		return LABEL_REGISTRATION
	case .Connect:
		return LABEL_CONNECT
	}
	return LABEL_UNKNOWN
}

policy_error_to_authz :: proc(err: PolicyError) -> AuthzReason {
	switch err {
	case .MissingCapability:
		return .Capability
	case .NamespaceDenied:
		return .Namespace
	case .QuotaExceeded:
		return .Quota
	case .None, .Unauthorized, .InvalidPattern, .InvalidPrincipal, .OutOfMemory:
		return .Unauthorized
	}
	return .Unauthorized
}

policy_error_to_register_failure :: proc(err: PolicyError) -> RegisterFailureReason {
	switch err {
	case .MissingCapability:
		return .Capability
	case .NamespaceDenied:
		return .Namespace
	case .QuotaExceeded:
		return .QuotaExceeded
	case .None, .Unauthorized, .InvalidPattern, .InvalidPrincipal, .OutOfMemory:
		return .Unauthorized
	}
	return .Unauthorized
}

registry_error_to_register_failure :: proc(err: RegistryError) -> (RegisterFailureReason, bool) {
	switch err {
	case .ServiceAlreadyRegistered:
		return .AlreadyRegistered, true
	case .InvalidServiceId:
		return .InvalidServiceId, true
	case .QuotaExceeded:
		return .QuotaExceeded, true
	case .None, .SessionNotFound, .ServiceNotFound, .NotOwned, .InvalidPrincipal, .OutOfMemory:
		return .AlreadyRegistered, false
	}
	return .AlreadyRegistered, false
}

register_failure_reason_from_registry :: proc(err: RegistryError) -> string {
	reason, ok := registry_error_to_register_failure(err)
	if !ok {
		return ""
	}
	return register_failure_reason_label(reason)
}

latency_kind_name :: proc(kind: LatencyKind) -> string {
	switch kind {
	case .Authentication:
		return LABEL_AUTHENTICATION
	case .ServiceLookup:
		return LABEL_SERVICE_LOOKUP
	case .OpenOk:
		return LABEL_OPEN_OK
	case .ConnectOk:
		return LABEL_CONNECT_OK
	}
	return LABEL_UNKNOWN
}

metrics_inc :: proc(counter: ^u64, n: u64 = 1) {
	if counter == nil || n == 0 {
		return
	}
	sync.atomic_add(counter, n)
}

metrics_inc_reset :: proc(m: ^Metrics, reason: ResetReason) {
	if m == nil {
		return
	}
	metrics_inc(&m.resets[reason])
}

metrics_inc_limit :: proc(m: ^Metrics, kind: LimitKind) {
	if m == nil {
		return
	}
	metrics_inc(&m.limit_exceeds[kind])
}

metrics_inc_connect_failure :: proc(m: ^Metrics, reason: ConnectFailureReason) {
	if m == nil {
		return
	}
	metrics_inc(&m.connection_failures[reason])
}

metrics_inc_authz :: proc(m: ^Metrics, reason: AuthzReason) {
	if m == nil {
		return
	}
	metrics_inc(&m.authorization_failures[reason])
}

metrics_inc_register_failure :: proc(m: ^Metrics, reason: RegisterFailureReason) {
	if m == nil {
		return
	}
	metrics_inc(&m.registration_failures[reason])
}

metrics_inc_unregister_failure :: proc(m: ^Metrics, reason: UnregisterFailureReason) {
	if m == nil {
		return
	}
	metrics_inc(&m.unregistration_failures[reason])
}

metrics_inc_rate_limit :: proc(m: ^Metrics, kind: RateLimitKind) {
	if m == nil {
		return
	}
	metrics_inc(&m.rate_limit_exceeds[kind])
}

metrics_inc_role_violation :: proc(m: ^Metrics) {
	if m == nil {
		return
	}
	metrics_inc(&m.role_violations_total)
	metrics_inc(&m.protocol_errors_total)
}

metrics_add_bytes :: proc(m: ^Metrics, from: StreamPeer, n: int) {
	if m == nil || n <= 0 {
		return
	}
	switch from {
	case .Agent:
		metrics_inc(&m.bytes_agent_to_caller_total, u64(n))
	case .Caller:
		metrics_inc(&m.bytes_caller_to_agent_total, u64(n))
	}
}

metrics_observe :: proc(m: ^Metrics, kind: LatencyKind, d: time.Duration) {
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

metrics_snapshot_counters :: proc(m: ^Metrics) -> MetricsSnapshot {
	snap: MetricsSnapshot
	if m == nil {
		return snap
	}
	snap.active_caller_connections = int(sync.atomic_load(&m.active_caller_connections))
	snap.registrations_total = sync.atomic_load(&m.registrations_total)
	snap.unregistrations_total = sync.atomic_load(&m.unregistrations_total)
	snap.connection_attempts_total = sync.atomic_load(&m.connection_attempts_total)
	snap.connection_success_total = sync.atomic_load(&m.connection_success_total)
	snap.bytes_agent_to_caller_total = sync.atomic_load(&m.bytes_agent_to_caller_total)
	snap.bytes_caller_to_agent_total = sync.atomic_load(&m.bytes_caller_to_agent_total)
	snap.protocol_errors_total = sync.atomic_load(&m.protocol_errors_total)
	snap.authentication_failures_total = sync.atomic_load(&m.authentication_failures_total)
	snap.role_violations_total = sync.atomic_load(&m.role_violations_total)
	snap.session_timeouts_total = sync.atomic_load(&m.session_timeouts_total)
	snap.agent_sessions_total = sync.atomic_load(&m.agent_sessions_total)
	for reason in ConnectFailureReason {
		snap.connection_failures[reason] = sync.atomic_load(&m.connection_failures[reason])
	}
	for reason in AuthzReason {
		snap.authorization_failures[reason] = sync.atomic_load(&m.authorization_failures[reason])
	}
	for reason in RegisterFailureReason {
		snap.registration_failures[reason] = sync.atomic_load(&m.registration_failures[reason])
	}
	for reason in UnregisterFailureReason {
		snap.unregistration_failures[reason] = sync.atomic_load(&m.unregistration_failures[reason])
	}
	for kind in RateLimitKind {
		snap.rate_limit_exceeds[kind] = sync.atomic_load(&m.rate_limit_exceeds[kind])
	}
	for reason in ResetReason {
		snap.resets[reason] = sync.atomic_load(&m.resets[reason])
	}
	for kind in LimitKind {
		snap.limit_exceeds[kind] = sync.atomic_load(&m.limit_exceeds[kind])
	}
	for kind in LatencyKind {
		snap.latency[kind] = metrics_copy_histogram(&m.latency[kind])
	}
	return snap
}

metrics_snapshot :: proc(server: ^Server) -> MetricsSnapshot {
	snap := metrics_snapshot_counters(&server.metrics)
	if server == nil {
		return snap
	}
	snap.active_physical_connections = int(sync.atomic_load(&server.active_conns))
	if server.registry != nil {
		snap.registered_services, snap.active_agent_sessions, snap.active_organizations =
			registry_metrics(server.registry)
	}
	snap.active_relay_streams = relay_stream_count(server)
	return snap
}

metrics_write_prometheus :: proc(snap: MetricsSnapshot, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_gauge(&b, "active_physical_connections", "Active physical connections", snap.active_physical_connections)
	write_gauge(&b, "active_agent_sessions", "Active authenticated agent sessions", snap.active_agent_sessions)
	write_gauge(&b, "active_caller_connections", "Active authenticated caller connections", snap.active_caller_connections)
	write_gauge(&b, "registered_services", "Currently registered services", snap.registered_services)
	write_gauge(&b, "active_relay_streams", "Active relay streams", snap.active_relay_streams)
	write_gauge(&b, "active_organizations", "Distinct organizations with a live session", snap.active_organizations)
	write_counter(&b, "registrations_total", "Successful service registrations", snap.registrations_total)
	write_counter(&b, "unregistrations_total", "Successful service unregistrations", snap.unregistrations_total)
	write_counter(&b, "connection_attempts_total", "CONNECT attempts", snap.connection_attempts_total)
	write_counter(&b, "connection_success_total", "CONNECT_OK completions", snap.connection_success_total)
	write_counter(&b, "bytes_agent_to_caller_total", "DATA bytes agent to caller", snap.bytes_agent_to_caller_total)
	write_counter(&b, "bytes_caller_to_agent_total", "DATA bytes caller to agent", snap.bytes_caller_to_agent_total)
	write_counter(&b, "protocol_errors_total", "Protocol errors", snap.protocol_errors_total)
	write_counter(&b, "authentication_failures_total", "Authentication failures", snap.authentication_failures_total)
	write_counter(&b, "role_violations_total", "Role-invalid opcode rejections", snap.role_violations_total)
	write_counter(&b, "session_timeouts_total", "Sessions closed for idle timeout", snap.session_timeouts_total)
	write_counter(&b, "agent_sessions_total", "Agent sessions created", snap.agent_sessions_total)
	write_labeled_connect_failure(&b, snap.connection_failures)
	write_labeled_authz(&b, snap.authorization_failures)
	write_labeled_register_failure(&b, snap.registration_failures)
	write_labeled_unregister_failure(&b, snap.unregistration_failures)
	write_labeled_rate_limit(&b, snap.rate_limit_exceeds)
	write_labeled_counter(&b, "resets_total", "Stream RESET frames originated by the broker", "reason", reset_reason_label, snap.resets)
	write_labeled_limit(&b, snap.limit_exceeds)
	write_histogram(&b, .Authentication, "Authentication duration in seconds", snap.latency[.Authentication])
	write_histogram(&b, .ServiceLookup, "Service lookup duration in seconds", snap.latency[.ServiceLookup])
	write_histogram(&b, .OpenOk, "OPEN to OPEN_OK duration in seconds", snap.latency[.OpenOk])
	write_histogram(&b, .ConnectOk, "CONNECT to CONNECT_OK duration in seconds", snap.latency[.ConnectOk])
	return strings.to_string(b)
}

write_gauge :: proc(b: ^strings.Builder, name: string, help: string, value: int) {
	fmt.sbprintf(b, "# HELP thirp_%s %s\n", name, help)
	fmt.sbprintf(b, "# TYPE thirp_%s gauge\n", name)
	fmt.sbprintf(b, "thirp_%s %d\n", name, value)
}

write_counter :: proc(b: ^strings.Builder, name: string, help: string, value: u64) {
	fmt.sbprintf(b, "# HELP thirp_%s %s\n", name, help)
	fmt.sbprintf(b, "# TYPE thirp_%s counter\n", name)
	fmt.sbprintf(b, "thirp_%s %d\n", name, value)
}

write_labeled_counter :: proc(
	b: ^strings.Builder,
	name: string,
	help: string,
	label: string,
	label_of: proc(ResetReason) -> string,
	values: [ResetReason]u64,
) {
	fmt.sbprintf(b, "# HELP thirp_%s %s\n", name, help)
	fmt.sbprintf(b, "# TYPE thirp_%s counter\n", name)
	for reason in ResetReason {
		fmt.sbprintf(b, "thirp_%s{{%s=\"%s\"}} %d\n", name, label, label_of(reason), values[reason])
	}
}

write_labeled_limit :: proc(b: ^strings.Builder, values: [LimitKind]u64) {
	fmt.sbprintf(b, "# HELP thirp_limit_exceeds_total Limit exceed events\n")
	fmt.sbprintf(b, "# TYPE thirp_limit_exceeds_total counter\n")
	for kind in LimitKind {
		fmt.sbprintf(b, "thirp_limit_exceeds_total{{limit=\"%s\"}} %d\n", limit_kind_label(kind), values[kind])
	}
}

write_labeled_connect_failure :: proc(b: ^strings.Builder, values: [ConnectFailureReason]u64) {
	fmt.sbprintf(b, "# HELP thirp_connection_failure_total CONNECT_FAILED completions by reason\n")
	fmt.sbprintf(b, "# TYPE thirp_connection_failure_total counter\n")
	for reason in ConnectFailureReason {
		fmt.sbprintf(
			b,
			"thirp_connection_failure_total{{reason=\"%s\"}} %d\n",
			connect_failure_reason_label(reason),
			values[reason],
		)
	}
}

write_labeled_authz :: proc(b: ^strings.Builder, values: [AuthzReason]u64) {
	fmt.sbprintf(b, "# HELP thirp_authorization_failures_total Authorization denials by reason\n")
	fmt.sbprintf(b, "# TYPE thirp_authorization_failures_total counter\n")
	for reason in AuthzReason {
		fmt.sbprintf(
			b,
			"thirp_authorization_failures_total{{reason=\"%s\"}} %d\n",
			authz_reason_label(reason),
			values[reason],
		)
	}
}

write_labeled_register_failure :: proc(b: ^strings.Builder, values: [RegisterFailureReason]u64) {
	fmt.sbprintf(b, "# HELP thirp_registration_failures_total REGISTER failures by reason\n")
	fmt.sbprintf(b, "# TYPE thirp_registration_failures_total counter\n")
	for reason in RegisterFailureReason {
		fmt.sbprintf(
			b,
			"thirp_registration_failures_total{{reason=\"%s\"}} %d\n",
			register_failure_reason_label(reason),
			values[reason],
		)
	}
}

write_labeled_unregister_failure :: proc(b: ^strings.Builder, values: [UnregisterFailureReason]u64) {
	fmt.sbprintf(b, "# HELP thirp_unregistration_failures_total UNREGISTER failures by reason\n")
	fmt.sbprintf(b, "# TYPE thirp_unregistration_failures_total counter\n")
	for reason in UnregisterFailureReason {
		fmt.sbprintf(
			b,
			"thirp_unregistration_failures_total{{reason=\"%s\"}} %d\n",
			unregister_failure_reason_label(reason),
			values[reason],
		)
	}
}

write_labeled_rate_limit :: proc(b: ^strings.Builder, values: [RateLimitKind]u64) {
	fmt.sbprintf(b, "# HELP thirp_rate_limit_exceeds_total Rate-limit rejections by limiter\n")
	fmt.sbprintf(b, "# TYPE thirp_rate_limit_exceeds_total counter\n")
	for kind in RateLimitKind {
		fmt.sbprintf(
			b,
			"thirp_rate_limit_exceeds_total{{limit=\"%s\"}} %d\n",
			rate_limit_kind_label(kind),
			values[kind],
		)
	}
}

write_histogram :: proc(b: ^strings.Builder, kind: LatencyKind, help: string, h: LatencyHistogram) {
	name := latency_kind_name(kind)
	fmt.sbprintf(b, "# HELP thirp_%s_seconds %s\n", name, help)
	fmt.sbprintf(b, "# TYPE thirp_%s_seconds histogram\n", name)
	bounds := HISTOGRAM_FINITE_BOUNDS
	for i in 0 ..< len(bounds) {
		fmt.sbprintf(
			b,
			"thirp_%s_seconds_bucket{{le=\"%g\"}} %d\n",
			name,
			bounds[i],
			h.buckets[i],
		)
	}
	fmt.sbprintf(b, "thirp_%s_seconds_bucket{{le=\"+Inf\"}} %d\n", name, h.buckets[HISTOGRAM_BUCKET_COUNT - 1])
	sum := f64(h.sum_ns) / 1_000_000_000.0
	fmt.sbprintf(b, "thirp_%s_seconds_sum %g\n", name, sum)
	fmt.sbprintf(b, "thirp_%s_seconds_count %d\n", name, h.count)
}