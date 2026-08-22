package web_ingress

import log "../logging"

ingress_log :: proc(server: ^IngressServer, level: log.LogLevel, event: string, fields: log.LogFields = {}) {
	if server == nil || server.logger == nil {
		return
	}
	log.log_event(server.logger, level, event, fields)
}

ingress_error_reason :: proc(err: IngressError) -> string {
	switch err {
	case .None:
		return ""
	case .InvalidConfiguration:
		return "invalid_configuration"
	case .InvalidPublicHost:
		return "invalid_public_host"
	case .DuplicateRoute:
		return "duplicate_route"
	case .UnknownRoute:
		return "unknown_route"
	case .TlsHandshakeFailed:
		return "tls_handshake_failed"
	case .ClientHelloTooLarge:
		return "client_hello_too_large"
	case .ClientHelloTimeout:
		return "client_hello_timeout"
	case .MalformedClientHello:
		return "malformed_client_hello"
	case .MissingSni:
		return "missing_sni"
	case .UnsupportedAlpn:
		return "unsupported_alpn"
	case .BrokerUnavailable:
		return "broker_unavailable"
	case .BrokerUnauthorized:
		return "broker_unauthorized"
	case .ServiceUnavailable:
		return "service_unavailable"
	case .RateLimited:
		return "rate_limited"
	case .QuotaExceeded:
		return "quota_exceeded"
	case .DialTimeout:
		return "dial_timeout"
	case .ConnectionIdle:
		return "connection_idle"
	case .BufferLimit:
		return "buffer_limit"
	case .Draining:
		return "draining"
	case .Internal:
		return "internal"
	}
	return "internal"
}
