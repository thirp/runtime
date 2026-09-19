package main

import broker "../broker"
import trans "../transport"
import posix "core:sys/posix"
import "core:thread"

SignalWaiter :: struct {
	server: ^broker.Server,
	set:    posix.sigset_t,
}

signal_wait_proc :: proc(w: ^SignalWaiter) {
	sig: posix.Signal
	_ = posix.sigwait(&w.set, &sig)
	w.server.stop = true
	if w.server.listening {
		trans.listener_close(&w.server.listener)
		w.server.listening = false
	}
}

broker_setup_interrupt :: proc(server: ^broker.Server) {
	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	waiter := SignalWaiter {
		server = server,
		set    = set,
	}
	th := thread.create_and_start_with_poly_data(&waiter, signal_wait_proc)
	_ = th
}
