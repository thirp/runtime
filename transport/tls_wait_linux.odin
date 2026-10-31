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
		// HUP is the peer's FIN with nothing left to read. ERR is a dead socket.
		// ETIMEDOUT is TCP_USER_TIMEOUT, not a peer FIN.
		if .ERR in pfd.revents {
			if connection_so_error_timed_out(conn) {
				conn.user_timed_out = true
			}
			conn.closed = true
		}
		return .Closed
	}
	return .None
}

connection_syscall_timed_out :: proc() -> bool {
	return posix.get_errno() == .ETIMEDOUT
}

connection_so_error_timed_out :: proc(conn: ^Connection) -> bool {
	soerr: c.int
	olen := posix.socklen_t(size_of(soerr))
	rc := posix.getsockopt(
		posix.FD(connection_socket_fd(conn)),
		posix.SOL_SOCKET,
		.ERROR,
		&soerr,
		&olen,
	)
	if rc != .OK {
		return false
	}
	return posix.Errno(soerr) == .ETIMEDOUT
}
