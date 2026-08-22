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
