#+build linux
package caller

import "core:net"
import "core:sys/linux"
import "core:testing"

// Accept queue of 0 with one completed handshake. The next SYN is dropped,
// so the agent's local dial hits its timeout instead of a fast RST.
// net.listen_tcp rejects a backlog of 0, so this stays a test helper.
SynSink :: struct {
	sock:   net.TCP_Socket,
	filler: net.TCP_Socket,
	ep:     net.Endpoint,
}

syn_sink_listen :: proc() -> (sock: net.TCP_Socket, ep: net.Endpoint, ok: bool) {
	fd, serr := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if serr != .NONE {
		return {}, {}, false
	}
	reuse: b32 = true
	_ = linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &reuse)
	addr := linux.Sock_Addr_Any {
		ipv4 = {sin_family = .INET, sin_port = 0, sin_addr = {127, 0, 0, 1}},
	}
	if linux.bind(fd, &addr) != .NONE {
		_ = linux.close(fd)
		return {}, {}, false
	}
	if linux.listen(fd, 0) != .NONE {
		_ = linux.close(fd)
		return {}, {}, false
	}
	sock = net.TCP_Socket(net.Socket(fd))
	berr: net.Network_Error
	ep, berr = net.bound_endpoint(sock)
	if berr != nil {
		net.close(sock)
		return {}, {}, false
	}
	return sock, ep, true
}

syn_sink_start :: proc(t: ^testing.T) -> SynSink {
	sock, ep, ok := syn_sink_listen()
	testing.expect(t, ok, "syn sink listen")
	if !ok {
		return {}
	}
	filler, ferr := net.dial_tcp(ep)
	testing.expect(t, ferr == nil, "syn sink filler")
	if ferr != nil {
		net.close(sock)
		return {}
	}
	return SynSink{sock = sock, filler = filler, ep = ep}
}

syn_sink_stop :: proc(s: ^SynSink) {
	if s == nil {
		return
	}
	if s.filler != 0 {
		net.close(s.filler)
		s.filler = 0
	}
	if s.sock != 0 {
		net.close(s.sock)
		s.sock = 0
	}
}
