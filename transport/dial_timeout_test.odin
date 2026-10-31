package transport

import "core:testing"

@(test)
test_dial_timeout_zero_still_connects :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)
	conn, derr := connection_dial_timeout(ep, 0)
	testing.expect_value(t, derr, TransportError.None)
	if conn != nil {
		connection_destroy(conn)
	}
}
