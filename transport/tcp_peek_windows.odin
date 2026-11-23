package transport

import "core:c"
import win "core:sys/windows"

// winsock2.h MSG_PEEK. core:sys/windows exports recv but not this flag.
MSG_PEEK :: 2

// A Winsock blocking recv that hits SO_RCVTIMEO can leave the socket in
// an indeterminate state. Wait without issuing a recv when there is no data.
@(private)
tcp_wait_receive :: proc(conn: ^Connection) -> TransportError {
	if conn.recv_timeout <= 0 {
		return .None
	}
	// Keep the injected interruption for the keepalive write poll. The
	// plaintext reader and the probe can wait on the same socket.
	err := tls_wait_socket_impl(conn, false, conn.recv_timeout)
	return .Timeout if err == .WouldBlock else err
}

connection_peek_impl :: proc(conn: ^Connection, dst: []u8) -> (n: int, err: TransportError) {
	if ready := tcp_wait_receive(conn); ready != .None {
		return 0, ready
	}
	to_read := min(len(dst), int(max(c.int)))
	got := win.recv(
		win.SOCKET(conn.socket),
		raw_data(dst),
		c.int(to_read),
		MSG_PEEK,
	)
	if got == win.SOCKET_ERROR {
		switch win.WSAGetLastError() {
		case win.WSAEWOULDBLOCK:
			return 0, .Timeout
		case win.WSAETIMEDOUT:
			if conn.recv_timeout <= 0 {
				return 0, .Timeout
			}
			conn.closed = true
			return 0, .Network
		case win.WSAECONNRESET, win.WSAENOTCONN, win.WSAESHUTDOWN:
			conn.closed = true
			return 0, .Closed
		}
		return 0, .Network
	}
	if got == 0 {
		// Peer FIN. Leave the socket writable; the response may still be owed.
		return 0, .Closed
	}
	return int(got), .None
}

// SO_RCVLOWAT is not a supported TCP option on Windows. The ClientHello
// inspection loop enforces its deadline while a partial hello is readable.
connection_set_recv_lowat_impl :: proc(conn: ^Connection, n: int) -> TransportError {
	_ = conn
	_ = n
	return .None
}

// closesocket used to abort a blocking recv/send on another thread. The fd is
// now released only after that thread leaves, so abort its pending IO
// explicitly; the handle stays valid until conn_release_fd.
connection_abort_io_impl :: proc(conn: ^Connection) {
	_ = win.CancelIoEx(win.HANDLE(uintptr(conn.socket)), nil)
}
