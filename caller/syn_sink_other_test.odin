#+build !linux
package caller

import "core:net"
import "core:testing"

SynSink :: struct {
	sock:   net.TCP_Socket,
	filler: net.TCP_Socket,
	ep:     net.Endpoint,
}

syn_sink_start :: proc(t: ^testing.T) -> SynSink {
	testing.expect(t, false, "SYN blackhole is linux-only")
	return {}
}

syn_sink_stop :: proc(s: ^SynSink) {}
