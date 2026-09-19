package transport

import win "core:sys/windows"
import "core:time"

tls_wait_socket_impl :: proc(conn: ^Connection, want_write: bool, timeout: time.Duration) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	pfd: win.WSA_POLLFD
	pfd.fd = win.SOCKET(conn.socket)
	pfd.events = i16(want_write ? win.POLLOUT : win.POLLIN)
	n := win.WSAPoll(&pfd, 1, tls_poll_timeout_ms(timeout))
	if n == 0 {
		return .Timeout
	}
	if n == win.SOCKET_ERROR {
		return .Network
	}
	if pfd.revents & i16(win.POLLNVAL) != 0 {
		conn.closed = true
		return .Closed
	}
	ready := want_write ? (pfd.revents & i16(win.POLLOUT) != 0) : (pfd.revents & i16(win.POLLIN) != 0)
	if ready {
		return .None
	}
	if pfd.revents & i16(win.POLLHUP) != 0 || pfd.revents & i16(win.POLLERR) != 0 {
		conn.closed = true
		return .Closed
	}
	return .None
}
