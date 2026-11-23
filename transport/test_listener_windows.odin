package transport

import "core:net"
import win "core:sys/windows"

when ODIN_TEST {
test_listener_listen :: proc(endpoint: net.Endpoint) -> (listener: Listener, err: TransportError) {
	// Other tests launch child processes with handle inheritance enabled.
	// Create the listener non-inheritable so a child cannot keep the origin
	// port listening after the accept thread has exited and we close it.
	family := win.AF_INET
	if _, ipv6 := endpoint.address.(net.IP6_Address); ipv6 {
		family = win.AF_INET6
	}
	fd := win.WSASocketW(
		family, win.SOCK_STREAM, win.IPPROTO_TCP, nil, 0,
		win.WSA_FLAG_OVERLAPPED | win.WSA_FLAG_NO_HANDLE_INHERIT,
	)
	if fd == win.INVALID_SOCKET {
		return {}, .Network
	}
	socket := net.TCP_Socket(fd)
	defer if err != .None {
		net.close(socket)
	}
	if net.set_option(socket, .Exclusive_Addr_Use, true) != .None ||
	   net.bind(socket, endpoint) != .None ||
	   win.listen(fd, 1000) == win.SOCKET_ERROR {
		return {}, .Network
	}
	return Listener{socket = socket}, .None
}
}
