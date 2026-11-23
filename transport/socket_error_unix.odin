#+build linux, darwin
package transport

import "core:c"
import "core:sys/posix"

socket_syscall_error :: proc() -> i32 {
	return i32(posix.get_errno())
}

socket_error_cause :: proc(code: i32) -> CloseCause {
	#partial switch posix.Errno(code) {
	case .ECONNRESET: return .PeerReset
	case .ETIMEDOUT:  return .ReadDeadline
	}
	return .NetworkError
}

socket_pending_error_cause :: proc(conn: ^Connection, fallback: CloseCause) -> CloseCause {
	code: c.int
	size := posix.socklen_t(size_of(code))
	if posix.getsockopt(posix.FD(connection_socket_fd(conn)), posix.SOL_SOCKET, .ERROR, &code, &size) != .OK {
		return .NetworkError
	}
	return fallback if code == 0 else socket_error_cause(i32(code))
}
