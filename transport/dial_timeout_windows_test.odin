#+build windows
package transport

import "core:net"
import win "core:sys/windows"
import "core:testing"

// Winsock can refuse new connections when the accept queue fills. With
// conditional accept, the kernel leaves the handshake pending until the
// listener accepts it. This fixture never accepts.
dial_timeout_sink_listen :: proc(t: ^testing.T, sink: ^DialTimeoutSink) -> bool {
	if !testing.expect_value(t, net.set_option(sink.socket, .Conditional_Accept, true), net.Socket_Option_Error.None) {
		return false
	}
	return testing.expectf(t, win.listen(win.SOCKET(sink.socket), 8) == 0, "listen failed (%v)", win.WSAGetLastError())
}
