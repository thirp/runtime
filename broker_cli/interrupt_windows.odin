package main

import broker "../broker"
import trans "../transport"
import "base:runtime"
import win "core:sys/windows"

global_server: ^broker.Server

broker_ctrl_handler :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	context = runtime.default_context()
	if ctrl_type == win.CTRL_C_EVENT || ctrl_type == win.CTRL_BREAK_EVENT || ctrl_type == win.CTRL_CLOSE_EVENT {
		if global_server != nil {
			global_server.stop = true
			if global_server.listening {
				trans.listener_close(&global_server.listener)
				global_server.listening = false
			}
		}
		return win.TRUE
	}
	return win.FALSE
}

broker_setup_interrupt :: proc(server: ^broker.Server) {
	global_server = server
	win.SetConsoleCtrlHandler(broker_ctrl_handler, win.TRUE)
}
