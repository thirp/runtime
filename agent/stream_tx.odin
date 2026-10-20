package agent

import proto "../protocol"
import trans "../transport"
import "core:container/queue"
import "core:mem"
import "core:sync"
import "core:time"

// Per-stream broker->local write queue. The one relay reader appends DATA
// here and moves on; a writer thread per stream drains it into the local
// service. A slow local service therefore only slows its own stream, not
// every stream on the agent session (the 50 MB upload / 320 KB/s stall).
//
// There is no per-stream flow control in protocol 1.0, so the queue cannot
// push back on the sender without also stopping the shared reader. The
// reader therefore never waits on a stream:
//   - a stream whose queue would pass its cap is RESET at once;
//   - when every stream together would pass the agent-wide cap, the stream
//     holding the most queued bytes is RESET (then the new data's stream,
//     if that still does not make room);
//   - an OPEN beyond the stream cap is refused (OPEN_FAILED QuotaExceeded).
// A large upload to a slow service therefore fails once its backlog passes
// the cap, instead of freezing every other stream (and, with the broker's
// PINGs stuck behind it, losing the agent session). WINDOW in a later
// protocol version is the real fix.
AgentTx :: struct {
	mutex:         sync.Mutex,
	cond:          sync.Cond,
	refs:          int, // atomic
	chunks:        queue.Queue([]u8),
	bytes:         int, // queued + the chunk being written; under mutex
	counter:       ^int, // agent-wide queued bytes (atomic), may be nil
	half_close:    bool, // broker HALF_CLOSE: shut write once drained
	write_done:    bool, // writer drained and shut the local write side
	closed:        bool, // stream finished; writer exits, queue dropped
	last_progress: time.Time,
	// Chunks and tx itself are freed on whichever thread lets go last.
	allocator:     mem.Allocator,
}

AgentTxArg :: struct {
	relay:     ^AgentRelay,
	stream_id: proto.StreamId,
	local:     ^trans.Connection,
	tx:        ^AgentTx,
}

agent_tx_new :: proc(counter: ^int = nil) -> ^AgentTx {
	tx, err := new(AgentTx)
	if err != .None {
		return nil
	}
	tx.refs = 1
	tx.counter = counter
	tx.allocator = context.allocator
	tx.last_progress = time.now()
	if queue.init(&tx.chunks, allocator = tx.allocator) != .None {
		free(tx, tx.allocator)
		return nil
	}
	return tx
}

agent_tx_acquire :: proc(tx: ^AgentTx) {
	sync.atomic_add(&tx.refs, 1)
}

agent_tx_release :: proc(tx: ^AgentTx) {
	if tx == nil {
		return
	}
	if sync.atomic_sub(&tx.refs, 1) != 1 {
		return
	}
	agent_tx_drop_queued_locked(tx)
	queue.destroy(&tx.chunks)
	free(tx, tx.allocator)
}

// Frees queued (not in-flight) chunks and gives their bytes back to the
// agent-wide count. Caller holds tx.mutex or the last reference.
agent_tx_drop_queued_locked :: proc(tx: ^AgentTx) {
	dropped := 0
	for queue.len(tx.chunks) > 0 {
		chunk := queue.pop_front(&tx.chunks)
		dropped += len(chunk)
		delete(chunk, tx.allocator)
	}
	tx.bytes -= dropped
	if tx.counter != nil && dropped > 0 {
		sync.atomic_sub(tx.counter, dropped)
	}
}

// Stream finished: the writer stops and queued bytes are dropped now (not
// when the last reference goes), so a reset frees agent-wide room at once.
agent_tx_close :: proc(tx: ^AgentTx) {
	if tx == nil {
		return
	}
	sync.mutex_lock(&tx.mutex)
	agent_tx_drop_queued_locked(tx)
	tx.closed = true
	sync.cond_broadcast(&tx.cond)
	sync.mutex_unlock(&tx.mutex)
}

agent_stall_timeout :: proc(relay: ^AgentRelay) -> time.Duration {
	if relay == nil || relay.agent == nil {
		return DEFAULT_STREAM_STALL_TIMEOUT
	}
	stall := relay.agent.config.stream_stall_timeout
	if stall == 0 {
		return DEFAULT_STREAM_STALL_TIMEOUT
	}
	if stall < 0 {
		return 0
	}
	return stall
}

agent_cfg_int :: proc(v: int, def: int) -> int {
	if v == 0 {
		return def
	}
	if v < 0 {
		return 0 // no limit
	}
	return v
}

agent_stream_buffer_cap :: proc(relay: ^AgentRelay) -> int {
	if relay == nil || relay.agent == nil {
		return DEFAULT_AGENT_STREAM_BUFFER
	}
	return agent_cfg_int(relay.agent.config.max_stream_buffer, DEFAULT_AGENT_STREAM_BUFFER)
}

agent_buffered_cap :: proc(relay: ^AgentRelay) -> int {
	if relay == nil || relay.agent == nil {
		return DEFAULT_AGENT_BUFFERED_BYTES
	}
	return agent_cfg_int(relay.agent.config.max_buffered_bytes, DEFAULT_AGENT_BUFFERED_BYTES)
}

agent_stream_cap :: proc(relay: ^AgentRelay) -> int {
	if relay == nil || relay.agent == nil {
		return DEFAULT_AGENT_MAX_STREAMS
	}
	return agent_cfg_int(relay.agent.config.max_streams, DEFAULT_AGENT_MAX_STREAMS)
}

// Test and metrics view of the agent-wide queue.
agent_note_buffered :: proc(relay: ^AgentRelay) {
	if relay.agent == nil {
		return
	}
	cur := sync.atomic_load(&relay.queued_bytes)
	sync.atomic_store(&relay.agent.buffered_bytes, cur)
	for {
		peak := sync.atomic_load(&relay.agent.buffered_peak)
		if cur <= peak {
			return
		}
		if _, ok := sync.atomic_compare_exchange_strong(&relay.agent.buffered_peak, peak, cur); ok {
			return
		}
	}
}

AgentEnqueueResult :: enum {
	Queued,
	Dropped,    // stream already finished
	StreamFull, // this stream's queue would pass its cap
	AgentFull,  // all queues together would pass the agent-wide cap
	NoMemory,
}

// Runs on the relay reader and never waits.
agent_tx_enqueue :: proc(tx: ^AgentTx, data: []u8, stream_cap: int, agent_cap: int) -> AgentEnqueueResult {
	if len(data) == 0 {
		return .Queued
	}
	sync.mutex_lock(&tx.mutex)
	defer sync.mutex_unlock(&tx.mutex)
	if tx.closed || tx.half_close {
		return .Dropped
	}
	if stream_cap > 0 && tx.bytes + len(data) > stream_cap {
		return .StreamFull
	}
	if tx.counter != nil && agent_cap > 0 {
		// Reserve first so two streams cannot both slip under the cap.
		if sync.atomic_add(tx.counter, len(data)) + len(data) > agent_cap {
			sync.atomic_sub(tx.counter, len(data))
			return .AgentFull
		}
	} else if tx.counter != nil {
		sync.atomic_add(tx.counter, len(data))
	}
	chunk, err := make([]u8, len(data), tx.allocator)
	if err != .None {
		if tx.counter != nil {
			sync.atomic_sub(tx.counter, len(data))
		}
		return .NoMemory
	}
	copy(chunk, data)
	if _, qerr := queue.push_back(&tx.chunks, chunk); qerr != .None {
		delete(chunk, tx.allocator)
		if tx.counter != nil {
			sync.atomic_sub(tx.counter, len(data))
		}
		return .NoMemory
	}
	tx.bytes += len(data)
	sync.cond_broadcast(&tx.cond)
	return .Queued
}

agent_tx_queued :: proc(tx: ^AgentTx) -> int {
	if tx == nil {
		return 0
	}
	sync.mutex_lock(&tx.mutex)
	defer sync.mutex_unlock(&tx.mutex)
	return tx.bytes
}

agent_tx_half_close :: proc(tx: ^AgentTx) {
	if tx == nil {
		return
	}
	sync.mutex_lock(&tx.mutex)
	tx.half_close = true
	sync.cond_broadcast(&tx.cond)
	sync.mutex_unlock(&tx.mutex)
}

agent_tx_write_done :: proc(tx: ^AgentTx) -> bool {
	if tx == nil {
		return true
	}
	sync.mutex_lock(&tx.mutex)
	defer sync.mutex_unlock(&tx.mutex)
	return tx.write_done
}

// One per stream. The local send timeout is the stall timeout, so a write
// fails only when the local service took no bytes for that long; a steady
// slow reader keeps the stream alive however long the upload takes.
agent_tx_writer :: proc(arg: ^AgentTxArg) {
	relay := arg.relay
	stream_id := arg.stream_id
	local := arg.local
	tx := arg.tx
	free(arg)
	defer {
		agent_tx_release(tx)
		trans.connection_release(local)
		sync.atomic_sub(&relay.live_pumps, 1)
	}
	for {
		sync.mutex_lock(&tx.mutex)
		for !tx.closed && queue.len(tx.chunks) == 0 && !tx.half_close {
			sync.cond_wait(&tx.cond, &tx.mutex)
		}
		if tx.closed {
			sync.mutex_unlock(&tx.mutex)
			return
		}
		if queue.len(tx.chunks) == 0 {
			// Broker HALF_CLOSE after everything queued before it.
			sync.mutex_unlock(&tx.mutex)
			_ = trans.connection_shutdown_write(local)
			sync.mutex_lock(&tx.mutex)
			tx.write_done = true
			sync.mutex_unlock(&tx.mutex)
			agent_maybe_finish(relay, stream_id)
			return
		}
		chunk := queue.pop_front(&tx.chunks)
		sync.mutex_unlock(&tx.mutex)

		werr := trans.connection_write(local, chunk)
		n := len(chunk)
		delete(chunk, tx.allocator)

		sync.mutex_lock(&tx.mutex)
		tx.bytes -= n
		if tx.counter != nil {
			sync.atomic_sub(tx.counter, n)
		}
		tx.last_progress = time.now()
		closed := tx.closed
		sync.cond_broadcast(&tx.cond)
		sync.mutex_unlock(&tx.mutex)
		if closed {
			return
		}
		if werr != .None {
			agent_reset_owned_stream(relay, stream_id, .InternalError)
			return
		}
	}
}
