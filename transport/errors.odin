package transport

import "core:sync"

TransportError :: enum {
	None,
	Closed,
	Timeout,
	WouldBlock,
	InvalidEndpoint,
	OutOfMemory,
	Network,
	Tls,
}

// CloseCause describes a terminal observation. TransportError continues to
// drive IO control flow, including polling and write-after-EOF.
CloseCause :: enum {
	None,
	PeerEOF,
	PeerReset,
	TLSAlert,
	TLSError,
	ReadDeadline,
	ReadIdle,
	KeepaliveMiss,
	LocalClose,
	BrokerDrain,
	BrokerShutdown,
	BrokerCredentialRevoked,
	ProtocolError,
	BrokerError,
	InternalError,
	NetworkError,
}

close_cause_label :: proc(cause: CloseCause) -> string {
	switch cause {
	case .None:                    return "unknown"
	case .PeerEOF:                 return "peer_eof"
	case .PeerReset:               return "peer_reset"
	case .TLSAlert:                return "tls_alert"
	case .TLSError:                return "tls_error"
	case .ReadDeadline, .ReadIdle: return "read_deadline"
	case .KeepaliveMiss:           return "keepalive_miss"
	case .LocalClose:              return "local_close"
	case .BrokerDrain:             return "broker_drain"
	case .BrokerShutdown:          return "broker_shutdown"
	case .BrokerCredentialRevoked: return "broker_credential_revoked"
	case .ProtocolError:           return "protocol_error"
	case .BrokerError:             return "broker_error"
	case .InternalError:           return "internal_error"
	case .NetworkError:            return "network_error"
	}
	return "unknown"
}

// Record the first cause before waking other IO, so teardown cannot replace
// a transport failure with the local close it triggered.
connection_note_close :: proc(conn: ^Connection, cause: CloseCause) {
	_ = sync.atomic_compare_exchange_strong(&conn.close_cause, CloseCause.None, cause)
}

connection_close_cause :: proc(conn: ^Connection, fallback: CloseCause = .None) -> CloseCause {
	cause := sync.atomic_load(&conn.close_cause)
	return fallback if cause == .None else cause
}
