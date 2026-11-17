package connect

import trans "../../transport"
import "core:net"
import "core:time"

// Only for sockets owned exclusively by a test, after its IO assertions and
// writer joins. Never use this on a product-owned caller/agent/broker socket.
// Setting linger here (not at dial/accept) leaves shutdown_write and clean EOF
// observable throughout the test. Windows' zero-duration Linger sets both
// l_onoff=1 and l_linger=0; closing then releases the test endpoint without
// retaining TIME_WAIT. Other platforms keep their original close behaviour.
connect_test_connection_destroy :: proc(conn: ^trans.Connection) {
	when ODIN_OS == .Windows {
		if conn != nil && conn.socket != 0 {
			err := net.set_option(conn.socket, .Linger, time.Duration(0))
			assert(err == .None, "test socket SO_LINGER failed")
		}
	}
	trans.connection_destroy(conn)
}
