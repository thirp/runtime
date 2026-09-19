package main

import ag "../agent"
import posix "core:sys/posix"
import "core:thread"

AgentSignalWaiter :: struct {
	set:   posix.sigset_t,
	agent: ^ag.Agent,
}

agent_signal_wait :: proc(w: ^AgentSignalWaiter) {
	sig: posix.Signal
	_ = posix.sigwait(&w.set, &sig)
	ag.agent_stop(w.agent)
}

agent_setup_interrupt :: proc(agent: ^ag.Agent) {
	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	waiter := AgentSignalWaiter{set = set, agent = agent}
	_ = thread.create_and_start_with_poly_data(&waiter, agent_signal_wait)
}
