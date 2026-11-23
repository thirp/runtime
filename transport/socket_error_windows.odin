package transport

import "core:c"
import win "core:sys/windows"

socket_syscall_error :: proc() -> i32 {
	return win.WSAGetLastError()
}

socket_error_cause :: proc(code: i32) -> CloseCause {
	#partial switch win.System_Error(code) {
	case .WSAECONNRESET: return .PeerReset
	case .WSAENETRESET, .WSAETIMEDOUT: return .ReadDeadline
	}
	return .NetworkError
}

socket_pending_error_cause :: proc(conn: ^Connection, fallback: CloseCause) -> CloseCause {
	code: c.int
	size := c.int(size_of(code))
	if win.getsockopt(win.SOCKET(conn.socket), win.SOL_SOCKET, win.SO_ERROR, cast([^]c.char)&code, &size) != 0 {
		return .NetworkError
	}
	return fallback if code == 0 else socket_error_cause(i32(code))
}
