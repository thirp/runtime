package transport

import "core:net"
import "core:time"
import win "core:sys/windows"

dial_connect_other :: proc(sock: net.TCP_Socket, ep: net.Endpoint, timeout: time.Duration) -> TransportError {
		addr: win.SOCKADDR_STORAGE_LH
		switch a in ep.address {
		case net.IP4_Address:
			(^win.sockaddr_in)(&addr)^ = {sin_family = u16(win.AF_INET), sin_port = u16be(ep.port), sin_addr = transmute(win.in_addr)a}
		case net.IP6_Address:
			(^win.sockaddr_in6)(&addr)^ = {sin6_family = u16(win.AF_INET6), sin6_port = u16be(ep.port), sin6_addr = transmute(win.in6_addr)a}
		}
		fd := win.SOCKET(sock)
		if win.connect(fd, &addr, size_of(addr)) == 0 {return .None}
		e := win.WSAGetLastError()
		if e != win.WSAEWOULDBLOCK && e != win.WSAEINPROGRESS {return e == win.WSAETIMEDOUT ? .Timeout : .Network}
		deadline := time.time_add(time.now(), timeout)
		for {
			left := time.diff(time.now(), deadline)
			if left <= 0 {return .Timeout}
			pfd := win.WSA_POLLFD{fd = fd, events = i16(win.POLLOUT)}
			n := win.WSAPoll(&pfd, 1, max(1, tls_poll_timeout_ms(left)))
			if n == win.SOCKET_ERROR && win.WSAGetLastError() == win.WSAEINTR {continue}
			if n == win.SOCKET_ERROR {return .Network}
			if n == 0 {return .Timeout}
			soerr: i32
			length := i32(size_of(soerr))
			if win.getsockopt(fd, win.SOL_SOCKET, win.SO_ERROR, ([^]u8)(&soerr), &length) != 0 {return .Network}
			if soerr == 0 {return .None}
			return soerr == win.WSAETIMEDOUT ? .Timeout : .Network
		}
}
