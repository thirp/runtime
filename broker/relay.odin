package broker

import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:sync"
import "core:time"

RelayStream :: struct {
	id:                        proto.StreamId,
	service_id:                ServiceId,
	state:                     StreamState,
	agent_session:             SessionId,
	caller_session:            SessionId,
	agent_conn:                ^trans.Connection,
	caller_conn:               ^trans.Connection,
	opened_at:                 time.Time,
	last_activity:             time.Time,
	access_grant_id:           string,
	credential_id:             string,
	principal_id:              string,
	organization_id:           string,
	environment_id:            string,
	valid_until:               time.Time,
	authorization_lease_until: time.Time,
	policy_version:            i64,
	bytes_caller_to_agent:     u64,
	bytes_agent_to_caller:     u64,
}

GrantExpiry :: struct {
	id:     proto.StreamId,
	reason: ResetReason,
}

relay_init :: proc(server: ^Server) {
	server.agent_conns = make(map[SessionId]^trans.Connection, server.allocator)
	server.streams = make(map[proto.StreamId]RelayStream, server.allocator)
	server.session_stream_count = make(map[SessionId]int, server.allocator)
	server.next_stream_id = 1
}

relay_destroy :: proc(server: ^Server) {
	if server == nil {
		return
	}
	for _, stream in server.streams {
		relay_release_stream(server, stream)
	}
	clear(&server.streams)
	delete(server.streams)
	delete(server.agent_conns)
	delete(server.session_stream_count)
	server.streams = {}
	server.agent_conns = {}
	server.session_stream_count = {}
}

relay_release_stream :: proc(server: ^Server, stream: RelayStream) {
	trans.connection_release(stream.agent_conn)
	trans.connection_release(stream.caller_conn)
	if len(stream.service_id) > 0 {
		delete(string(stream.service_id), server.allocator)
	}
	relay_free_authz_strings(server, stream)
}

relay_free_authz_strings :: proc(server: ^Server, stream: RelayStream) {
	if server == nil {
		return
	}
	if len(stream.access_grant_id) > 0 {
		delete(stream.access_grant_id, server.allocator)
	}
	if len(stream.credential_id) > 0 {
		delete(stream.credential_id, server.allocator)
	}
	if len(stream.principal_id) > 0 {
		delete(stream.principal_id, server.allocator)
	}
	if len(stream.organization_id) > 0 {
		delete(stream.organization_id, server.allocator)
	}
	if len(stream.environment_id) > 0 {
		delete(stream.environment_id, server.allocator)
	}
}

relay_clone_string :: proc(s: string, allocator := context.allocator) -> (string, bool) {
	if len(s) == 0 {
		return "", true
	}
	cloned, err := strings.clone(s, allocator)
	if err != .None {
		return "", false
	}
	return cloned, true
}

relay_bind_agent :: proc(server: ^Server, session_id: SessionId, conn: ^trans.Connection) {
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	server.agent_conns[session_id] = conn
}

relay_unbind_agent :: proc(server: ^Server, session_id: SessionId) {
	if session_id == INVALID_SESSION_ID {
		return
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	delete_key(&server.agent_conns, session_id)
}

relay_adjust_session_stream_count_locked :: proc(server: ^Server, session_id: SessionId, delta: int) {
	if session_id == INVALID_SESSION_ID {
		return
	}
	next := server.session_stream_count[session_id] + delta
	if next <= 0 {
		delete_key(&server.session_stream_count, session_id)
		return
	}
	server.session_stream_count[session_id] = next
}

relay_stream_count :: proc(server: ^Server) -> int {
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	return len(server.streams)
}

relay_open_stream :: proc(
	server: ^Server,
	service_id: ServiceId,
	agent_session: SessionId,
	caller_conn: ^trans.Connection,
	authz: AuthzDecision = {},
	h: ^ConnHandler = nil,
) -> (
	stream_id: proto.StreamId,
	agent_conn: ^trans.Connection,
	err: RelayOpenError,
) {
	cloned, clone_err := strings.clone(string(service_id), server.allocator)
	if clone_err != .None {
		return proto.CONNECTION_STREAM_ID, nil, .OutOfMemory
	}
	grant_id, gok := relay_clone_string(authz.access_grant_id, server.allocator)
	cred_src := ""
	prin_src := ""
	if h != nil {
		cred_src = h.credential_id
		prin_src = h.principal_id
	}
	cred_id, cok := relay_clone_string(cred_src, server.allocator)
	prin_id, pok := relay_clone_string(prin_src, server.allocator)
	org_src := authz.organization_id
	if len(org_src) == 0 && h != nil {
		org_src = h.organization
	}
	env_src := authz.environment_id
	if len(env_src) == 0 && h != nil {
		env_src = h.environment_id
	}
	org_id, ook := relay_clone_string(org_src, server.allocator)
	env_id, eok := relay_clone_string(env_src, server.allocator)
	if !gok || !cok || !pok || !ook || !eok {
		delete(cloned, server.allocator)
		if gok && len(grant_id) > 0 {
			delete(grant_id, server.allocator)
		}
		if cok && len(cred_id) > 0 {
			delete(cred_id, server.allocator)
		}
		if pok && len(prin_id) > 0 {
			delete(prin_id, server.allocator)
		}
		if ook && len(org_id) > 0 {
			delete(org_id, server.allocator)
		}
		if eok && len(env_id) > 0 {
			delete(env_id, server.allocator)
		}
		return proto.CONNECTION_STREAM_ID, nil, .OutOfMemory
	}

	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)

	found_conn, found := server.agent_conns[agent_session]
	if !found || found_conn == nil {
		delete(cloned, server.allocator)
		relay_free_authz_strings(server, RelayStream {
			access_grant_id = grant_id,
			credential_id   = cred_id,
			principal_id    = prin_id,
			organization_id = org_id,
			environment_id  = env_id,
		})
		return proto.CONNECTION_STREAM_ID, nil, .AgentUnavailable
	}
	if server.max_streams_per_session > 0 &&
	   server.session_stream_count[agent_session] >= server.max_streams_per_session {
		delete(cloned, server.allocator)
		relay_free_authz_strings(server, RelayStream {
			access_grant_id = grant_id,
			credential_id   = cred_id,
			principal_id    = prin_id,
			organization_id = org_id,
			environment_id  = env_id,
		})
		return proto.CONNECTION_STREAM_ID, nil, .QuotaExceeded
	}
	if !trans.connection_acquire(found_conn) {
		delete(cloned, server.allocator)
		relay_free_authz_strings(server, RelayStream {
			access_grant_id = grant_id,
			credential_id   = cred_id,
			principal_id    = prin_id,
			organization_id = org_id,
			environment_id  = env_id,
		})
		return proto.CONNECTION_STREAM_ID, nil, .AgentUnavailable
	}
	if !trans.connection_acquire(caller_conn) {
		trans.connection_release(found_conn)
		delete(cloned, server.allocator)
		relay_free_authz_strings(server, RelayStream {
			access_grant_id = grant_id,
			credential_id   = cred_id,
			principal_id    = prin_id,
			organization_id = org_id,
			environment_id  = env_id,
		})
		return proto.CONNECTION_STREAM_ID, nil, .AgentUnavailable
	}
	if !trans.connection_acquire(found_conn) {
		trans.connection_release(found_conn)
		trans.connection_release(caller_conn)
		delete(cloned, server.allocator)
		relay_free_authz_strings(server, RelayStream {
			access_grant_id = grant_id,
			credential_id   = cred_id,
			principal_id    = prin_id,
			organization_id = org_id,
			environment_id  = env_id,
		})
		return proto.CONNECTION_STREAM_ID, nil, .AgentUnavailable
	}

	stream_id = proto.StreamId(server.next_stream_id)
	server.next_stream_id += 1
	now := time.now()
	caller_session: SessionId = INVALID_SESSION_ID
	if h != nil {
		caller_session = h.session_id
	}
	server.streams[stream_id] = RelayStream {
		id                        = stream_id,
		service_id                = ServiceId(cloned),
		state                     = .Opening,
		agent_session             = agent_session,
		caller_session            = caller_session,
		agent_conn                = found_conn,
		caller_conn               = caller_conn,
		opened_at                 = now,
		last_activity             = now,
		access_grant_id           = grant_id,
		credential_id             = cred_id,
		principal_id              = prin_id,
		organization_id           = org_id,
		environment_id            = env_id,
		valid_until               = authz.valid_until,
		authorization_lease_until = authz.authorization_lease_until,
		policy_version            = authz.policy_version,
	}
	relay_adjust_session_stream_count_locked(server, agent_session, 1)
	return stream_id, found_conn, .None
}

relay_drop_stream :: proc(server: ^Server, stream_id: proto.StreamId) {
	sync.mutex_lock(&server.routing_mutex)
	stream, found := server.streams[stream_id]
	if found {
		delete_key(&server.streams, stream_id)
		relay_adjust_session_stream_count_locked(server, stream.agent_session, -1)
	}
	sync.mutex_unlock(&server.routing_mutex)
	if found {
		relay_release_stream(server, stream)
	}
}

relay_lookup_stream :: proc(server: ^Server, stream_id: proto.StreamId) -> (RelayStream, bool) {
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	stream, found := server.streams[stream_id]
	return stream, found
}

relay_add_stream_bytes :: proc(server: ^Server, stream_id: proto.StreamId, from: StreamPeer, n: int) {
	if server == nil || n <= 0 {
		return
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	stream, found := server.streams[stream_id]
	if !found {
		return
	}
	switch from {
	case .Caller:
		stream.bytes_caller_to_agent += u64(n)
	case .Agent:
		stream.bytes_agent_to_caller += u64(n)
	}
	server.streams[stream_id] = stream
}

relay_apply :: proc(
	server: ^Server,
	stream_id: proto.StreamId,
	event: StreamEvent,
	from: StreamPeer,
) -> (
	RelayStream,
	StreamError,
) {
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	stream, found := server.streams[stream_id]
	if !found {
		return {}, .NotFound
	}
	next, aerr := apply_stream_event(stream.state, event, from)
	if aerr != .None {
		return stream, aerr
	}
	stream.state = next
	#partial switch event {
	case .OpenOk, .Data, .HalfClose:
		stream.last_activity = time.now()
	}
	server.streams[stream_id] = stream
	return stream, .None
}

relay_acquire_peer :: proc(
	server: ^Server,
	stream_id: proto.StreamId,
	dest: StreamPeer,
) -> (
	conn: ^trans.Connection,
	stream: RelayStream,
	ok: bool,
) {
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	got, found := server.streams[stream_id]
	if !found {
		return nil, {}, false
	}
	peer := dest == .Agent ? got.agent_conn : got.caller_conn
	if !trans.connection_acquire(peer) {
		return nil, {}, false
	}
	return peer, got, true
}

relay_take_streams_for_conn :: proc(
	server: ^Server,
	conn: ^trans.Connection,
	session_id: SessionId,
	allocator := context.allocator,
) -> [dynamic]RelayStream {
	taken := make([dynamic]RelayStream, allocator)
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	if session_id != INVALID_SESSION_ID {
		delete_key(&server.agent_conns, session_id)
	}
	ids: [dynamic]proto.StreamId
	defer delete(ids)
	for id, stream in server.streams {
		if stream.caller_conn == conn || stream.agent_conn == conn {
			append(&ids, id)
		}
	}
	for id in ids {
		stream, found := server.streams[id]
		if found {
			delete_key(&server.streams, id)
			relay_adjust_session_stream_count_locked(server, stream.agent_session, -1)
			append(&taken, stream)
		}
	}
	return taken
}

relay_take_all_streams :: proc(server: ^Server, allocator := context.allocator) -> [dynamic]RelayStream {
	taken := make([dynamic]RelayStream, allocator)
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	ids: [dynamic]proto.StreamId
	defer delete(ids)
	for id in server.streams {
		append(&ids, id)
	}
	for id in ids {
		stream, found := server.streams[id]
		if found {
			delete_key(&server.streams, id)
			relay_adjust_session_stream_count_locked(server, stream.agent_session, -1)
			append(&taken, stream)
		}
	}
	return taken
}

relay_write :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId,
	allocator := context.allocator,
) -> bool {
	if conn == nil {
		return false
	}
	terr, perr := trans.write_frame(conn, opcode, payload, stream_id, allocator)
	return terr == .None && perr == .None
}

relay_write_failure :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	code: proto.WireError,
	stream_id: proto.StreamId,
	allocator := context.allocator,
) -> bool {
	payload, perr := proto.encode_wire_failure(
		proto.WireFailure {
			code       = proto.wire_error_to_u16(code),
			diagnostic = wire_error_diagnostic(code),
		},
		allocator,
	)
	if perr != .None {
		return false
	}
	defer delete(payload, allocator)
	return relay_write(conn, opcode, payload, stream_id, allocator)
}

relay_idle_stream_ids :: proc(
	server: ^Server,
	conn: ^trans.Connection,
	timeout: time.Duration,
	allocator := context.allocator,
) -> [dynamic]proto.StreamId {
	ids := make([dynamic]proto.StreamId, allocator)
	if server == nil || conn == nil || timeout <= 0 {
		return ids
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	now := time.now()
	for id, stream in server.streams {
		if stream.caller_conn != conn && stream.agent_conn != conn {
			continue
		}
		if time.diff(stream.last_activity, now) >= timeout {
			append(&ids, id)
		}
	}
	return ids
}

relay_until_next_stream_idle :: proc(server: ^Server, conn: ^trans.Connection) -> time.Duration {
	if server == nil || conn == nil || server.stream_idle_timeout <= 0 {
		return time.Hour
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	soonest := time.Duration(-1)
	now := time.now()
	for _, stream in server.streams {
		if stream.caller_conn != conn && stream.agent_conn != conn {
			continue
		}
		age := time.diff(stream.last_activity, now)
		remaining := server.stream_idle_timeout - age
		if remaining < 0 {
			remaining = 0
		}
		if soonest < 0 || remaining < soonest {
			soonest = remaining
		}
	}
	if soonest < 0 {
		return time.Hour
	}
	return soonest
}

stream_grant_expiry_reason :: proc(stream: RelayStream, now: time.Time) -> (ResetReason, bool) {
	if authz_time_is_set(stream.valid_until) && now._nsec >= stream.valid_until._nsec {
		return .GrantExpired, true
	}
	if authz_time_is_set(stream.authorization_lease_until) &&
	   now._nsec >= stream.authorization_lease_until._nsec {
		return .LeaseExpired, true
	}
	return {}, false
}

stream_grant_deadline :: proc(stream: RelayStream) -> (time.Time, bool) {
	until := time.Time{}
	set := false
	if authz_time_is_set(stream.valid_until) {
		until = stream.valid_until
		set = true
	}
	if authz_time_is_set(stream.authorization_lease_until) {
		if !set || stream.authorization_lease_until._nsec < until._nsec {
			until = stream.authorization_lease_until
			set = true
		}
	}
	return until, set
}

relay_expired_grant_streams :: proc(
	server: ^Server,
	conn: ^trans.Connection,
	allocator := context.allocator,
) -> [dynamic]GrantExpiry {
	out := make([dynamic]GrantExpiry, allocator)
	if server == nil || conn == nil {
		return out
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	now := time.now()
	for id, stream in server.streams {
		if stream.caller_conn != conn && stream.agent_conn != conn {
			continue
		}
		reason, expired := stream_grant_expiry_reason(stream, now)
		if expired {
			append(&out, GrantExpiry{id = id, reason = reason})
		}
	}
	return out
}

relay_until_next_grant_expiry :: proc(server: ^Server, conn: ^trans.Connection) -> time.Duration {
	if server == nil || conn == nil {
		return time.Hour
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	soonest := time.Duration(-1)
	now := time.now()
	for _, stream in server.streams {
		if stream.caller_conn != conn && stream.agent_conn != conn {
			continue
		}
		deadline, set := stream_grant_deadline(stream)
		if !set {
			continue
		}
		remaining := time.Duration(deadline._nsec - now._nsec)
		if remaining < 0 {
			remaining = 0
		}
		if soonest < 0 || remaining < soonest {
			soonest = remaining
		}
	}
	if soonest < 0 {
		return time.Hour
	}
	return soonest
}

relay_take_streams_for_grant :: proc(
	server: ^Server,
	grant_id: string,
	allocator := context.allocator,
) -> [dynamic]RelayStream {
	taken := make([dynamic]RelayStream, allocator)
	if server == nil || len(grant_id) == 0 {
		return taken
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	ids: [dynamic]proto.StreamId
	defer delete(ids)
	for id, stream in server.streams {
		if len(stream.access_grant_id) == 0 {
			continue
		}
		if stream.access_grant_id == grant_id {
			append(&ids, id)
		}
	}
	for id in ids {
		stream, found := server.streams[id]
		if found {
			delete_key(&server.streams, id)
			relay_adjust_session_stream_count_locked(server, stream.agent_session, -1)
			append(&taken, stream)
		}
	}
	return taken
}

relay_set_grant_lease :: proc(server: ^Server, grant_id: string, until: time.Time) {
	if server == nil || len(grant_id) == 0 {
		return
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	for id, &stream in server.streams {
		if stream.access_grant_id == grant_id {
			stream.authorization_lease_until = until
			server.streams[id] = stream
		}
	}
}

relay_copy_stream_grant_ids :: proc(
	server: ^Server,
	allocator := context.allocator,
) -> [dynamic]string {
	ids := make([dynamic]string, allocator)
	if server == nil {
		return ids
	}
	sync.mutex_lock(&server.routing_mutex)
	defer sync.mutex_unlock(&server.routing_mutex)
	for _, stream in server.streams {
		if len(stream.access_grant_id) == 0 {
			continue
		}
		seen := false
		for existing in ids {
			if existing == stream.access_grant_id {
				seen = true
				break
			}
		}
		if seen {
			continue
		}
		cloned, err := strings.clone(stream.access_grant_id, allocator)
		if err == .None {
			append(&ids, cloned)
		}
	}
	return ids
}
