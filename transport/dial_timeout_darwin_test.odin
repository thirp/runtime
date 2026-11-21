#+build darwin
package transport

import "core:sys/posix"
import "core:testing"

// XNU drops SYNs when the completed queue is full. Queue two handshakes
// with a backlog of two and shrink the backlog to one. Both clients stay
// open, including on kernels that permit an extra connection at the limit.
dial_timeout_sink_listen :: proc(t: ^testing.T, sink: ^DialTimeoutSink) -> bool {
	fd := posix.FD(sink.socket)
	// XNU disables SYN cookies on sockets bound to a loopback interface.
	IP_BOUND_IF :: posix.Sock_Option(25)
	loopback_if := posix.if_nametoindex("lo0")
	if !testing.expect(t, loopback_if != 0, "lo0 interface not found") {
		return false
	}
	if posix.setsockopt(fd, posix.IPPROTO_IP, IP_BOUND_IF, &loopback_if, size_of(loopback_if)) != .OK {
		return testing.expectf(t, false, "IP_BOUND_IF failed (%v)", posix.errno())
	}
	if !testing.expectf(t, posix.listen(fd, 2) == .OK, "initial listen failed (%v)", posix.errno()) {
		return false
	}
	if !dial_timeout_fill_queue(t, sink, 2) {
		return false
	}
	return testing.expectf(t, posix.listen(fd, 1) == .OK, "reducing listen backlog failed (%v)", posix.errno())
}
