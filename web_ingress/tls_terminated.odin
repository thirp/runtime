package web_ingress

import trans "../transport"
import "core:time"

ingress_tls_accept :: proc(
	conn: ^trans.Connection,
	ctx: ^trans.TlsServerContext,
	timeout: time.Duration,
) -> IngressError {
	herr := trans.connection_tls_accept(conn, ctx, timeout)
	if herr == .Timeout {
		return .ClientHelloTimeout
	}
	if herr != .None {
		return .TlsHandshakeFailed
	}
	return .None
}

ingress_sni_public_host :: proc(
	conn: ^trans.Connection,
	allocator := context.allocator,
) -> (
	PublicHost,
	IngressError,
) {
	raw := trans.connection_tls_servername(conn)
	if len(raw) == 0 {
		return {}, .MissingSni
	}
	host, err := make_public_host(raw, allocator)
	if err != .None {
		return {}, public_host_error_to_ingress(err)
	}
	return host, .None
}
