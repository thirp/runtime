#+build linux
package transport

import "core:net"
import "core:sys/linux"
import "core:testing"
import "core:time"

// listen backlog 0 plus one completed handshake fills the accept queue.
// Further SYNs are dropped. net.listen_tcp rejects a backlog of 0.
listen_drop_syn :: proc() -> (sock: net.TCP_Socket, ep: net.Endpoint, err: TransportError) {
	fd, serr := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if serr != .NONE {
		return {}, {}, .Network
	}
	reuse: b32 = true
	_ = linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &reuse)
	addr := linux.Sock_Addr_Any {
		ipv4 = {sin_family = .INET, sin_port = 0, sin_addr = {127, 0, 0, 1}},
	}
	if linux.bind(fd, &addr) != .NONE {
		_ = linux.close(fd)
		return {}, {}, .Network
	}
	if linux.listen(fd, 0) != .NONE {
		_ = linux.close(fd)
		return {}, {}, .Network
	}
	sock = net.TCP_Socket(net.Socket(fd))
	berr: net.Network_Error
	ep, berr = net.bound_endpoint(sock)
	if berr != nil {
		net.close(sock)
		return {}, {}, .Network
	}
	return sock, ep, .None
}

@(test)
test_dial_timeout_bounds_syn_retries :: proc(t: ^testing.T) {
	sock, ep, lerr := listen_drop_syn()
	testing.expect(t, lerr == .None, "listen")
	if lerr != .None {
		return
	}
	defer net.close(sock)
	filler, ferr := net.dial_tcp(ep)
	testing.expect(t, ferr == nil, "filler dial")
	if ferr != nil {
		return
	}
	defer net.close(filler)

	start := time.now()
	conn, derr := connection_dial_timeout(ep, 400 * time.Millisecond)
	elapsed := time.since(start)
	if conn != nil {
		connection_destroy(conn)
	}
	testing.expect_value(t, derr, TransportError.Timeout)
	testing.expect(t, elapsed < 2 * time.Second, "dial waited on SYN retries")
	testing.expect(t, elapsed >= 300 * time.Millisecond, "dial returned before the timeout")
}
