package transport

import "core:c"
import win "core:sys/windows"

// winsock2.h MSG_PEEK. core:sys/windows exports recv but not this flag.
MSG_PEEK :: 2

connection_peek_impl :: proc(conn: ^Connection, dst: []u8) -> (n: int, err: TransportError) {
	to_read := min(len(dst), int(max(c.int)))
	got := win.recv(
		win.SOCKET(conn.socket),
		raw_data(dst),
		c.int(to_read),
		MSG_PEEK,
	)
	if got == win.SOCKET_ERROR {
		switch win.WSAGetLastError() {
		case win.WSAEWOULDBLOCK, win.WSAETIMEDOUT:
			return 0, .Timeout
		case win.WSAECONNRESET, win.WSAENOTCONN, win.WSAESHUTDOWN:
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

// SO_RCVLOWAT is not a supported TCP option on Windows. Peek + SO_RCVTIMEO
// still bound ClientHello inspection; Incomplete loops until timeout.
connection_set_recv_lowat_impl :: proc(conn: ^Connection, n: int) -> TransportError {
	_ = conn
	_ = n
	return .None
}
