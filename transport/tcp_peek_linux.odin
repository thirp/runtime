package transport

import "core:c"
import "core:sys/posix"

connection_peek_impl :: proc(conn: ^Connection, dst: []u8) -> (n: int, err: TransportError) {
	got := posix.recv(
		posix.FD(connection_socket_fd(conn)),
		raw_data(dst),
		c.size_t(len(dst)),
		{.PEEK},
	)
	if got < 0 {
		#partial switch posix.get_errno() {
		case .EAGAIN, .ETIMEDOUT:
			return 0, .Timeout
		case .ECONNRESET, .ENOTCONN, .EPIPE:
			conn.closed = true
			return 0, .Closed
		}
		return 0, .Network
	}
	if got == 0 {
		conn.closed = true
		return 0, .Closed
	}
	return int(got), .None
}

connection_set_recv_lowat_impl :: proc(conn: ^Connection, n: int) -> TransportError {
	val: c.int = 1
	if n > 1 {
		val = c.int(n)
	}
	rc := posix.setsockopt(
		posix.FD(connection_socket_fd(conn)),
		posix.SOL_SOCKET,
		.RCVLOWAT,
		&val,
		posix.socklen_t(size_of(val)),
	)
	if rc != .OK {
		return .Network
	}
	return .None
}
