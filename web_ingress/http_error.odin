package web_ingress

import cl "../caller"
import trans "../transport"
import "core:fmt"

HTTP_ERROR_CONTENT_TYPE :: "text/plain; charset=utf-8"

HttpErrorStatus :: struct {
	code:   int,
	reason: string,
}

http_status_misdirected :: proc() -> HttpErrorStatus {
	return HttpErrorStatus{code = 421, reason = "Misdirected Request"}
}

http_status_forbidden :: proc() -> HttpErrorStatus {
	return HttpErrorStatus{code = 403, reason = "Forbidden"}
}

http_status_too_many_requests :: proc() -> HttpErrorStatus {
	return HttpErrorStatus{code = 429, reason = "Too Many Requests"}
}

http_status_service_unavailable :: proc() -> HttpErrorStatus {
	return HttpErrorStatus{code = 503, reason = "Service Unavailable"}
}

http_status_bad_gateway :: proc() -> HttpErrorStatus {
	return HttpErrorStatus{code = 502, reason = "Bad Gateway"}
}

http_status_for_ingress_error :: proc(err: IngressError) -> HttpErrorStatus {
	switch err {
	case .UnknownRoute, .MissingSni, .InvalidPublicHost:
		return http_status_misdirected()
	case .BrokerUnauthorized:
		return http_status_forbidden()
	case .RateLimited:
		return http_status_too_many_requests()
	case .ServiceUnavailable, .QuotaExceeded, .Draining:
		return http_status_service_unavailable()
	case .None, .InvalidConfiguration, .DuplicateRoute, .TlsHandshakeFailed,
	     .ClientHelloTooLarge, .ClientHelloTimeout, .MalformedClientHello,
	     .UnsupportedAlpn, .BrokerUnavailable, .DialTimeout, .ConnectionIdle,
	     .BufferLimit, .Internal:
		return http_status_bad_gateway()
	}
	return http_status_bad_gateway()
}

http_status_for_caller_error :: proc(err: cl.CallerError) -> HttpErrorStatus {
	switch err {
	case .Unauthorized:
		return http_status_forbidden()
	case .RateLimited:
		return http_status_too_many_requests()
	case .BrokerDraining, .ServiceNotFound, .AgentUnavailable,
	     .LocalServiceUnavailable, .QuotaExceeded:
		return http_status_service_unavailable()
	case .None, .InvalidConfig, .InvalidServiceId, .Transport, .AuthFailed,
	     .Closed, .Timeout, .Internal, .OutOfMemory:
		return http_status_bad_gateway()
	}
	return http_status_bad_gateway()
}

format_http_error :: proc(status: HttpErrorStatus, allocator := context.allocator) -> string {
	body_len := len(status.reason) + 1
	return fmt.aprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s\n",
		status.code,
		status.reason,
		HTTP_ERROR_CONTENT_TYPE,
		body_len,
		status.reason,
		allocator = allocator,
	)
}

write_http_error :: proc(conn: ^trans.Connection, status: HttpErrorStatus) -> trans.TransportError {
	text := format_http_error(status)
	defer delete(text)
	err := trans.connection_write(conn, transmute([]u8)text)
	if err == .None {
		// Request bytes are still in the socket. close() with unread data is RST
		// and the peer can lose the error response. SHUT_RDWR discards them.
		trans.connection_shutdown_both(conn)
	}
	return err
}
