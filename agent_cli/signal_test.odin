#+build !windows
package main

import ag "../agent"
import posix "core:sys/posix"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

signal_clobber_sink: int

// Overwrite the stack frame agent_setup_interrupt returned from. A waiter
// that lived there is no longer a coherent sigset or agent pointer.
signal_stack_clobber :: proc(depth: int) {
	buf: [8192]byte
	for &b, i in buf {
		b = byte(depth + i)
	}
	signal_clobber_sink += int(buf[0]) + int(buf[len(buf) - 1])
	if depth > 0 {
		signal_stack_clobber(depth - 1)
	}
}

@(test)
test_sigterm_stops_agent_after_setup_returns :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		return
	}
	agent: ag.Agent
	agent_setup_interrupt(&agent)
	defer {
		if !sync.atomic_load(&g_agent_waiter.handled) {
			if sync.atomic_load(&g_agent_waiter.ready) {
				_ = posix.pthread_kill(g_agent_waiter.tid, .SIGTERM)
			}
			again := time.now()
			for !sync.atomic_load(&g_agent_waiter.handled) && time.since(again) < 1 * time.Second {
				time.sleep(1 * time.Millisecond)
			}
		}
		if sync.atomic_load(&g_agent_waiter.handled) && g_agent_signal_thread != nil {
			thread.join(g_agent_signal_thread)
			thread.destroy(g_agent_signal_thread)
			g_agent_signal_thread = nil
		} else if g_agent_signal_thread != nil {
			testing.expect(t, false, "signal thread did not exit")
		}
		set: posix.sigset_t
		posix.sigemptyset(&set)
		posix.sigaddset(&set, .SIGINT)
		posix.sigaddset(&set, .SIGTERM)
		posix.pthread_sigmask(.UNBLOCK, &set, nil)
	}

	ready_at := time.now()
	for !sync.atomic_load(&g_agent_waiter.ready) {
		if time.since(ready_at) > 1 * time.Second {
			testing.expect(t, false, "signal thread did not publish itself")
			return
		}
		time.sleep(1 * time.Millisecond)
	}
	tid := g_agent_waiter.tid
	signal_stack_clobber(8)
	err := posix.pthread_kill(tid, .SIGTERM)
	testing.expect(t, err == nil, "pthread_kill")

	deadline := time.now()
	for !sync.atomic_load(&g_agent_waiter.handled) {
		if time.since(deadline) > 1 * time.Second {
			testing.expect(t, false, "SIGTERM did not run the agent waiter")
			return
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&agent.stop), "SIGTERM did not stop the agent")
}
