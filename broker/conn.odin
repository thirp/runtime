package broker

import auth "../auth"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:crypto"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

ConnState :: enum {
	ExpectHello,
	ExpectAuthenticate,
	Authenticated,
}

ConnCloseReason :: enum {
	None,
	IdleTimeout,
	Protocol,
	Peer,
}

ConnHandler :: struct {
	server:          ^Server,
	conn:            ^trans.Connection,
	outbox:          ^ConnOutbox,
	decoder:         proto.FrameDecoder,
	state:           ConnState,
	role:            proto.PeerRole,
	session_id:      SessionId,
	principal_id:       string,
	organization:       string,
	credential_label:   string,
	credential_id:      string,
	environment_id:     string,
	principal_kind:     string,
	auth_policy_version: i64,
	capabilities:       PrincipalCapabilities,
	last_recv:       time.Time,
	last_ping_sent:  time.Time,
	caller_counted:  bool,
	close_reason:    ConnCloseReason,
}

conn_start_outbox :: proc(h: ^ConnHandler) -> bool {
	box, aerr := new(ConnOutbox, h.server.allocator)
	if aerr != .None {
		return false
	}
	outbox_init(box, h.conn, h.server, h.server.allocator)
	server_register_outbox(h.server, h.conn, box)
	outbox_start_writer(box)
	if box.writer == nil {
		server_unregister_outbox(h.server, h.conn)
		outbox_close(box)
		outbox_release(box)
		return false
	}
	h.outbox = box
	return true
}

conn_stop_outbox :: proc(h: ^ConnHandler) {
	if h.outbox == nil {
		return
	}
	server_unregister_outbox(h.server, h.conn)
	outbox_stop(h.outbox)
	outbox_release(h.outbox)
	h.outbox = nil
}

conn_thread_proc :: proc(h: ^ConnHandler) {
	context.allocator = h.server.allocator
	ip := ip_key_from_endpoint(h.conn.remote)
	defer {
		conn_stop_outbox(h)
		conn_cleanup(h)
		server_release_connection_slot(h.server, ip)
		free(h, h.server.allocator)
	}
	if h.server.tls_ctx != nil {
		if trans.connection_tls_accept(h.conn, h.server.tls_ctx) != .None {
			return
		}
	}
	if !conn_start_outbox(h) {
		return
	}
	conn_run(h)
}

conn_cleanup :: proc(h: ^ConnHandler) {
	server_unregister_handler(h.server, h)
	conn_emit_session_unregistered(h)
	taken := relay_take_streams_for_conn(h.server, h.conn, h.session_id, h.server.allocator)
	defer delete(taken)
	for stream in taken {
		from: StreamPeer = stream.caller_conn == h.conn ? .Caller : .Agent
		dest_peer := stream_peer_opposite(from)
		dest := dest_peer == .Agent ? stream.agent_conn : stream.caller_conn
		server_drop_stream_queues(h.server, stream)
		if trans.connection_acquire(dest) {
			if stream.state == .Opening && dest_peer == .Caller {
				metrics_inc_connect_failure(&h.server.metrics, .AgentUnavailable)
				_ = relay_write_failure(
					dest,
					.ConnectFailed,
					.AgentUnavailable,
					proto.CONNECTION_STREAM_ID,
					h.server.allocator,
				)
			} else {
				code: proto.WireError = from == .Agent ? .AgentUnavailable : .InternalError
				reason: ResetReason
				if h.close_reason == .IdleTimeout {
					reason = .IdleTimeout
				} else if from == .Agent {
					reason = .AgentGone
				} else {
					reason = .CallerGone
				}
				metrics_inc_reset(&h.server.metrics, reason)
				conn_log(
					h,
					.Info,
					LOG_EVENT_STREAM_RESET,
					log.LogFields {
						stream_id  = u64(stream.id),
						service_id = string(stream.service_id),
						error_code = wire_error_name(code),
						reason     = reset_reason_label(reason),
					},
				)
				_ = relay_write_failure(dest, .Reset, code, stream.id, h.server.allocator)
				server_emit_connection(
					h.server,
					connection_event_from_stream(.Reset, stream, reset_reason_label(reason)),
				)
			}
			trans.connection_release(dest)
		}
		relay_release_stream(h.server, stream)
	}
	if h.caller_counted {
		sync.atomic_sub(&h.server.metrics.active_caller_connections, 1)
		h.caller_counted = false
	}
	if h.close_reason == .IdleTimeout {
		metrics_inc(&h.server.metrics.session_timeouts_total)
	}
	if h.state == .Authenticated {
		conn_log(h, .Info, LOG_EVENT_SESSION_CLOSED, log.LogFields{reason = conn_close_reason_label(h.close_reason)})
	}
	if h.session_id != INVALID_SESSION_ID {
		_ = registry_remove_session(h.server.registry, h.session_id)
		h.session_id = INVALID_SESSION_ID
	}
	if len(h.principal_id) > 0 {
		delete(h.principal_id, h.server.allocator)
		h.principal_id = ""
	}
	if len(h.organization) > 0 {
		delete(h.organization, h.server.allocator)
		h.organization = ""
	}
	if len(h.credential_label) > 0 {
		delete(h.credential_label, h.server.allocator)
		h.credential_label = ""
	}
	if len(h.credential_id) > 0 {
		delete(h.credential_id, h.server.allocator)
		h.credential_id = ""
	}
	if len(h.environment_id) > 0 {
		delete(h.environment_id, h.server.allocator)
		h.environment_id = ""
	}
	if len(h.principal_kind) > 0 {
		delete(h.principal_kind, h.server.allocator)
		h.principal_kind = ""
	}
	proto.decoder_destroy(&h.decoder)
	trans.connection_destroy(h.conn, h.server.allocator)
	h.conn = nil
}

conn_run :: proc(h: ^ConnHandler) {
	if proto.decoder_init(&h.decoder, h.server.allocator) != .None {
		return
	}
	if h.server.max_frame_payload > 0 {
		h.decoder.max_payload = h.server.max_frame_payload
	}
	h.state = .ExpectHello
	h.session_id = INVALID_SESSION_ID
	h.last_recv = time.now()
	h.last_ping_sent = h.last_recv

	for {
		_ = trans.connection_set_recv_timeout(h.conn, conn_next_timeout(h))
		frame, terr, perr := trans.read_frame(h.conn, &h.decoder, h.server.allocator)
		if terr == .Timeout {
			conn_expire_idle_streams(h)
			conn_expire_grant_streams(h)
			if conn_idle_expired(h) {
				h.close_reason = .IdleTimeout
				return
			}
			if h.state == .Authenticated {
				if !conn_maybe_send_ping(h) {
					h.close_reason = .Peer
					return
				}
			}
			continue
		}
		if terr != .None {
			h.close_reason = .Peer
			return
		}
		if perr != .None {
			h.close_reason = .Protocol
			wire := protocol_error_to_wire(perr)
			metrics_inc(&h.server.metrics.protocol_errors_total)
			if wire == .FrameTooLarge {
				metrics_inc_limit(&h.server.metrics, .FramePayload)
				conn_log(h, .Warn, LOG_EVENT_LIMIT_EXCEEDED, log.LogFields{reason = limit_kind_label(.FramePayload), error_code = wire_error_name(wire)})
			} else {
				conn_log(h, .Warn, LOG_EVENT_PROTOCOL_ERROR, log.LogFields{error_code = wire_error_name(wire)})
			}
			_ = conn_send_failure(h, .Error, wire)
			return
		}
		should_close := conn_handle_frame(h, frame)
		proto.frame_destroy(&frame, h.server.allocator)
		if should_close {
			return
		}
	}
}

conn_idle_expired :: proc(h: ^ConnHandler) -> bool {
	return time.since(h.last_recv) >= h.server.session_timeout
}

conn_next_timeout :: proc(h: ^ConnHandler) -> time.Duration {
	idle := time.since(h.last_recv)
	until_expire := h.server.session_timeout - idle
	until := until_expire
	if h.state == .Authenticated {
		since_ping := time.since(h.last_ping_sent)
		until_ping := h.server.heartbeat_interval - since_ping
		if until_ping < until {
			until = until_ping
		}
		until_stream := relay_until_next_stream_idle(h.server, h.conn)
		if until_stream < until {
			until = until_stream
		}
		until_grant := relay_until_next_grant_expiry(h.server, h.conn)
		if until_grant < until {
			until = until_grant
		}
	}
	return clamp_timeout(until)
}

clamp_timeout :: proc(d: time.Duration) -> time.Duration {
	if d < time.Millisecond {
		return time.Millisecond
	}
	return d
}

conn_maybe_send_ping :: proc(h: ^ConnHandler) -> bool {
	if time.since(h.last_ping_sent) < h.server.heartbeat_interval {
		return true
	}
	nonce := u64(time.time_to_unix_nano(time.now()))
	payload, perr := proto.encode_ping(proto.Ping{nonce = nonce}, h.server.allocator)
	if perr != .None {
		return false
	}
	defer delete(payload, h.server.allocator)
	if !conn_write_payload(h, .Ping, payload) {
		return false
	}
	h.last_ping_sent = time.now()
	return true
}

conn_handle_frame :: proc(h: ^ConnHandler, frame: proto.Frame) -> (close: bool) {
	h.last_recv = time.now()
	if h.session_id != INVALID_SESSION_ID {
		_ = registry_touch_session(h.server.registry, h.session_id)
	}
	switch h.state {
	case .ExpectHello:
		return conn_handle_hello(h, frame)
	case .ExpectAuthenticate:
		return conn_handle_authenticate(h, frame)
	case .Authenticated:
		return conn_handle_authenticated(h, frame)
	}
	return true
}

conn_handle_hello :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	if frame.header.opcode != .Hello {
		_ = conn_send_failure(h, .Error, .ProtocolError)
		return true
	}
	msg, err := proto.decode_hello(frame.payload, h.server.allocator)
	if err != .None {
		_ = conn_send_failure(h, .Error, protocol_error_to_wire(err))
		return true
	}
	delete(msg.implementation, h.server.allocator)
	if msg.major != proto.PROTOCOL_MAJOR {
		_ = conn_send_failure(h, .Error, .UnsupportedVersion)
		return true
	}
	h.role = msg.role
	ack := proto.HelloAck {
		major            = proto.PROTOCOL_MAJOR,
		minor            = proto.PROTOCOL_MINOR,
		capability_bits  = 0,
		implementation   = BROKER_IMPLEMENTATION,
	}
	payload, perr := proto.encode_hello_ack(ack, h.server.allocator)
	if perr != .None {
		return true
	}
	defer delete(payload, h.server.allocator)
	if !conn_write_payload(h, .HelloAck, payload) {
		return true
	}
	h.state = .ExpectAuthenticate
	return false
}

conn_handle_authenticate :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	if frame.header.opcode != .Authenticate {
		metrics_inc(&h.server.metrics.protocol_errors_total)
		_ = conn_send_failure(h, .Error, .ProtocolError)
		h.close_reason = .Protocol
		return true
	}
	auth_started := time.now()
	msg, err := proto.decode_authenticate(frame.payload, h.server.allocator)
	if err != .None {
		metrics_inc(&h.server.metrics.protocol_errors_total)
		_ = conn_send_failure(h, .Error, protocol_error_to_wire(err))
		h.close_reason = .Protocol
		return true
	}
	ip := ip_key_from_endpoint(h.conn.remote)
	if !server_auth_rate_available(h.server, ip) {
		zero_and_free_bytes(msg.token, h.server.allocator)
		metrics_inc(&h.server.metrics.authentication_failures_total)
		metrics_inc_rate_limit(&h.server.metrics, .Authentication)
		conn_log(
			h,
			.Warn,
			LOG_EVENT_AUTH_FAILED,
			log.LogFields{error_code = wire_error_name(.RateLimited), reason = peer_role_reason(h.role)},
		)
		_ = conn_send_failure(h, .AuthenticateFailed, .RateLimited)
		h.close_reason = .Protocol
		return true
	}
	result, aerr := auth.authenticate(h.server.auth, msg.token)
	zero_and_free_bytes(msg.token, h.server.allocator)
	if aerr != .None {
		_ = server_auth_rate_take(h.server, ip)
		metrics_inc(&h.server.metrics.authentication_failures_total)
		conn_log(
			h,
			.Warn,
			LOG_EVENT_AUTH_FAILED,
			log.LogFields{error_code = wire_error_name(.AuthenticationFailed), reason = peer_role_reason(h.role)},
		)
		_ = conn_send_failure(h, .AuthenticateFailed, auth_error_to_wire(aerr))
		h.close_reason = .Protocol
		return true
	}
	pid, clone_err := strings.clone(result.id, h.server.allocator)
	if clone_err != .None {
		_ = conn_send_failure(h, .Error, .InternalError)
		return true
	}
	org_owned, oerr := strings.clone(result.organization, h.server.allocator)
	if oerr != .None {
		delete(pid, h.server.allocator)
		_ = conn_send_failure(h, .Error, .InternalError)
		return true
	}
	label_owned: string
	if len(result.label) > 0 {
		cloned, lerr := strings.clone(result.label, h.server.allocator)
		if lerr != .None {
			delete(pid, h.server.allocator)
			delete(org_owned, h.server.allocator)
			_ = conn_send_failure(h, .Error, .InternalError)
			return true
		}
		label_owned = cloned
	}
	h.principal_id = pid
	h.organization = org_owned
	h.credential_label = label_owned
	h.capabilities = token_capabilities_to_principal(result.capabilities)
	ok := true
	h.credential_id, ok = clone_optional_string(result.credential_id, h.server.allocator)
	if !ok {
		_ = conn_send_failure(h, .Error, .InternalError)
		return true
	}
	h.environment_id, ok = clone_optional_string(result.environment_id, h.server.allocator)
	if !ok {
		_ = conn_send_failure(h, .Error, .InternalError)
		return true
	}
	h.principal_kind, ok = clone_optional_string(result.principal_kind, h.server.allocator)
	if !ok {
		_ = conn_send_failure(h, .Error, .InternalError)
		return true
	}
	h.auth_policy_version = result.policy_version

	if h.role == .Agent {
		principal, perr := make_principal(pid, org_owned)
		if perr != .None {
			_ = conn_send_failure(h, .Error, .InternalError)
			return true
		}
		principal.capabilities = h.capabilities + policy_capabilities(&h.server.policy, pid)
		sid, rerr := registry_add_session(h.server.registry, principal)
		if rerr != .None {
			_ = conn_send_failure(h, .Error, .InternalError)
			return true
		}
		h.session_id = sid
		relay_bind_agent(h.server, sid, h.conn)
		metrics_inc(&h.server.metrics.agent_sessions_total)
	}

	ok_payload, ok_err := proto.encode_authenticate_ok(
		proto.AuthenticateOk{principal_id = pid},
		h.server.allocator,
	)
	if ok_err != .None {
		return true
	}
	defer delete(ok_payload, h.server.allocator)
	if !conn_write_payload(h, .AuthenticateOk, ok_payload) {
		return true
	}
	h.state = .Authenticated
	h.last_ping_sent = time.now()
	server_register_handler(h.server, h)
	metrics_observe(&h.server.metrics, .Authentication, time.since(auth_started))
	if h.role == .Caller {
		sync.atomic_add(&h.server.metrics.active_caller_connections, 1)
		h.caller_counted = true
	}
	conn_log(h, .Info, LOG_EVENT_SESSION_AUTHENTICATED)
	return false
}

conn_handle_authenticated :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	switch frame.header.opcode {
	case .Register:
		return conn_handle_register(h, frame)
	case .Unregister:
		return conn_handle_unregister(h, frame)
	case .Ping:
		return conn_handle_ping(h, frame)
	case .Pong:
		return false
	case .Connect:
		return conn_handle_connect(h, frame)
	case .OpenOk:
		return conn_handle_open_ok(h, frame)
	case .OpenFailed:
		return conn_handle_open_failed(h, frame)
	case .Data, .HalfClose, .Close, .Reset:
		return conn_handle_stream_frame(h, frame)
	case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
	     .RegisterOk, .RegisterFailed, .UnregisterOk, .UnregisterFailed,
	     .ConnectOk, .ConnectFailed, .Open, .Error:
		_ = conn_send_failure(h, .Error, .ProtocolError)
		return true
	}
	_ = conn_send_failure(h, .Error, .ProtocolError)
	return true
}

conn_handle_register :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	if check_opcode_role(h.role, .Register) != .None || h.session_id == INVALID_SESSION_ID {
		return conn_reject_role(h, .Register)
	}
	if !server_register_rate_take(h.server, h.principal_id) {
		metrics_inc_rate_limit(&h.server.metrics, .Registration)
		metrics_inc_register_failure(&h.server.metrics, .RateLimited)
		conn_log(h, .Warn, LOG_EVENT_REGISTER_FAILED, log.LogFields{error_code = wire_error_name(.RateLimited)})
		_ = conn_send_failure(h, .RegisterFailed, .RateLimited)
		return false
	}
	msg, err := proto.decode_register(frame.payload, h.server.allocator)
	if err == .InvalidServiceId {
		metrics_inc_register_failure(&h.server.metrics, .InvalidServiceId)
		conn_log(
			h,
			.Info,
			LOG_EVENT_REGISTER_FAILED,
			log.LogFields{error_code = wire_error_name(.InvalidServiceId)},
		)
		_ = conn_send_failure(h, .RegisterFailed, .InvalidServiceId)
		return false
	}
	if err != .None {
		_ = conn_send_failure(h, .Error, protocol_error_to_wire(err))
		return true
	}
	defer delete(string(msg.service_id), h.server.allocator)

	if perr := check_register_policy(h.server, h, msg.service_id); perr != .None {
		authz := policy_error_to_authz(perr)
		metrics_inc_authz(&h.server.metrics, authz)
		metrics_inc_register_failure(&h.server.metrics, policy_error_to_register_failure(perr))
		conn_log(
			h,
			.Warn,
			LOG_EVENT_REGISTER_FAILED,
			log.LogFields {
				service_id = string(msg.service_id),
				error_code = wire_error_name(.Unauthorized),
				reason     = authz_reason_label(authz),
			},
		)
		_ = conn_send_failure(h, .RegisterFailed, .Unauthorized)
		return false
	}

	if sync.atomic_load(&h.server.draining) {
		metrics_inc_register_failure(&h.server.metrics, .BrokerDraining)
		conn_log(
			h,
			.Info,
			LOG_EVENT_REGISTER_FAILED,
			log.LogFields{service_id = string(msg.service_id), error_code = wire_error_name(.BrokerDraining)},
		)
		_ = conn_send_failure(h, .RegisterFailed, .BrokerDraining)
		return false
	}

	rerr := register_service(h.server.registry, h.session_id, msg.service_id)
	if rerr != .None {
		if rerr == .QuotaExceeded {
			metrics_inc_limit(&h.server.metrics, .RegistrationsPerSession)
			conn_log(
				h,
				.Warn,
				LOG_EVENT_LIMIT_EXCEEDED,
				log.LogFields {
					service_id = string(msg.service_id),
					error_code = wire_error_name(.QuotaExceeded),
					reason     = limit_kind_label(.RegistrationsPerSession),
				},
			)
		}
		if reason, ok := registry_error_to_register_failure(rerr); ok {
			metrics_inc_register_failure(&h.server.metrics, reason)
		}
		conn_log(
			h,
			.Info,
			LOG_EVENT_REGISTER_FAILED,
			log.LogFields {
				service_id = string(msg.service_id),
				error_code = wire_error_name(registry_error_to_wire(rerr)),
				reason     = register_failure_reason_from_registry(rerr),
			},
		)
		_ = conn_send_failure(h, .RegisterFailed, registry_error_to_wire(rerr))
		return false
	}
	ok_payload, ok_err := proto.encode_register_ok(
		proto.RegisterOk{service_id = msg.service_id},
		h.server.allocator,
	)
	if ok_err != .None {
		return true
	}
	defer delete(ok_payload, h.server.allocator)
	metrics_inc(&h.server.metrics.registrations_total)
	conn_log(h, .Info, LOG_EVENT_SERVICE_REGISTERED, log.LogFields{service_id = string(msg.service_id)})
	server_emit_registration(
		h.server,
		RegistrationEvent {
			kind            = .Registered,
			service_id      = msg.service_id,
			principal_id    = h.principal_id,
			organization_id = h.organization,
			environment_id  = h.environment_id,
			credential_id   = h.credential_id,
			session_id      = h.session_id,
		},
	)
	if !conn_write_payload(h, .RegisterOk, ok_payload) {
		return true
	}
	return false
}

conn_handle_unregister :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	if check_opcode_role(h.role, .Unregister) != .None || h.session_id == INVALID_SESSION_ID {
		return conn_reject_role(h, .Unregister)
	}
	if !server_register_rate_take(h.server, h.principal_id) {
		metrics_inc_rate_limit(&h.server.metrics, .Registration)
		metrics_inc_unregister_failure(&h.server.metrics, .RateLimited)
		conn_log(h, .Warn, LOG_EVENT_UNREGISTER_FAILED, log.LogFields{error_code = wire_error_name(.RateLimited)})
		_ = conn_send_failure(h, .UnregisterFailed, .RateLimited)
		return false
	}
	msg, err := proto.decode_unregister(frame.payload, h.server.allocator)
	if err != .None {
		code := protocol_error_to_wire(err)
		if err == .InvalidServiceId {
			metrics_inc_unregister_failure(&h.server.metrics, .InvalidServiceId)
			conn_log(
				h,
				.Info,
				LOG_EVENT_UNREGISTER_FAILED,
				log.LogFields{error_code = wire_error_name(.InvalidServiceId)},
			)
			_ = conn_send_failure(h, .UnregisterFailed, .InvalidServiceId)
			return false
		}
		_ = conn_send_failure(h, .Error, code)
		return true
	}
	defer delete(string(msg.service_id), h.server.allocator)
	if perr := check_unregister_policy(h.server, conn_handler_principal(h)); perr != .None {
		authz := policy_error_to_authz(perr)
		metrics_inc_authz(&h.server.metrics, authz)
		metrics_inc_unregister_failure(&h.server.metrics, .Capability)
		conn_log(
			h,
			.Warn,
			LOG_EVENT_UNREGISTER_FAILED,
			log.LogFields {
				service_id = string(msg.service_id),
				error_code = wire_error_name(.Unauthorized),
				reason     = authz_reason_label(authz),
			},
		)
		_ = conn_send_failure(h, .UnregisterFailed, .Unauthorized)
		return false
	}
	rerr := unregister_service(h.server.registry, h.session_id, msg.service_id)
	if rerr != .None {
		if rerr == .NotOwned {
			metrics_inc_authz(&h.server.metrics, .NotOwned)
			metrics_inc_unregister_failure(&h.server.metrics, .NotOwned)
		}
		conn_log(
			h,
			.Warn,
			LOG_EVENT_UNREGISTER_FAILED,
			log.LogFields {
				service_id = string(msg.service_id),
				error_code = wire_error_name(registry_error_to_wire(rerr)),
				reason     = rerr == .NotOwned ? LABEL_NOT_OWNED : "",
			},
		)
		_ = conn_send_failure(h, .UnregisterFailed, registry_error_to_wire(rerr))
		return false
	}
	ok_payload, ok_err := proto.encode_unregister_ok(
		proto.UnregisterOk{service_id = msg.service_id},
		h.server.allocator,
	)
	if ok_err != .None {
		return true
	}
	defer delete(ok_payload, h.server.allocator)
	metrics_inc(&h.server.metrics.unregistrations_total)
	conn_log(h, .Info, LOG_EVENT_SERVICE_UNREGISTERED, log.LogFields{service_id = string(msg.service_id)})
	server_emit_registration(
		h.server,
		RegistrationEvent {
			kind            = .Unregistered,
			service_id      = msg.service_id,
			principal_id    = h.principal_id,
			organization_id = h.organization,
			environment_id  = h.environment_id,
			credential_id   = h.credential_id,
			session_id      = h.session_id,
		},
	)
	if !conn_write_payload(h, .UnregisterOk, ok_payload) {
		return true
	}
	return false
}

conn_handle_ping :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	msg, err := proto.decode_ping(frame.payload)
	if err != .None {
		_ = conn_send_failure(h, .Error, protocol_error_to_wire(err))
		return true
	}
	payload, perr := proto.encode_pong(proto.Pong{nonce = msg.nonce}, h.server.allocator)
	if perr != .None {
		return true
	}
	defer delete(payload, h.server.allocator)
	if !conn_write_payload(h, .Pong, payload) {
		return true
	}
	return false
}

conn_handle_connect :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	if check_opcode_role(h.role, .Connect) != .None {
		return conn_reject_role(h, .Connect)
	}
	metrics_inc(&h.server.metrics.connection_attempts_total)
	ip := ip_key_from_endpoint(h.conn.remote)
	if !server_connect_rate_take(h.server, h.principal_id, ip) {
		metrics_inc_rate_limit(&h.server.metrics, .Connect)
		metrics_inc_connect_failure(&h.server.metrics, .RateLimited)
		conn_log(h, .Warn, LOG_EVENT_CONNECT_FAILED, log.LogFields{error_code = wire_error_name(.RateLimited)})
		_ = conn_send_failure(h, .ConnectFailed, .RateLimited)
		return false
	}
	msg, err := proto.decode_connect(frame.payload, h.server.allocator)
	if err == .InvalidServiceId {
		metrics_inc_connect_failure(&h.server.metrics, .InvalidServiceId)
		conn_log(
			h,
			.Info,
			LOG_EVENT_CONNECT_FAILED,
			log.LogFields{error_code = wire_error_name(.InvalidServiceId)},
		)
		_ = conn_send_failure(h, .ConnectFailed, .InvalidServiceId)
		return false
	}
	if err != .None {
		metrics_inc(&h.server.metrics.protocol_errors_total)
		metrics_inc_connect_failure(&h.server.metrics, .ProtocolError)
		_ = conn_send_failure(h, .Error, protocol_error_to_wire(err))
		h.close_reason = .Protocol
		return true
	}
	defer delete(string(msg.service_id), h.server.allocator)

	if server_global_buffer_at_ceiling(h.server) {
		metrics_inc_limit(&h.server.metrics, .GlobalBuffer)
		metrics_inc_connect_failure(&h.server.metrics, .QuotaExceeded)
		conn_log(
			h,
			.Warn,
			LOG_EVENT_CONNECT_FAILED,
			log.LogFields {
				service_id = string(msg.service_id),
				error_code = wire_error_name(.QuotaExceeded),
				reason     = limit_kind_label(.GlobalBuffer),
			},
		)
		_ = conn_send_failure(h, .ConnectFailed, .QuotaExceeded)
		return false
	}

	if sync.atomic_load(&h.server.draining) {
		metrics_inc_connect_failure(&h.server.metrics, .BrokerDraining)
		conn_log(
			h,
			.Info,
			LOG_EVENT_CONNECT_FAILED,
			log.LogFields{service_id = string(msg.service_id), error_code = wire_error_name(.BrokerDraining)},
		)
		_ = conn_send_failure(h, .ConnectFailed, .BrokerDraining)
		return false
	}

	lookup_started := time.now()
	rec, found := lookup_service(h.server.registry, msg.service_id)
	metrics_observe(&h.server.metrics, .ServiceLookup, time.since(lookup_started))
	if !found {
		metrics_inc_connect_failure(&h.server.metrics, .ServiceNotFound)
		conn_log(
			h,
			.Info,
			LOG_EVENT_CONNECT_FAILED,
			log.LogFields{service_id = string(msg.service_id), error_code = wire_error_name(.ServiceNotFound)},
		)
		_ = conn_send_failure(h, .ConnectFailed, .ServiceNotFound)
		return false
	}

	decision, polerr := check_connect_policy(h.server, h, rec)
	if polerr != .None {
		authz := policy_error_to_authz(polerr)
		code: proto.WireError = .Unauthorized
		fail: ConnectFailureReason = .Unauthorized
		if polerr == .QuotaExceeded {
			code = .QuotaExceeded
			fail = .QuotaExceeded
		}
		metrics_inc_authz(&h.server.metrics, authz)
		metrics_inc_connect_failure(&h.server.metrics, fail)
		conn_log(
			h,
			.Warn,
			LOG_EVENT_CONNECT_FAILED,
			log.LogFields {
				service_id = string(msg.service_id),
				error_code = wire_error_name(code),
				reason     = authz_reason_label(authz),
			},
		)
		conn_emit_connect_decision(h, .Denied, msg.service_id, decision)
		_ = conn_send_failure(h, .ConnectFailed, code)
		return false
	}
	conn_emit_connect_decision(h, .Authorized, msg.service_id, decision)

	stream_id, agent_conn, oerr := relay_open_stream(
		h.server,
		msg.service_id,
		rec.agent_session,
		h.conn,
		decision,
		h,
	)
	if oerr != .None {
		code: proto.WireError = .AgentUnavailable
		if oerr == .QuotaExceeded {
			code = .QuotaExceeded
			metrics_inc_limit(&h.server.metrics, .StreamsPerSession)
			conn_log(
				h,
				.Warn,
				LOG_EVENT_LIMIT_EXCEEDED,
				log.LogFields {
					service_id = string(msg.service_id),
					error_code = wire_error_name(.QuotaExceeded),
					reason     = limit_kind_label(.StreamsPerSession),
				},
			)
		} else if oerr == .OutOfMemory {
			code = .InternalError
		}
		fail_reason: ConnectFailureReason = .AgentUnavailable
		if code == .QuotaExceeded {
			fail_reason = .QuotaExceeded
		} else if code == .InternalError {
			fail_reason = .InternalError
		}
		metrics_inc_connect_failure(&h.server.metrics, fail_reason)
		conn_log(
			h,
			.Info,
			LOG_EVENT_CONNECT_FAILED,
			log.LogFields{service_id = string(msg.service_id), error_code = wire_error_name(code)},
		)
		_ = conn_send_failure(h, .ConnectFailed, code)
		return false
	}

	open_payload, perr := proto.encode_open(proto.Open{service_id = msg.service_id}, h.server.allocator)
	if perr != .None {
		trans.connection_release(agent_conn)
		relay_drop_stream(h.server, stream_id)
		metrics_inc_connect_failure(&h.server.metrics, .InternalError)
		_ = conn_send_failure(h, .ConnectFailed, .InternalError)
		return false
	}
	qerr := server_enqueue_frame(h.server, agent_conn, .Open, open_payload, stream_id)
	delete(open_payload, h.server.allocator)
	trans.connection_release(agent_conn)
	if qerr != .None {
		relay_drop_stream(h.server, stream_id)
		metrics_inc_connect_failure(&h.server.metrics, .AgentUnavailable)
		_ = conn_send_failure(h, .ConnectFailed, .AgentUnavailable)
		return false
	}
	return false
}

conn_handle_open_ok :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	if check_opcode_role(h.role, .OpenOk) != .None {
		return conn_reject_role(h, .OpenOk)
	}
	if proto.decode_empty(frame.payload) != .None {
		_ = conn_send_failure(h, .Error, .ProtocolError)
		return true
	}
	stream, err := relay_apply(h.server, frame.header.stream_id, .OpenOk, .Agent)
	if err == .NotFound {
		metrics_inc_reset(&h.server.metrics, .StreamNotFound)
		conn_log(
			h,
			.Info,
			LOG_EVENT_STREAM_RESET,
			log.LogFields{stream_id = u64(frame.header.stream_id), error_code = wire_error_name(.StreamNotFound), reason = reset_reason_label(.StreamNotFound)},
		)
		_ = conn_send_failure_stream(h, .Reset, .StreamNotFound, frame.header.stream_id)
		return false
	}
	if err != .None {
		_ = conn_send_failure_stream(h, .Reset, .ProtocolError, frame.header.stream_id)
		return false
	}
	metrics_observe(&h.server.metrics, .OpenOk, time.since(stream.opened_at))
	peer, _, ok := relay_acquire_peer(h.server, stream.id, .Caller)
	if !ok {
		relay_drop_stream(h.server, stream.id)
		metrics_inc_connect_failure(&h.server.metrics, .AgentUnavailable)
		return false
	}
	qerr := server_enqueue_frame(h.server, peer, .ConnectOk, nil, stream.id)
	trans.connection_release(peer)
	if qerr != .None {
		relay_drop_stream(h.server, stream.id)
		metrics_inc_connect_failure(&h.server.metrics, .AgentUnavailable)
		return false
	}
	metrics_inc(&h.server.metrics.connection_success_total)
	metrics_observe(&h.server.metrics, .ConnectOk, time.since(stream.opened_at))
	conn_log(
		h,
		.Info,
		LOG_EVENT_CONNECT_OK,
		log.LogFields{stream_id = u64(stream.id), service_id = string(stream.service_id)},
	)
	server_emit_connection(h.server, connection_event_from_stream(.Opened, stream))
	return false
}

conn_handle_open_failed :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	if check_opcode_role(h.role, .OpenFailed) != .None {
		return conn_reject_role(h, .OpenFailed)
	}
	fail, ferr := proto.decode_wire_failure(frame.payload, h.server.allocator)
	if ferr != .None {
		_ = conn_send_failure(h, .Error, protocol_error_to_wire(ferr))
		return true
	}
	delete(fail.diagnostic, h.server.allocator)

	stream, err := relay_apply(h.server, frame.header.stream_id, .OpenFailed, .Agent)
	if err == .NotFound {
		_ = conn_send_failure_stream(h, .Reset, .StreamNotFound, frame.header.stream_id)
		return false
	}
	if err != .None {
		_ = conn_send_failure_stream(h, .Reset, .ProtocolError, frame.header.stream_id)
		return false
	}
	peer, _, ok := relay_acquire_peer(h.server, stream.id, .Caller)
	if ok {
		_ = server_enqueue_failure(
			h.server,
			peer,
			.ConnectFailed,
			.LocalServiceUnavailable,
			proto.CONNECTION_STREAM_ID,
		)
		trans.connection_release(peer)
	}
	metrics_inc_connect_failure(&h.server.metrics, .LocalServiceUnavailable)
	conn_log(
		h,
		.Info,
		LOG_EVENT_CONNECT_FAILED,
		log.LogFields {
			stream_id  = u64(stream.id),
			service_id = string(stream.service_id),
			error_code = wire_error_name(.LocalServiceUnavailable),
		},
	)
	relay_drop_stream(h.server, stream.id)
	return false
}

conn_handle_stream_frame :: proc(h: ^ConnHandler, frame: proto.Frame) -> bool {
	from: StreamPeer = h.role == .Agent ? .Agent : .Caller
	event: StreamEvent
	switch frame.header.opcode {
	case .Data:
		event = .Data
	case .HalfClose:
		if proto.decode_empty(frame.payload) != .None {
			_ = conn_send_failure(h, .Error, .ProtocolError)
			return true
		}
		event = .HalfClose
	case .Close:
		if proto.decode_empty(frame.payload) != .None {
			_ = conn_send_failure(h, .Error, .ProtocolError)
			return true
		}
		event = .Close
	case .Reset:
		event = .Reset
	case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
	     .Register, .RegisterOk, .RegisterFailed, .Unregister, .UnregisterOk,
	     .UnregisterFailed, .Connect, .ConnectOk, .ConnectFailed, .Open, .OpenOk,
	     .OpenFailed, .Ping, .Pong, .Error:
		_ = conn_send_failure(h, .Error, .ProtocolError)
		return true
	}

	stream, err := relay_apply(h.server, frame.header.stream_id, event, from)
	if err == .NotFound {
		metrics_inc_reset(&h.server.metrics, .StreamNotFound)
		conn_log(
			h,
			.Info,
			LOG_EVENT_STREAM_RESET,
			log.LogFields {
				stream_id  = u64(frame.header.stream_id),
				error_code = wire_error_name(.StreamNotFound),
				reason     = reset_reason_label(.StreamNotFound),
			},
		)
		_ = conn_send_failure_stream(h, .Reset, .StreamNotFound, frame.header.stream_id)
		return false
	}
	if err != .None {
		conn_abort_stream(h, frame.header.stream_id, from)
		return false
	}

	if event == .Reset {
		metrics_inc_reset(&h.server.metrics, .Peer)
		conn_log(
			h,
			.Info,
			LOG_EVENT_STREAM_RESET,
			log.LogFields{stream_id = u64(stream.id), service_id = string(stream.service_id), reason = reset_reason_label(.Peer)},
		)
		server_emit_connection(h.server, connection_event_from_stream(.Reset, stream, LABEL_PEER))
	}

	dest := stream_peer_opposite(from)
	peer, _, ok := relay_acquire_peer(h.server, stream.id, dest)
	if ok {
		if !conn_enqueue_stream(h, peer, frame.header.opcode, frame.payload, frame.header.stream_id, from) {
			trans.connection_release(peer)
			return false
		}
		trans.connection_release(peer)
	}
	if stream_state_is_terminal(stream.state) {
		if event == .Close {
			latest, found := relay_lookup_stream(h.server, stream.id)
			if found {
				stream = latest
			}
			server_emit_connection(h.server, connection_event_from_stream(.Closed, stream))
		}
		relay_drop_stream(h.server, stream.id)
	}
	return false
}

conn_enqueue_stream :: proc(
	h: ^ConnHandler,
	dest: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId,
	from: StreamPeer,
) -> bool {
	needed := outbox_counts_as_data(opcode) ? len(payload) : 0
	if needed > 0 && h.server.max_stream_buffer > 0 && needed > h.server.max_stream_buffer {
		conn_reset_overflow(h, stream_id, .StreamBuffer)
		return false
	}
	for {
		err := server_enqueue_frame(h.server, dest, opcode, payload, stream_id)
		if err == .None {
			if needed > 0 {
				metrics_add_bytes(&h.server.metrics, from, needed)
				relay_add_stream_bytes(h.server, stream_id, from, needed)
			}
			return true
		}
		if err == .Closed {
			return true
		}
		if err == .StreamLimit && outbox_counts_as_data(opcode) {
			box := server_lookup_outbox(h.server, dest)
			if box == nil {
				return true
			}
			ok := outbox_wait_stream_space(box, stream_id, needed, h.server.session_timeout)
			outbox_release(box)
			if ok {
				_, still := relay_lookup_stream(h.server, stream_id)
				if still {
					continue
				}
				return true
			}
			conn_reset_overflow(h, stream_id, .StreamBuffer)
			return false
		}
		if err == .StreamLimit {
			conn_reset_overflow(h, stream_id, .StreamBuffer)
			return false
		}
		if err == .ConnectionLimit {
			conn_reset_overflow(h, stream_id, .ConnectionBuffer)
			return false
		}
		if err == .GlobalLimit {
			conn_reset_overflow(h, stream_id, .GlobalBuffer)
			return false
		}
		conn_reset_overflow(h, stream_id, .StreamBuffer)
		return false
	}
}

conn_reset_overflow :: proc(h: ^ConnHandler, stream_id: proto.StreamId, limit: LimitKind) {
	reason: ResetReason = .StreamBuffer
	diagnostic := DIAGNOSTIC_STREAM_BUFFER_EXCEEDED
	switch limit {
	case .ConnectionBuffer:
		reason = .ConnectionBuffer
		diagnostic = DIAGNOSTIC_CONNECTION_BUFFER_EXCEEDED
	case .GlobalBuffer:
		reason = .ConnectionBuffer
		diagnostic = DIAGNOSTIC_GLOBAL_BUFFER_EXCEEDED
	case .StreamBuffer, .StreamsPerSession, .RegistrationsPerSession, .PhysicalConnections,
	     .ConnectionsPerIp, .FramePayload, .FileDescriptors:
		reason = .StreamBuffer
		diagnostic = DIAGNOSTIC_STREAM_BUFFER_EXCEEDED
	}
	metrics_inc_limit(&h.server.metrics, limit)
	metrics_inc_reset(&h.server.metrics, reason)
	conn_log(
		h,
		.Warn,
		LOG_EVENT_STREAM_RESET,
		log.LogFields {
			stream_id  = u64(stream_id),
			error_code = wire_error_name(.InternalError),
			reason     = reset_reason_label(reason),
		},
	)
	conn_log(h, .Warn, LOG_EVENT_LIMIT_EXCEEDED, log.LogFields{stream_id = u64(stream_id), reason = limit_kind_label(limit)})
	stream, found := relay_lookup_stream(h.server, stream_id)
	if !found {
		return
	}
	if caller := server_lookup_outbox(h.server, stream.caller_conn); caller != nil {
		outbox_drop_stream(caller, stream_id)
		_ = outbox_enqueue_failure(caller, .Reset, .InternalError, stream_id, diagnostic)
		outbox_release(caller)
	}
	if agent := server_lookup_outbox(h.server, stream.agent_conn); agent != nil {
		outbox_drop_stream(agent, stream_id)
		_ = outbox_enqueue_failure(agent, .Reset, .InternalError, stream_id, diagnostic)
		outbox_release(agent)
	}
	server_emit_connection(h.server, connection_event_from_stream(.Reset, stream, reset_reason_label(reason)))
	relay_drop_stream(h.server, stream_id)
}

conn_expire_idle_streams :: proc(h: ^ConnHandler) {
	if h.server.stream_idle_timeout <= 0 {
		return
	}
	ids := relay_idle_stream_ids(h.server, h.conn, h.server.stream_idle_timeout, h.server.allocator)
	defer delete(ids)
	for id in ids {
		conn_reset_idle_stream(h, id)
	}
}

conn_reset_idle_stream :: proc(h: ^ConnHandler, stream_id: proto.StreamId) {
	stream, found := relay_lookup_stream(h.server, stream_id)
	if !found {
		return
	}
	metrics_inc_reset(&h.server.metrics, .StreamIdle)
	conn_log(
		h,
		.Info,
		LOG_EVENT_STREAM_RESET,
		log.LogFields {
			stream_id  = u64(stream_id),
			service_id = string(stream.service_id),
			error_code = wire_error_name(.Timeout),
			reason     = reset_reason_label(.StreamIdle),
		},
	)
	if stream.state == .Opening {
		if trans.connection_acquire(stream.caller_conn) {
			_ = server_enqueue_failure(
				h.server,
				stream.caller_conn,
				.ConnectFailed,
				.Timeout,
				proto.CONNECTION_STREAM_ID,
			)
			trans.connection_release(stream.caller_conn)
		}
		if trans.connection_acquire(stream.agent_conn) {
			_ = server_enqueue_failure(h.server, stream.agent_conn, .Reset, .Timeout, stream_id)
			trans.connection_release(stream.agent_conn)
		}
	} else {
		if caller := server_lookup_outbox(h.server, stream.caller_conn); caller != nil {
			outbox_drop_stream(caller, stream_id)
			_ = outbox_enqueue_failure(caller, .Reset, .Timeout, stream_id)
			outbox_release(caller)
		}
		if agent := server_lookup_outbox(h.server, stream.agent_conn); agent != nil {
			outbox_drop_stream(agent, stream_id)
			_ = outbox_enqueue_failure(agent, .Reset, .Timeout, stream_id)
			outbox_release(agent)
		}
	}
	server_emit_connection(h.server, connection_event_from_stream(.Reset, stream, reset_reason_label(.StreamIdle)))
	relay_drop_stream(h.server, stream_id)
}

conn_expire_grant_streams :: proc(h: ^ConnHandler) {
	expired := relay_expired_grant_streams(h.server, h.conn, h.server.allocator)
	defer delete(expired)
	for item in expired {
		conn_reset_grant_stream(h, item.id, item.reason)
	}
}

conn_reset_grant_stream :: proc(h: ^ConnHandler, stream_id: proto.StreamId, reason: ResetReason) {
	stream, found := relay_lookup_stream(h.server, stream_id)
	if !found {
		return
	}
	code: proto.WireError = .Timeout
	if reason == .GrantRevoked {
		code = .Unauthorized
	}
	metrics_inc_reset(&h.server.metrics, reason)
	conn_log(
		h,
		.Info,
		LOG_EVENT_STREAM_RESET,
		log.LogFields {
			stream_id  = u64(stream_id),
			service_id = string(stream.service_id),
			error_code = wire_error_name(code),
			reason     = reset_reason_label(reason),
		},
	)
	if stream.state == .Opening {
		if trans.connection_acquire(stream.caller_conn) {
			_ = server_enqueue_failure(
				h.server,
				stream.caller_conn,
				.ConnectFailed,
				code,
				proto.CONNECTION_STREAM_ID,
			)
			trans.connection_release(stream.caller_conn)
		}
		if trans.connection_acquire(stream.agent_conn) {
			_ = server_enqueue_failure(h.server, stream.agent_conn, .Reset, code, stream_id)
			trans.connection_release(stream.agent_conn)
		}
	} else {
		if caller := server_lookup_outbox(h.server, stream.caller_conn); caller != nil {
			outbox_drop_stream(caller, stream_id)
			_ = outbox_enqueue_failure(caller, .Reset, code, stream_id)
			outbox_release(caller)
		}
		if agent := server_lookup_outbox(h.server, stream.agent_conn); agent != nil {
			outbox_drop_stream(agent, stream_id)
			_ = outbox_enqueue_failure(agent, .Reset, code, stream_id)
			outbox_release(agent)
		}
	}
	server_emit_connection(h.server, connection_event_from_stream(.Reset, stream, reset_reason_label(reason)))
	relay_drop_stream(h.server, stream_id)
}

conn_abort_stream :: proc(h: ^ConnHandler, stream_id: proto.StreamId, from: StreamPeer) {
	metrics_inc_reset(&h.server.metrics, .ProtocolError)
	conn_log(
		h,
		.Warn,
		LOG_EVENT_STREAM_RESET,
		log.LogFields{stream_id = u64(stream_id), error_code = wire_error_name(.ProtocolError), reason = reset_reason_label(.ProtocolError)},
	)
	dest := stream_peer_opposite(from)
	peer, _, ok := relay_acquire_peer(h.server, stream_id, dest)
	if ok {
		if box := server_lookup_outbox(h.server, peer); box != nil {
			outbox_drop_stream(box, stream_id)
			outbox_release(box)
		}
		_ = server_enqueue_failure(h.server, peer, .Reset, .ProtocolError, stream_id)
		trans.connection_release(peer)
	}
	_ = conn_send_failure_stream(h, .Reset, .ProtocolError, stream_id)
	relay_drop_stream(h.server, stream_id)
}

conn_write_payload :: proc(
	h: ^ConnHandler,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId = proto.CONNECTION_STREAM_ID,
) -> bool {
	return relay_write(h.conn, opcode, payload, stream_id, h.server.allocator)
}

conn_handler_principal :: proc(h: ^ConnHandler) -> Principal {
	return Principal {
		id           = PrincipalId(h.principal_id),
		organization = OrganizationId(h.organization),
		capabilities = h.capabilities,
	}
}

clone_optional_string :: proc(src: string, allocator: mem.Allocator) -> (string, bool) {
	if len(src) == 0 {
		return "", true
	}
	cloned, err := strings.clone(src, allocator)
	if err != .None {
		return "", false
	}
	return cloned, true
}

conn_emit_connect_decision :: proc(
	h: ^ConnHandler,
	kind: ConnectionEventKind,
	service_id: ServiceId,
	d: AuthzDecision,
) {
	if h == nil || h.server == nil {
		return
	}
	org := d.organization_id
	if len(org) == 0 {
		org = h.organization
	}
	env := d.environment_id
	if len(env) == 0 {
		env = h.environment_id
	}
	server_emit_connection(
		h.server,
		ConnectionEvent {
			kind            = kind,
			stream_id       = proto.CONNECTION_STREAM_ID,
			service_id      = service_id,
			grant_id        = d.access_grant_id,
			credential_id   = h.credential_id,
			principal_id    = h.principal_id,
			organization_id = org,
			environment_id  = env,
			session_id      = h.session_id,
		},
	)
}

conn_emit_session_unregistered :: proc(h: ^ConnHandler) {
	if h == nil || h.server == nil || h.session_id == INVALID_SESSION_ID {
		return
	}
	if h.server.registration_observer == nil {
		return
	}
	ids := copy_session_service_ids(h.server.registry, h.session_id, h.server.allocator)
	defer {
		for sid in ids {
			delete(string(sid), h.server.allocator)
		}
		delete(ids, h.server.allocator)
	}
	for sid in ids {
		server_emit_registration(
			h.server,
			RegistrationEvent {
				kind            = .Unregistered,
				service_id      = sid,
				principal_id    = h.principal_id,
				organization_id = h.organization,
				environment_id  = h.environment_id,
				credential_id   = h.credential_id,
				session_id      = h.session_id,
			},
		)
	}
}

role_violation_reason :: proc(role: proto.PeerRole, opcode: proto.Opcode) -> string {
	if role == .Agent {
		switch opcode {
		case .Connect:
			return REASON_AGENT_CONNECT
		case .Open:
			return REASON_AGENT_OPEN
		case .Register:
			return REASON_AGENT_REGISTER
		case .Unregister:
			return REASON_AGENT_UNREGISTER
		case .OpenOk:
			return REASON_AGENT_OPEN_OK
		case .OpenFailed:
			return REASON_AGENT_OPEN_FAILED
		case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
		     .RegisterOk, .RegisterFailed, .UnregisterOk, .UnregisterFailed,
		     .ConnectOk, .ConnectFailed, .Data, .HalfClose, .Close, .Reset, .Ping, .Pong, .Error:
			return REASON_AGENT_OPCODE
		}
		return REASON_AGENT_OPCODE
	}
	switch opcode {
	case .Register:
		return REASON_CALLER_REGISTER
	case .Unregister:
		return REASON_CALLER_UNREGISTER
	case .Open:
		return REASON_CALLER_OPEN
	case .OpenOk:
		return REASON_CALLER_OPEN_OK
	case .OpenFailed:
		return REASON_CALLER_OPEN_FAILED
	case .Connect:
		return REASON_CALLER_CONNECT
	case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
	     .RegisterOk, .RegisterFailed, .UnregisterOk, .UnregisterFailed,
	     .ConnectOk, .ConnectFailed, .Data, .HalfClose, .Close, .Reset, .Ping, .Pong, .Error:
		return REASON_CALLER_OPCODE
	}
	return REASON_CALLER_OPCODE
}

conn_reject_role :: proc(h: ^ConnHandler, opcode: proto.Opcode) -> bool {
	metrics_inc_role_violation(&h.server.metrics)
	conn_log(
		h,
		.Warn,
		LOG_EVENT_ROLE_VIOLATION,
		log.LogFields{error_code = wire_error_name(.ProtocolError), reason = role_violation_reason(h.role, opcode)},
	)
	_ = conn_send_failure(h, .Error, .ProtocolError)
	h.close_reason = .Protocol
	return true
}

conn_send_failure :: proc(h: ^ConnHandler, opcode: proto.Opcode, code: proto.WireError) -> bool {
	return conn_send_failure_stream(h, opcode, code, proto.CONNECTION_STREAM_ID)
}

conn_send_failure_stream :: proc(
	h: ^ConnHandler,
	opcode: proto.Opcode,
	code: proto.WireError,
	stream_id: proto.StreamId,
) -> bool {
	if stream_id != proto.CONNECTION_STREAM_ID && h.outbox != nil {
		err := outbox_enqueue_failure(h.outbox, opcode, code, stream_id)
		if err == .None {
			return true
		}
		if err == .Closed {
			return false
		}
	}
	return relay_write_failure(h.conn, opcode, code, stream_id, h.server.allocator)
}

token_capabilities_to_principal :: proc(caps: auth.TokenCapabilities) -> PrincipalCapabilities {
	out: PrincipalCapabilities
	if .RegisterService in caps {
		out += {.RegisterService}
	}
	if .ConnectService in caps {
		out += {.ConnectService}
	}
	return out
}

zero_and_free_bytes :: proc(buf: []u8, allocator := context.allocator) {
	if len(buf) > 0 {
		crypto.zero_explicit(raw_data(buf), len(buf))
	}
	delete(buf, allocator)
}
