package transport

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
		return .WouldBlock if posix.get_errno() == .EINTR else .Network
	}
	if .NVAL in pfd.revents {
		connection_note_close(conn, .NetworkError)
		conn.closed = true
		return .Closed
	}
	ready := want_write ? (.OUT in pfd.revents) : (.IN in pfd.revents)
	if ready {
		return .None
	}
	socket_error := .ERR in pfd.revents
	if .HUP in pfd.revents || socket_error {
		// HUP is the peer's FIN with nothing left to read. ERR is a dead socket.
		connection_note_close(conn, socket_pending_error_cause(conn, .NetworkError if socket_error else .PeerEOF))
		if socket_error {
			conn.closed = true
		}
		return .Closed
	}
	return .None
}
