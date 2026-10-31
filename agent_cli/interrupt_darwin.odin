package main

import ag "../agent"
import posix "core:sys/posix"
import "core:sync"
import "core:thread"

// Process lifetime. See interrupt_linux.odin: a stack waiter dies when
// agent_setup_interrupt returns, and the signal thread then reads garbage.
AgentSignalWaiter :: struct {
	set:     posix.sigset_t,
	agent:   ^ag.Agent,
	tid:     posix.pthread_t,
	ready:   bool,
	handled: bool,
}

g_agent_waiter: AgentSignalWaiter
g_agent_signal_thread: ^thread.Thread

agent_signal_wait :: proc(w: ^AgentSignalWaiter) {
	w.tid = posix.pthread_self()
	sync.atomic_store(&w.ready, true)
	sig: posix.Signal
	_ = posix.sigwait(&w.set, &sig)
	if w.agent != nil {
		ag.agent_stop(w.agent)
	}
	sync.atomic_store(&w.handled, true)
}

agent_setup_interrupt :: proc(agent: ^ag.Agent) {
	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	g_agent_waiter = AgentSignalWaiter {
		set   = set,
		agent = agent,
	}
	g_agent_signal_thread = thread.create_and_start_with_poly_data(&g_agent_waiter, agent_signal_wait)
}
