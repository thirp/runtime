#+build linux
package transport

import "core:net"
import "core:sys/linux"

// core:net's Linux accept does not request CLOEXEC. Set it atomically at
// accept, rather than with a later fcntl: another thread may fork/exec in
// between. An inherited socket delays EOF until the unrelated child exits.
@(private)
listener_accept_cloexec :: proc(sock: net.TCP_Socket) -> (net.TCP_Socket, net.Endpoint, net.Accept_Error) {
	addr: linux.Sock_Addr_Any
	fd, errno := linux.accept(linux.Fd(sock), &addr, {.CLOEXEC})
	if errno != .NONE {
		// Preserve listener_accept's transport error classifications. Every
		// other accept error maps to Network there, as with net.accept_tcp.
		#partial switch errno {
		case .EWOULDBLOCK:
			return {}, {}, .Would_Block
		case .EINTR:
			return {}, {}, .Interrupted
		case:
			return {}, {}, .Unknown
		}
	}
	no_delay: b32 = b32(net.DEFAULT_TCP_OPTIONS.no_delay)
	_ = linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.NODELAY, &no_delay)
	source: net.Endpoint
	#partial switch addr.family {
	case .INET:
		source = {address = net.IP4_Address(addr.sin_addr), port = int(addr.sin_port)}
	case .INET6:
		source = {address = transmute(net.IP6_Address)addr.sin6_addr, port = int(addr.sin6_port)}
	case:
		linux.close(fd)
		return {}, {}, .Unknown
	}
	return net.TCP_Socket(fd), source, nil
}
