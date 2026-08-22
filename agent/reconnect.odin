package agent

import proto "../protocol"
import trans "../transport"
import "core:time"

reconnect_backoff :: proc(attempt: int) -> time.Duration {
	n := attempt
	if n < 0 {
		n = 0
	}
	ms: i64 = 250
	for i in 0 ..< n {
		if ms >= 15000 {
			ms = 15000
			break
		}
		next := ms * 2
		if next > 15000 || next < ms {
			ms = 15000
			break
		}
		ms = next
	}
	if ms > 15000 {
		ms = 15000
	}
	return time.Duration(ms) * time.Millisecond
}

reconnect_delay :: proc(attempt: int, jitter: u64) -> time.Duration {
	d := reconnect_backoff(attempt)
	if d > RECONNECT_MAX {
		d = RECONNECT_MAX
	}
	half := d / 2
	if half <= 0 {
		return d
	}
	span := u64(half)
	j := time.Duration(jitter % (span + 1))
	return half + j
}

classify_dial_error :: proc(err: trans.TransportError) -> ReconnectClass {
	switch err {
	case .None:
		return .None
	case .Tls:
		return .Tls
	case .InvalidEndpoint:
		return .Configuration
	case .Network, .Closed:
		return .Network
	case .Timeout, .WouldBlock, .OutOfMemory:
		return .BrokerUnavailable
	}
	return .BrokerUnavailable
}

classify_handshake :: proc(hs: HandshakeResult) -> ReconnectClass {
	switch hs {
	case .Ok:
		return .None
	case .AuthFailed:
		return .Authentication
	case .Unauthorized:
		return .Authorization
	case .DuplicateRegistration:
		return .DuplicateRegistration
	case .Tls:
		return .Tls
	case .Network:
		return .Network
	case .Stopped:
		return .None
	case .Configuration:
		return .Configuration
	case .RateLimited:
		return .RateLimited
	case .RegisterFailed, .Transport:
		return .BrokerUnavailable
	}
	return .BrokerUnavailable
}

reconnect_class_reason :: proc(class: ReconnectClass) -> string {
	switch class {
	case .None:
		return ""
	case .Network:
		return "network"
	case .BrokerUnavailable:
		return "broker_unavailable"
	case .Tls:
		return "tls"
	case .Authentication:
		return "authentication"
	case .Authorization:
		return "authorization"
	case .DuplicateRegistration:
		return "duplicate_registration"
	case .Configuration:
		return "configuration"
	case .Disconnected:
		return "disconnected"
	case .RateLimited:
		return "rate_limited"
	}
	return ""
}

reconnect_class_is_permanent :: proc(class: ReconnectClass) -> bool {
	return class == .Authentication || class == .Authorization || class == .Configuration
}

handshake_from_register_failed :: proc(payload: []u8) -> HandshakeResult {
	fail, _ := proto.decode_wire_failure(payload)
	code, ok := proto.wire_error_from_u16(fail.code)
	delete(fail.diagnostic)
	if !ok {
		return .RegisterFailed
	}
	switch code {
	case .Unauthorized:
		return .Unauthorized
	case .ServiceAlreadyRegistered:
		return .DuplicateRegistration
	case .InvalidServiceId:
		return .Configuration
	case .AuthenticationFailed:
		return .AuthFailed
	case .RateLimited:
		return .RateLimited
	case .None, .ProtocolError, .UnsupportedVersion, .ServiceNotFound,
	     .AgentUnavailable, .LocalServiceUnavailable, .QuotaExceeded,
	     .StreamNotFound, .StreamAlreadyExists, .FrameTooLarge, .Timeout,
	     .BrokerDraining, .InternalError:
		return .RegisterFailed
	}
	return .RegisterFailed
}
