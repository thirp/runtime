package transport

import "core:c"
import "core:sys/posix"
import "core:time"

tls_wait_socket_impl :: proc(conn: ^Connection, want_write: bool, timeout: time.Duration) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	pfd: posix.pollfd
	pfd.fd = posix.FD(connection_socket_fd(conn))
	pfd.events = want_write ? {.OUT} : {.IN}
	n := posix.poll(&pfd, 1, tls_poll_timeout_ms(timeout))
	if n == 0 {
		return .Timeout
	}
	if n < 0 {
		return .Network
	}
	if .NVAL in pfd.revents {
		conn.closed = true
		return .Closed
	}
	ready := want_write ? (.OUT in pfd.revents) : (.IN in pfd.revents)
	if ready {
		return .None
	}
	if .HUP in pfd.revents || .ERR in pfd.revents {
		conn.closed = true
		return .Closed
	}
	return .None
}
