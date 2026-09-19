package main

import ag "../agent"
import "base:runtime"
import win "core:sys/windows"

global_agent: ^ag.Agent

agent_ctrl_handler :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	context = runtime.default_context()
	if ctrl_type == win.CTRL_C_EVENT || ctrl_type == win.CTRL_BREAK_EVENT || ctrl_type == win.CTRL_CLOSE_EVENT {
		if global_agent != nil {
			ag.agent_stop(global_agent)
		}
		return win.TRUE
	}
	return win.FALSE
}

agent_setup_interrupt :: proc(agent: ^ag.Agent) {
	global_agent = agent
	win.SetConsoleCtrlHandler(agent_ctrl_handler, win.TRUE)
}
