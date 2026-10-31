package protocol

ProtocolError :: enum {
	None,
	Truncated,
	FrameTooLarge,
	InvalidVersion,
	InvalidOpcode,
	InvalidFlags,
	InvalidPayload,
	InvalidStreamId,
	InvalidServiceId,
	InvalidUtf8,
	BufferFull,
	OutOfMemory,
}

ServiceIdError :: enum {
	None,
	Empty,
	TooLong,
	InvalidCharacter,
}

// WireError is the numeric protocol error code. None is wire OK (0).
// Programs must branch on the numeric code, not diagnostic text.
WireError :: enum u16 {
	None                      = 0,
	ProtocolError             = 1,
	UnsupportedVersion        = 2,
	AuthenticationFailed      = 3,
	Unauthorized              = 4,
	InvalidServiceId          = 5,
	ServiceNotFound           = 6,
	ServiceAlreadyRegistered  = 7,
	AgentUnavailable          = 8,
	LocalServiceUnavailable   = 9,
	QuotaExceeded             = 10,
	RateLimited               = 11,
	StreamNotFound            = 12,
	StreamAlreadyExists       = 13,
	FrameTooLarge             = 14,
	Timeout                   = 15,
	BrokerDraining            = 16,
	InternalError             = 17,
}

wire_error_to_u16 :: proc(err: WireError) -> u16 {
	return u16(err)
}

wire_error_from_u16 :: proc(value: u16) -> (WireError, bool) {
	switch value {
	case u16(WireError.None) ..= u16(WireError.InternalError):
		return WireError(value), true
	}
	return {}, false
}

// Diagnostic name for logs. Call sites use this instead of the wire string.
wire_error_name :: proc(err: WireError) -> string {
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
