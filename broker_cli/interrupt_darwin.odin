package main

import broker "../broker"
import trans "../transport"
import posix "core:sys/posix"
import "core:sync"
import "core:thread"

// Process lifetime. See interrupt_linux.odin.
SignalWaiter :: struct {
	server:  ^broker.Server,
	set:     posix.sigset_t,
	tid:     posix.pthread_t,
	ready:   bool,
	handled: bool,
}

g_broker_waiter: SignalWaiter
g_broker_signal_thread: ^thread.Thread

signal_wait_proc :: proc(w: ^SignalWaiter) {
	w.tid = posix.pthread_self()
	sync.atomic_store(&w.ready, true)
	sig: posix.Signal
	_ = posix.sigwait(&w.set, &sig)
	if w.server != nil {
		w.server.stop = true
		if w.server.listening {
			trans.listener_close(&w.server.listener)
			w.server.listening = false
		}
	}
	sync.atomic_store(&w.handled, true)
}

broker_setup_interrupt :: proc(server: ^broker.Server) {
	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	g_broker_waiter = SignalWaiter {
		server = server,
		set    = set,
	}
	g_broker_signal_thread = thread.create_and_start_with_poly_data(&g_broker_waiter, signal_wait_proc)
}
