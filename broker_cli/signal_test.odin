package main

import broker "../broker"
import posix "core:sys/posix"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

broker_signal_clobber_sink: int

broker_signal_stack_clobber :: proc(depth: int) {
	buf: [8192]byte
	for &b, i in buf {
		b = byte(depth + i)
	}
	broker_signal_clobber_sink += int(buf[0]) + int(buf[len(buf) - 1])
	if depth > 0 {
		broker_signal_stack_clobber(depth - 1)
	}
}

@(test)
test_sigterm_stops_broker_after_setup_returns :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		return
	}
	server: broker.Server
	broker_setup_interrupt(&server)
	defer {
		if !sync.atomic_load(&g_broker_waiter.handled) {
			if sync.atomic_load(&g_broker_waiter.ready) {
				_ = posix.pthread_kill(g_broker_waiter.tid, .SIGTERM)
			}
			again := time.now()
			for !sync.atomic_load(&g_broker_waiter.handled) && time.since(again) < 1 * time.Second {
				time.sleep(1 * time.Millisecond)
			}
		}
		if sync.atomic_load(&g_broker_waiter.handled) && g_broker_signal_thread != nil {
			thread.join(g_broker_signal_thread)
			thread.destroy(g_broker_signal_thread)
			g_broker_signal_thread = nil
		} else if g_broker_signal_thread != nil {
			testing.expect(t, false, "signal thread did not exit")
		}
		set: posix.sigset_t
		posix.sigemptyset(&set)
		posix.sigaddset(&set, .SIGINT)
		posix.sigaddset(&set, .SIGTERM)
		posix.pthread_sigmask(.UNBLOCK, &set, nil)
	}

	ready_at := time.now()
	for !sync.atomic_load(&g_broker_waiter.ready) {
		if time.since(ready_at) > 1 * time.Second {
			testing.expect(t, false, "signal thread did not publish itself")
			return
		}
		time.sleep(1 * time.Millisecond)
	}
	tid := g_broker_waiter.tid
	broker_signal_stack_clobber(8)
	err := posix.pthread_kill(tid, .SIGTERM)
	testing.expect(t, err == nil, "pthread_kill")

	deadline := time.now()
	for !sync.atomic_load(&g_broker_waiter.handled) {
		if time.since(deadline) > 1 * time.Second {
			testing.expect(t, false, "SIGTERM did not run the broker waiter")
			return
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, server.stop, "SIGTERM did not stop the broker")
}
