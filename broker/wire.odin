package broker

import auth "../auth"
import proto "../protocol"

registry_error_to_wire :: proc(err: RegistryError) -> proto.WireError {
	switch err {
	case .None:
		return .None
	case .ServiceAlreadyRegistered:
		return .ServiceAlreadyRegistered
	case .InvalidServiceId:
		return .InvalidServiceId
	case .ServiceNotFound, .SessionNotFound:
		return .ServiceNotFound
	case .NotOwned:
		return .Unauthorized
	case .QuotaExceeded:
		return .QuotaExceeded
	case .OutOfMemory, .InvalidPrincipal:
		return .InternalError
	}
	return .InternalError
}

auth_error_to_wire :: proc(err: auth.AuthError) -> proto.WireError {
	switch err {
	case .None:
		return .None
	case .InvalidToken, .Expired:
		return .AuthenticationFailed
	case .InvalidPrincipal, .OutOfMemory:
		return .InternalError
	}
	return .InternalError
}

protocol_error_to_wire :: proc(err: proto.ProtocolError) -> proto.WireError {
	switch err {
	case .None:
		return .None
	case .FrameTooLarge, .BufferFull:
		return .FrameTooLarge
	case .InvalidVersion:
		return .UnsupportedVersion
	case .InvalidServiceId:
		return .InvalidServiceId
	case .Truncated, .InvalidOpcode, .InvalidFlags, .InvalidPayload, .InvalidStreamId, .InvalidUtf8, .OutOfMemory:
		return .ProtocolError
	}
	return .ProtocolError
}

wire_error_diagnostic :: proc(err: proto.WireError) -> string {
	switch err {
	case .None:
		return ""
	case .ProtocolError:
		return "protocol error"
	case .UnsupportedVersion:
		return "unsupported version"
	case .AuthenticationFailed:
		return "authentication failed"
	case .Unauthorized:
		return "unauthorized"
	case .InvalidServiceId:
		return "invalid service id"
	case .ServiceNotFound:
		return "service not found"
	case .ServiceAlreadyRegistered:
		return "service already registered"
	case .QuotaExceeded:
		return "quota exceeded"
	case .FrameTooLarge:
		return "frame too large"
	case .InternalError:
		return "internal error"
	case .AgentUnavailable:
		return "agent unavailable"
	case .LocalServiceUnavailable:
		return "local service unavailable"
	case .StreamNotFound:
		return "stream not found"
	case .StreamAlreadyExists:
		return "stream already exists"
	case .RateLimited, .Timeout:
		return "error"
	case .BrokerDraining:
		return "broker draining"
	}
	return "error"
}
