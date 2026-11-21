#+build linux
package transport

import "core:sys/linux"
import "core:testing"

// One completed handshake fills Linux's zero-backlog queue. Further SYNs
// are dropped. net.listen_tcp rejects a backlog of 0.
dial_timeout_sink_listen :: proc(t: ^testing.T, sink: ^DialTimeoutSink) -> bool {
	if !testing.expect_value(t, linux.listen(linux.Fd(sink.socket), 0), linux.Errno.NONE) {
		return false
	}
	return dial_timeout_fill_queue(t, sink, 1)
}
