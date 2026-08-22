package broker

import auth "../auth"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_HEARTBEAT_INTERVAL :: 15 * time.Second
DEFAULT_SESSION_TIMEOUT :: 45 * time.Second
DEFAULT_SHUTDOWN_GRACE :: 10 * time.Second
ACCEPT_POLL_INTERVAL :: 50 * time.Millisecond
BROKER_IMPLEMENTATION :: "thirp-broker"

Server :: struct {
	allocator:                 mem.Allocator,
	registry:                  ^Registry,
	auth:                      auth.Authenticator,
	authorizer:                Authorizer,
	may_register:              MayRegisterProc,
	may_connect:               MayConnectProc,
	policy_mode:               PolicyMode,
	policy:                    StaticPolicy,
	registration_observer_ctx: rawptr,
	registration_observer:     RegistrationObserverProc,
	connection_observer_ctx:   rawptr,
	connection_observer:       ConnectionObserverProc,
	handlers_mutex:            sync.Mutex,
	handlers:                  map[^ConnHandler]struct{},
	heartbeat_interval:        time.Duration,
	session_timeout:           time.Duration,
	listener:                  trans.Listener,
	listening:                 bool,
	stop:                      bool,
	active_conns:              int,
	serve_thread:              ^thread.Thread,
	routing_mutex:             sync.Mutex,
	agent_conns:               map[SessionId]^trans.Connection,
	streams:                   map[proto.StreamId]RelayStream,
	next_stream_id:            u64,
	session_stream_count:      map[SessionId]int,
	max_stream_buffer:         int,
	max_connection_buffer:     int,
	max_streams_per_session:   int,
	max_frame_payload:         u32,
	max_physical_connections:  int,
	max_connections_per_ip:    int,
	max_buffered_bytes:        int,
	buffered_bytes:            i64,
	auth_rate:                 RateLimitConfig,
	register_rate:             RateLimitConfig,
	connect_rate:              RateLimitConfig,
	stream_idle_timeout:       time.Duration,
	rate_limits:               RateLimiters,
	limits_mutex:              sync.Mutex,
	ip_conns:                  map[IpKey]int,
	outbox_mutex:              sync.Mutex,
	outboxes:                  map[^trans.Connection]^ConnOutbox,
	tls_ctx:                   ^trans.TlsServerContext,
	metrics:                   Metrics,
	logger:                    ^log.Logger,
	draining:                  bool,
	shutdown_grace:            time.Duration,
	metrics_listener:          trans.Listener,
	metrics_listening:         bool,
	metrics_stop:              bool,
	metrics_thread:            ^thread.Thread,
}

server_init :: proc(
	server: ^Server,
	registry: ^Registry,
	authenticator: auth.Authenticator,
	allocator := context.allocator,
) {
	server^ = {}
	server.allocator = allocator
	server.registry = registry
	server.auth = authenticator
	server.may_register = may_register_allow_all
	server.may_connect = may_connect_allow_all
	server.policy_mode = .Development
	_ = policy_init(&server.policy, allocator)
	server.heartbeat_interval = DEFAULT_HEARTBEAT_INTERVAL
	server.session_timeout = DEFAULT_SESSION_TIMEOUT
	server.max_stream_buffer = DEFAULT_MAX_STREAM_BUFFER
	server.max_connection_buffer = DEFAULT_MAX_CONNECTION_BUFFER
	server.max_streams_per_session = DEFAULT_MAX_STREAMS_PER_SESSION
	server.max_frame_payload = proto.MAX_FRAME_PAYLOAD
	server.max_physical_connections = DEFAULT_MAX_PHYSICAL_CONNECTIONS
	server.max_connections_per_ip = DEFAULT_MAX_CONNECTIONS_PER_IP
	server.max_buffered_bytes = DEFAULT_MAX_BUFFERED_BYTES
	server.auth_rate = rate_limit_config(DEFAULT_AUTH_RATE_LIMIT, DEFAULT_RATE_LIMIT_WINDOW)
	server.register_rate = rate_limit_config(DEFAULT_REGISTER_RATE_LIMIT, DEFAULT_RATE_LIMIT_WINDOW)
	server.connect_rate = rate_limit_config(DEFAULT_CONNECT_RATE_LIMIT, DEFAULT_RATE_LIMIT_WINDOW)
	server.stream_idle_timeout = time.Duration(DEFAULT_STREAM_IDLE_TIMEOUT) * time.Second
	server.shutdown_grace = DEFAULT_SHUTDOWN_GRACE
	server.ip_conns = make(map[IpKey]int, allocator)
	server.outboxes = make(map[^trans.Connection]^ConnOutbox, allocator)
	server.handlers = make(map[^ConnHandler]struct{}, allocator)
	rate_limiters_init(&server.rate_limits, allocator)
	relay_init(server)
}

server_listen :: proc(server: ^Server, endpoint: net.Endpoint) -> trans.TransportError {
	ln, err := trans.listener_listen(endpoint)
	if err != .None {
		return err
	}
	server.listener = ln
	server.listening = true
	server.stop = false
	_ = trans.listener_set_recv_timeout(&server.listener, ACCEPT_POLL_INTERVAL)
	return .None
}

server_endpoint :: proc(server: ^Server) -> (net.Endpoint, trans.TransportError) {
	return trans.listener_endpoint(server.listener)
}

server_start :: proc(server: ^Server) {
	server.serve_thread = thread.create_and_start_with_poly_data(server, server_serve)
}

server_serve :: proc(server: ^Server) {
	context.allocator = server.allocator
	for {
		if server.stop {
			return
		}
		conn, err := trans.listener_accept(&server.listener, server.allocator)
		if err == .Timeout {
			continue
		}
		if server_accept_error_is_fatal(server, err) {
			return
		}
		if err != .None {
			metrics_inc_limit(&server.metrics, .FileDescriptors)
			server_log(server, .Warn, LOG_EVENT_ACCEPT_FAILED, log.LogFields{reason = limit_kind_label(.FileDescriptors)})
			time.sleep(ACCEPT_POLL_INTERVAL)
			continue
		}
		if server.stop {
			trans.connection_destroy(conn, server.allocator)
			return
		}
		if server_global_buffer_at_ceiling(server) {
			metrics_inc_limit(&server.metrics, .GlobalBuffer)
			server_log(server, .Warn, LOG_EVENT_LIMIT_EXCEEDED, log.LogFields{reason = limit_kind_label(.GlobalBuffer)})
			trans.connection_destroy(conn, server.allocator)
			continue
		}
		slot := server_acquire_connection_slot(server, conn)
		if slot != .Ok {
			kind: LimitKind = .ConnectionsPerIp
			if slot == .PhysicalConnections {
				kind = .PhysicalConnections
			} else if slot == .GlobalBuffer {
				kind = .GlobalBuffer
			}
			metrics_inc_limit(&server.metrics, kind)
			server_log(server, .Warn, LOG_EVENT_LIMIT_EXCEEDED, log.LogFields{reason = limit_kind_label(kind)})
			trans.connection_destroy(conn, server.allocator)
			continue
		}
		handler, aerr := new(ConnHandler, server.allocator)
		if aerr != .None {
			metrics_inc_limit(&server.metrics, .FileDescriptors)
			server_log(server, .Warn, LOG_EVENT_ACCEPT_FAILED, log.LogFields{reason = limit_kind_label(.FileDescriptors)})
			server_release_connection_slot(server, ip_key_from_endpoint(conn.remote))
			trans.connection_destroy(conn, server.allocator)
			continue
		}
		handler.server = server
		handler.conn = conn
		thread.run_with_poly_data(handler, conn_thread_proc)
	}
}

server_stop :: proc(server: ^Server) {
	server.stop = true
	if server.listening {
		trans.listener_close(&server.listener)
		server.listening = false
	}
	if server.serve_thread != nil {
		thread.join(server.serve_thread)
		thread.destroy(server.serve_thread)
		server.serve_thread = nil
	}
	server_shutdown_handlers(server)
	server_metrics_stop(server)
}

server_destroy :: proc(server: ^Server) {
	if server == nil {
		return
	}
	server_metrics_stop(server)
	relay_destroy(server)
	if server.tls_ctx != nil {
		trans.tls_server_context_destroy(server.tls_ctx)
		server.tls_ctx = nil
	}
	rate_limiters_destroy(&server.rate_limits)
	delete(server.outboxes)
	delete(server.ip_conns)
	delete(server.handlers)
	server.outboxes = {}
	server.ip_conns = {}
	server.handlers = {}
	policy_destroy(&server.policy)
}

server_register_handler :: proc(server: ^Server, h: ^ConnHandler) {
	if server == nil || h == nil {
		return
	}
	sync.mutex_lock(&server.handlers_mutex)
	defer sync.mutex_unlock(&server.handlers_mutex)
	server.handlers[h] = {}
}

server_unregister_handler :: proc(server: ^Server, h: ^ConnHandler) {
	if server == nil || h == nil {
		return
	}
	sync.mutex_lock(&server.handlers_mutex)
	defer sync.mutex_unlock(&server.handlers_mutex)
	delete_key(&server.handlers, h)
}

server_emit_registration :: proc(server: ^Server, ev: RegistrationEvent) {
	if server == nil || server.registration_observer == nil {
		return
	}
	server.registration_observer(server.registration_observer_ctx, ev)
}

server_emit_connection :: proc(server: ^Server, ev: ConnectionEvent) {
	if server == nil || server.connection_observer == nil {
		return
	}
	server.connection_observer(server.connection_observer_ctx, ev)
}

connection_event_from_stream :: proc(
	kind: ConnectionEventKind,
	stream: RelayStream,
	reason := "",
) -> ConnectionEvent {
	return ConnectionEvent {
		kind                  = kind,
		stream_id             = stream.id,
		service_id            = stream.service_id,
		grant_id              = stream.access_grant_id,
		credential_id         = stream.credential_id,
		principal_id          = stream.principal_id,
		organization_id       = stream.organization_id,
		environment_id        = stream.environment_id,
		session_id            = stream.caller_session,
		termination_reason    = reason,
		bytes_caller_to_agent = stream.bytes_caller_to_agent,
		bytes_agent_to_caller = stream.bytes_agent_to_caller,
	}
}

// Close Agent (or Caller) sessions whose AUTH result carried credential_id.
// Wakes the owner thread via SHUT_RDWR; the owner still runs connection_destroy.
server_disconnect_credential :: proc(server: ^Server, credential_id: string) {
	if server == nil || len(credential_id) == 0 {
		return
	}
	server_shutdown_handlers_matching(server, credential_id)
}

server_reset_grant :: proc(server: ^Server, grant_id: string) {
	if server == nil || len(grant_id) == 0 {
		return
	}
	taken := relay_take_streams_for_grant(server, grant_id, server.allocator)
	defer delete(taken)
	for stream in taken {
		metrics_inc_reset(&server.metrics, .GrantRevoked)
		server_log(
			server,
			.Info,
			LOG_EVENT_STREAM_RESET,
			log.LogFields {
				stream_id  = u64(stream.id),
				service_id = string(stream.service_id),
				error_code = wire_error_name(.Unauthorized),
				reason     = reset_reason_label(.GrantRevoked),
			},
		)
		server_reset_taken_stream(server, stream, .Unauthorized)
		server_emit_connection(server, connection_event_from_stream(.Reset, stream, LABEL_GRANT_REVOKED))
		relay_release_stream(server, stream)
	}
}

server_set_grant_lease :: proc(server: ^Server, grant_id: string, until: time.Time) {
	relay_set_grant_lease(server, grant_id, until)
}

server_copy_stream_grant_ids :: proc(
	server: ^Server,
	allocator := context.allocator,
) -> [dynamic]string {
	return relay_copy_stream_grant_ids(server, allocator)
}

server_reset_taken_stream :: proc(server: ^Server, stream: RelayStream, code: proto.WireError) {
	if server == nil {
		return
	}
	server_drop_stream_queues(server, stream)
	if stream.state == .Opening {
		if trans.connection_acquire(stream.caller_conn) {
			_ = server_enqueue_failure(
				server,
				stream.caller_conn,
				.ConnectFailed,
				code,
				proto.CONNECTION_STREAM_ID,
			)
			trans.connection_release(stream.caller_conn)
		}
		if trans.connection_acquire(stream.agent_conn) {
			_ = server_enqueue_failure(server, stream.agent_conn, .Reset, code, stream.id)
			trans.connection_release(stream.agent_conn)
		}
		return
	}
	if caller := server_lookup_outbox(server, stream.caller_conn); caller != nil {
		outbox_drop_stream(caller, stream.id)
		_ = outbox_enqueue_failure(caller, .Reset, code, stream.id)
		outbox_release(caller)
	}
	if agent := server_lookup_outbox(server, stream.agent_conn); agent != nil {
		outbox_drop_stream(agent, stream.id)
		_ = outbox_enqueue_failure(agent, .Reset, code, stream.id)
		outbox_release(agent)
	}
}

server_shutdown_handlers :: proc(server: ^Server) {
	if server == nil {
		return
	}
	server_shutdown_handlers_matching(server, "")
}

server_shutdown_handlers_matching :: proc(server: ^Server, credential_id: string) {
	conns := make([dynamic]^trans.Connection, server.allocator)
	sync.mutex_lock(&server.handlers_mutex)
	for h in server.handlers {
		if h == nil || h.conn == nil {
			continue
		}
		if len(credential_id) > 0 && h.credential_id != credential_id {
			continue
		}
		if trans.connection_acquire(h.conn) {
			append(&conns, h.conn)
		}
	}
	sync.mutex_unlock(&server.handlers_mutex)
	for conn in conns {
		trans.connection_shutdown_both(conn)
		trans.connection_release(conn)
	}
	delete(conns)
}

server_accept_error_is_fatal :: proc(server: ^Server, err: trans.TransportError) -> bool {
	if server == nil || server.stop {
		return true
	}
	return err == .Closed
}

server_wait_idle :: proc(server: ^Server, timeout: time.Duration) -> bool {
	start := time.now()
	for time.since(start) < timeout {
		if sync.atomic_load(&server.active_conns) == 0 {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return sync.atomic_load(&server.active_conns) == 0
}

IpKey :: struct {
	kind:  u8,
	bytes: [16]u8,
}

ip_key_from_endpoint :: proc(ep: net.Endpoint) -> IpKey {
	key: IpKey
	switch addr in ep.address {
	case net.IP4_Address:
		key.kind = 4
		key.bytes[0] = addr[0]
		key.bytes[1] = addr[1]
		key.bytes[2] = addr[2]
		key.bytes[3] = addr[3]
	case net.IP6_Address:
		key.kind = 6
		key.bytes = transmute([16]u8)addr
	}
	return key
}

server_acquire_connection_slot :: proc(server: ^Server, conn: ^trans.Connection) -> ConnectionSlotResult {
	key := ip_key_from_endpoint(conn.remote)
	sync.mutex_lock(&server.limits_mutex)
	defer sync.mutex_unlock(&server.limits_mutex)
	if server.max_physical_connections > 0 &&
	   sync.atomic_load(&server.active_conns) >= server.max_physical_connections {
		return .PhysicalConnections
	}
	count := server.ip_conns[key]
	if server.max_connections_per_ip > 0 && count >= server.max_connections_per_ip {
		return .ConnectionsPerIp
	}
	server.ip_conns[key] = count + 1
	sync.atomic_add(&server.active_conns, 1)
	return .Ok
}

server_release_connection_slot :: proc(server: ^Server, key: IpKey) {
	sync.mutex_lock(&server.limits_mutex)
	defer sync.mutex_unlock(&server.limits_mutex)
	count := server.ip_conns[key]
	if count <= 1 {
		delete_key(&server.ip_conns, key)
	} else {
		server.ip_conns[key] = count - 1
	}
	if sync.atomic_load(&server.active_conns) > 0 {
		sync.atomic_sub(&server.active_conns, 1)
	}
}
