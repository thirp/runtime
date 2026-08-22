package c_abi

import ag "../agent"
import cl "../caller"
import proto "../protocol"
import "core:c"

ERR_OK :: c.int(0)
ERR_PROTOCOL_ERROR :: c.int(proto.WireError.ProtocolError)
ERR_UNSUPPORTED_VERSION :: c.int(proto.WireError.UnsupportedVersion)
ERR_AUTHENTICATION_FAILED :: c.int(proto.WireError.AuthenticationFailed)
ERR_UNAUTHORIZED :: c.int(proto.WireError.Unauthorized)
ERR_INVALID_SERVICE_ID :: c.int(proto.WireError.InvalidServiceId)
ERR_SERVICE_NOT_FOUND :: c.int(proto.WireError.ServiceNotFound)
ERR_SERVICE_ALREADY_REGISTERED :: c.int(proto.WireError.ServiceAlreadyRegistered)
ERR_AGENT_UNAVAILABLE :: c.int(proto.WireError.AgentUnavailable)
ERR_LOCAL_SERVICE_UNAVAILABLE :: c.int(proto.WireError.LocalServiceUnavailable)
ERR_QUOTA_EXCEEDED :: c.int(proto.WireError.QuotaExceeded)
ERR_RATE_LIMITED :: c.int(proto.WireError.RateLimited)
ERR_STREAM_NOT_FOUND :: c.int(proto.WireError.StreamNotFound)
ERR_STREAM_ALREADY_EXISTS :: c.int(proto.WireError.StreamAlreadyExists)
ERR_FRAME_TOO_LARGE :: c.int(proto.WireError.FrameTooLarge)
ERR_TIMEOUT :: c.int(proto.WireError.Timeout)
ERR_BROKER_DRAINING :: c.int(proto.WireError.BrokerDraining)
ERR_INTERNAL_ERROR :: c.int(proto.WireError.InternalError)

ERR_INVALID_ARGUMENT :: c.int(100)
ERR_OUT_OF_MEMORY :: c.int(101)
ERR_NOT_CONNECTED :: c.int(102)
ERR_STOPPED :: c.int(103)
ERR_CLOSED :: c.int(104)
ERR_RESET :: c.int(105)
ERR_TRANSPORT :: c.int(106)

agent_error_to_c :: proc(err: ag.AgentError) -> c.int {
	switch err {
	case .None:
		return ERR_OK
	case .InvalidConfig:
		return ERR_INVALID_ARGUMENT
	case .InvalidServiceId:
		return ERR_INVALID_SERVICE_ID
	case .Transport:
		return ERR_TRANSPORT
	case .AuthFailed:
		return ERR_AUTHENTICATION_FAILED
	case .RegisterFailed:
		return ERR_INTERNAL_ERROR
	case .ServiceAlreadyRegistered:
		return ERR_SERVICE_ALREADY_REGISTERED
	case .QuotaExceeded:
		return ERR_QUOTA_EXCEEDED
	case .BrokerDraining:
		return ERR_BROKER_DRAINING
	case .Stopped:
		return ERR_STOPPED
	case .Internal:
		return ERR_INTERNAL_ERROR
	case .OutOfMemory:
		return ERR_OUT_OF_MEMORY
	}
	return ERR_INTERNAL_ERROR
}

caller_error_to_c :: proc(err: cl.CallerError) -> c.int {
	switch err {
	case .None:
		return ERR_OK
	case .InvalidConfig:
		return ERR_INVALID_ARGUMENT
	case .InvalidServiceId:
		return ERR_INVALID_SERVICE_ID
	case .Transport:
		return ERR_TRANSPORT
	case .AuthFailed:
		return ERR_AUTHENTICATION_FAILED
	case .ServiceNotFound:
		return ERR_SERVICE_NOT_FOUND
	case .Unauthorized:
		return ERR_UNAUTHORIZED
	case .AgentUnavailable:
		return ERR_AGENT_UNAVAILABLE
	case .QuotaExceeded:
		return ERR_QUOTA_EXCEEDED
	case .BrokerDraining:
		return ERR_BROKER_DRAINING
	case .Closed:
		return ERR_CLOSED
	case .Timeout:
		return ERR_TIMEOUT
	case .Internal:
		return ERR_INTERNAL_ERROR
	case .OutOfMemory:
		return ERR_OUT_OF_MEMORY
	case .RateLimited:
		return ERR_RATE_LIMITED
	case .LocalServiceUnavailable:
		return ERR_LOCAL_SERVICE_UNAVAILABLE
	}
	return ERR_INTERNAL_ERROR
}

conn_error_to_c :: proc(err: cl.ConnError) -> c.int {
	switch err {
	case .None:
		return ERR_OK
	case .Closed:
		return ERR_CLOSED
	case .Reset:
		return ERR_RESET
	case .Transport:
		return ERR_TRANSPORT
	case .Timeout:
		return ERR_TIMEOUT
	}
	return ERR_INTERNAL_ERROR
}
