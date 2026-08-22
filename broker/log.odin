package broker

import log "../logging"
import proto "../protocol"
import "core:net"

server_log :: proc(server: ^Server, level: log.LogLevel, event: string, fields: log.LogFields = {}) {
	if server == nil || server.logger == nil {
		return
	}
	log.log_event(server.logger, level, event, fields)
}

conn_log :: proc(h: ^ConnHandler, level: log.LogLevel, event: string, fields: log.LogFields = {}) {
	if h == nil || h.server == nil || h.server.logger == nil {
		return
	}
	f := fields
	if f.session_id == 0 && h.session_id != INVALID_SESSION_ID {
		f.session_id = u64(h.session_id)
	}
	if len(f.principal_id) == 0 {
		f.principal_id = h.principal_id
	}
	if len(f.organization_id) == 0 {
		f.organization_id = h.organization
	}
	if len(f.credential_label) == 0 {
		f.credential_label = h.credential_label
	}
	if len(f.remote_address) == 0 && h.conn != nil {
		f.remote_address = net.endpoint_to_string(h.conn.remote)
	}
	log.log_event(h.server.logger, level, event, f)
}

conn_close_reason_label :: proc(reason: ConnCloseReason) -> string {
	switch reason {
	case .None:
		return ""
	case .IdleTimeout:
		return LABEL_IDLE_TIMEOUT
	case .Protocol:
		return LABEL_PROTOCOL_ERROR
	case .Peer:
		return LABEL_PEER
	}
	return ""
}

peer_role_reason :: proc(role: proto.PeerRole) -> string {
	switch role {
	case .Agent:
		return LABEL_AGENT
	case .Caller:
		return LABEL_CALLER
	}
	return ""
}

wire_error_name :: proc(err: proto.WireError) -> string {
	switch err {
	case .None:
		return "OK"
	case .ProtocolError:
		return "PROTOCOL_ERROR"
	case .UnsupportedVersion:
		return "UNSUPPORTED_VERSION"
	case .AuthenticationFailed:
		return "AUTHENTICATION_FAILED"
	case .Unauthorized:
		return "UNAUTHORIZED"
	case .InvalidServiceId:
		return "INVALID_SERVICE_ID"
	case .ServiceNotFound:
		return "SERVICE_NOT_FOUND"
	case .ServiceAlreadyRegistered:
		return "SERVICE_ALREADY_REGISTERED"
	case .AgentUnavailable:
		return "AGENT_UNAVAILABLE"
	case .LocalServiceUnavailable:
		return "LOCAL_SERVICE_UNAVAILABLE"
	case .QuotaExceeded:
		return "QUOTA_EXCEEDED"
	case .RateLimited:
		return "RATE_LIMITED"
	case .StreamNotFound:
		return "STREAM_NOT_FOUND"
	case .StreamAlreadyExists:
		return "STREAM_ALREADY_EXISTS"
	case .FrameTooLarge:
		return "FRAME_TOO_LARGE"
	case .Timeout:
		return "TIMEOUT"
	case .BrokerDraining:
		return "BROKER_DRAINING"
	case .InternalError:
		return "INTERNAL_ERROR"
	}
	return "INTERNAL_ERROR"
}
