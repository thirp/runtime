package transport

import win "core:sys/windows"

when ODIN_TEST {
	// Capture Winsock's error before calling another OS or logging routine.
	tcp_trace_native_error :: proc() -> int {
		return int(win.WSAGetLastError())
	}
}
