#+build linux
package caller

import trans "../transport"
import "core:sys/linux"

// Abort a broker socket whose transmitted bytes stay unacknowledged. The
// first unacked Ping plus this timeout is ETIMEDOUT, logged dead_peer.
// A socket with nothing outstanding is not aborted; that case is the
// read-idle watchdog. This is also a backstop behind the send-stall timer.
caller_set_user_timeout :: proc(conn: ^trans.Connection) {
	if conn == nil {
		return
	}
	ms := u32(i64(TCP_USER_TIMEOUT) / 1_000_000)
	fd := linux.Fd(trans.connection_socket_fd(conn))
	_ = linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.USER_TIMEOUT, &ms)
}
