package agent

import trans "../transport"
import "base:runtime"
import "core:sync"
import "core:time"

@(private)
test_hold_mu: sync.Mutex

@(private)
test_hold: map[^Agent]bool

// Stop the relay from reading the broker. The TCP window then fills and
// the broker stops reading callers of this agent. Test builds only.
agent_test_hold_relay :: proc(agent: ^Agent, hold: bool) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&test_hold_mu)
	defer sync.mutex_unlock(&test_hold_mu)
	if hold {
		if test_hold == nil {
			test_hold = make(map[^Agent]bool)
		}
		test_hold[agent] = true
		return
	}
	if test_hold == nil {
		return
	}
	delete_key(&test_hold, agent)
	if len(test_hold) == 0 {
		delete(test_hold)
		test_hold = nil
	}
}

@(private)
test_pace_mu: sync.Mutex

@(private)
test_pace: map[^Agent]time.Duration

// Sleep this long at the start of each relay read. The agent still reads,
// so a caller upload keeps making send progress. Test builds only.
agent_test_relay_pace :: proc(agent: ^Agent, pace: time.Duration) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&test_pace_mu)
	defer sync.mutex_unlock(&test_pace_mu)
	if pace > 0 {
		if test_pace == nil {
			test_pace = make(map[^Agent]time.Duration)
		}
		test_pace[agent] = pace
		return
	}
	if test_pace == nil {
		return
	}
	delete_key(&test_pace, agent)
	if len(test_pace) == 0 {
		delete(test_pace)
		test_pace = nil
	}
}

agent_test_relay_pace_of :: proc(agent: ^Agent) -> time.Duration {
	if agent == nil {
		return 0
	}
	sync.mutex_lock(&test_pace_mu)
	defer sync.mutex_unlock(&test_pace_mu)
	if test_pace == nil {
		return 0
	}
	return test_pace[agent]
}

agent_test_relay_held :: proc(agent: ^Agent) -> bool {
	if agent == nil {
		return false
	}
	sync.mutex_lock(&test_hold_mu)
	defer sync.mutex_unlock(&test_hold_mu)
	if test_hold == nil {
		return false
	}
	return test_hold[agent]
}

// Shut the broker socket down so this process's session ends the way a
// killed agent does: the broker sees peer close, and agent_run dials again.
// agent_stop is a clean exit (it can RESET streams first); a restart is not.
// Test builds only.
@(private)
publish_mu: sync.Mutex

@(private)
publish_cond: sync.Cond

// Agents whose open worker must stop after the local dial, before the
// stream is inserted. Shutdown can snapshot the table in that window.
@(private)
publish_pause: map[^Agent]bool

@(private)
publish_paused: map[^Agent]bool

@(private)
stream_wait_mu: sync.Mutex

@(private)
stream_wait_cond: sync.Cond

// How many times shutdown found pumps or an open still in flight and
// nothing new to drop. The test releases the publish pause after this
// moves, so the insert lands after the snapshot.
@(private)
stream_wait_passes: map[^Agent]int

agent_test_pause_before_publish :: proc(agent: ^Agent, pause: bool) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&publish_mu)
	defer sync.mutex_unlock(&publish_mu)
	if pause {
		if publish_pause == nil {
			publish_pause = make(map[^Agent]bool, runtime.heap_allocator())
		}
		publish_pause[agent] = true
		return
	}
	if publish_pause != nil {
		delete_key(&publish_pause, agent)
		if len(publish_pause) == 0 {
			delete(publish_pause)
			publish_pause = nil
		}
	}
	sync.cond_broadcast(&publish_cond)
}

agent_test_wait_before_publish :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&publish_mu)
	defer sync.mutex_unlock(&publish_mu)
	if publish_pause == nil || !publish_pause[agent] {
		return
	}
	if publish_paused == nil {
		publish_paused = make(map[^Agent]bool, runtime.heap_allocator())
	}
	publish_paused[agent] = true
	sync.cond_broadcast(&publish_cond)
	for publish_pause != nil && publish_pause[agent] {
		sync.cond_wait(&publish_cond, &publish_mu)
	}
	if publish_paused != nil {
		delete_key(&publish_paused, agent)
		if len(publish_paused) == 0 {
			delete(publish_paused)
			publish_paused = nil
		}
	}
}

agent_test_wait_until_open_paused :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&publish_mu)
	defer sync.mutex_unlock(&publish_mu)
	for publish_paused == nil || !publish_paused[agent] {
		sync.cond_wait(&publish_cond, &publish_mu)
	}
}

agent_test_note_stream_wait :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&stream_wait_mu)
	defer sync.mutex_unlock(&stream_wait_mu)
	if stream_wait_passes == nil {
		stream_wait_passes = make(map[^Agent]int, runtime.heap_allocator())
	}
	stream_wait_passes[agent] += 1
	sync.cond_broadcast(&stream_wait_cond)
}

agent_test_wait_until_stream_wait :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&stream_wait_mu)
	defer sync.mutex_unlock(&stream_wait_mu)
	for stream_wait_passes == nil || stream_wait_passes[agent] == 0 {
		sync.cond_wait(&stream_wait_cond, &stream_wait_mu)
	}
}

agent_test_clear_stream_wait :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&stream_wait_mu)
	defer sync.mutex_unlock(&stream_wait_mu)
	if stream_wait_passes == nil {
		return
	}
	delete_key(&stream_wait_passes, agent)
	if len(stream_wait_passes) == 0 {
		delete(stream_wait_passes)
		stream_wait_passes = nil
	}
}

agent_cut_broker :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&agent.mutex)
	conn := agent.live_conn
	if conn != nil && !trans.connection_acquire(conn) {
		conn = nil
	}
	sync.mutex_unlock(&agent.mutex)
	if conn != nil {
		trans.connection_shutdown_both(conn)
		trans.connection_release(conn)
	}
}
