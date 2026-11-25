package broker

import proto "../protocol"
import trans "../transport"
import "core:bytes"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

QueuedFrame :: struct {
	opcode:    proto.Opcode,
	stream_id: proto.StreamId,
	payload:   []u8,
	release_slot: SessionId,
}

when ODIN_TEST {
	OutboxTestClock :: struct {
		// Called with the destination mutex held. A new wait takes its
		// starting sample before the loop checks the queue.
		test_wait_clock: proc(box: ^ConnOutbox, starting: bool, data: rawptr) -> time.Tick,
		test_wait_data:  rawptr,
		test_probe:      proc(source: ^ConnHandler, data: rawptr) -> (bool, int),
	}
} else {
	OutboxTestClock :: struct {}
}

ConnOutbox :: struct {
	mutex:        sync.Mutex,
	cond:         sync.Cond,
	conn:         ^trans.Connection,
	server:       ^Server,
	allocator:    mem.Allocator,
	queues:       map[proto.StreamId][dynamic]QueuedFrame,
	stream_bytes: map[proto.StreamId]int,
	total_bytes:  int,
	rr_order:     [dynamic]proto.StreamId,
	rr_index:     int,
	closed:       bool,
	refs:         int,
	writer:       ^thread.Thread,
	waiting_on_stream: bool, // our reader is waiting for a downstream outbox
	// Test only. While set, the writer leaves queued frames in place so a
	// test can observe what a terminal HALF_CLOSE does to them. Production
	// leaves it false. Shutdown (closed) still drains.
	writer_hold:  bool,
	using _:      OutboxTestClock,
}

outbox_counts_as_data :: proc(opcode: proto.Opcode) -> bool {
	return opcode == .Data
}

outbox_init :: proc(box: ^ConnOutbox, conn: ^trans.Connection, server: ^Server, allocator := context.allocator) {
	box^ = {}
	box.conn = conn
	box.server = server
	box.allocator = allocator
	box.queues = make(map[proto.StreamId][dynamic]QueuedFrame, allocator)
	box.stream_bytes = make(map[proto.StreamId]int, allocator)
	box.rr_order = make([dynamic]proto.StreamId, allocator)
	box.refs = 1
}

outbox_acquire :: proc(box: ^ConnOutbox) -> bool {
	if box == nil {
		return false
	}
	for {
		current := sync.atomic_load(&box.refs)
		if current <= 0 {
			return false
		}
		_, ok := sync.atomic_compare_exchange_strong(&box.refs, current, current + 1)
		if ok {
			return true
		}
	}
}

outbox_release :: proc(box: ^ConnOutbox) {
	if box == nil {
		return
	}
	prev := sync.atomic_sub(&box.refs, 1)
	if prev == 1 {
		outbox_free(box)
	}
}

outbox_free :: proc(box: ^ConnOutbox) {
	if box == nil {
		return
	}
	outbox_clear_queues(box)
	delete(box.queues)
	delete(box.stream_bytes)
	delete(box.rr_order)
	allocator := box.allocator
	free(box, allocator)
}

outbox_clear_queues :: proc(box: ^ConnOutbox) {
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	outbox_clear_queues_locked(box)
}

outbox_clear_queues_locked :: proc(box: ^ConnOutbox) {
	if box.total_bytes > 0 {
		server_sub_buffered_bytes(box.server, box.total_bytes)
	}
	for sid, q in box.queues {
		for frame in q {
			relay_release_cancelled_slot(box.server, frame.release_slot)
			if len(frame.payload) > 0 {
				delete(frame.payload, box.allocator)
			}
		}
		delete(q)
		delete_key(&box.queues, sid)
	}
	clear(&box.stream_bytes)
	clear(&box.rr_order)
	box.total_bytes = 0
	box.rr_index = 0
}

outbox_close :: proc(box: ^ConnOutbox) {
	if box == nil {
		return
	}
	sync.mutex_lock(&box.mutex)
	box.closed = true
	sync.cond_broadcast(&box.cond)
	sync.mutex_unlock(&box.mutex)
}

outbox_start_writer :: proc(box: ^ConnOutbox) {
	box.writer = thread.create_and_start_with_poly_data(box, outbox_writer_proc)
}

outbox_stop :: proc(box: ^ConnOutbox) {
	if box == nil {
		return
	}
	outbox_close(box)
	if box.conn != nil {
		trans.connection_close(box.conn)
	}
	if box.writer != nil {
		thread.join(box.writer)
		thread.destroy(box.writer)
		box.writer = nil
	}
	outbox_clear_queues(box)
}

outbox_has_frame_locked :: proc(box: ^ConnOutbox) -> bool {
	return len(box.rr_order) > 0
}

outbox_rr_add_locked :: proc(box: ^ConnOutbox, stream_id: proto.StreamId) {
	for id in box.rr_order {
		if id == stream_id {
			return
		}
	}
	append(&box.rr_order, stream_id)
}

outbox_rr_remove_locked :: proc(box: ^ConnOutbox, index: int) {
	if index < 0 || index >= len(box.rr_order) {
		return
	}
	ordered_remove(&box.rr_order, index)
	if len(box.rr_order) == 0 {
		box.rr_index = 0
		return
	}
	if box.rr_index > index {
		box.rr_index -= 1
	}
	if box.rr_index >= len(box.rr_order) {
		box.rr_index = 0
	}
}

outbox_enqueue :: proc(
	box: ^ConnOutbox,
	opcode: proto.Opcode,
	stream_id: proto.StreamId,
	payload: []u8,
	release_slot: SessionId = INVALID_SESSION_ID,
	origin: Maybe(StreamPeer) = nil,
) -> OutboxEnqueueError {
	if box == nil {
		return .Closed
	}
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	if box.closed {
		return .Closed
	}
	n := len(payload)
	is_data := outbox_counts_as_data(opcode)
	if is_data {
		used := box.stream_bytes[stream_id]
		max_stream := 0
		max_conn := 0
		if box.server != nil {
			max_stream = box.server.max_stream_buffer
			max_conn = box.server.max_connection_buffer
		}
		if max_stream > 0 && used + n > max_stream {
			return .StreamLimit
		}
		if max_conn > 0 && box.total_bytes + n > max_conn {
			return .ConnectionLimit
		}
		if !server_try_add_buffered_bytes(box.server, n) {
			return .GlobalLimit
		}
	}
	copied: []u8
	if n > 0 {
		copied = bytes.clone(payload, box.allocator)
	}
	q, found := box.queues[stream_id]
	if !found {
		q = make([dynamic]QueuedFrame, box.allocator)
	}
	_, aerr := append(&q, QueuedFrame{opcode = opcode, stream_id = stream_id, payload = copied, release_slot = release_slot})
	result: OutboxEnqueueError
	if aerr != .None {
		result = .OutOfMemory
	} else if opcode == .Open && !relay_publish_open(box.server, stream_id, box.conn) {
		// Revocation removed the relay before publication. The agent
		// writer cannot see this frame while we hold the outbox mutex.
		resize(&q, len(q) - 1)
		result = .Closed
	} else if from, relayed := origin.?; relayed && is_data && n > 0 {
		// The writer can deliver this DATA as soon as we release the
		// outbox mutex. Record it before a peer can reply with CLOSE.
		if relay_add_stream_bytes(box.server, stream_id, from, n) {
			metrics_add_bytes(&box.server.metrics, from, n)
		} else {
			// A terminal relay can no longer account for this DATA.
			// Keep it out of the writer's queue.
			resize(&q, len(q) - 1)
			result = .Closed
		}
	}
	if result != .None {
		if n > 0 {
			delete(copied, box.allocator)
		}
		if is_data {
			server_sub_buffered_bytes(box.server, n)
		}
		if found {
			box.queues[stream_id] = q
		} else {
			delete(q)
		}
		return result
	}
	box.queues[stream_id] = q
	if is_data {
		box.stream_bytes[stream_id] = box.stream_bytes[stream_id] + n
		box.total_bytes += n
	}
	if len(q) == 1 {
		outbox_rr_add_locked(box, stream_id)
	}
	sync.cond_signal(&box.cond)
	return .None
}

outbox_enqueue_failure :: proc(
	box: ^ConnOutbox,
	opcode: proto.Opcode,
	code: proto.WireError,
	stream_id: proto.StreamId,
	diagnostic := "",
	release_slot: SessionId = INVALID_SESSION_ID,
) -> OutboxEnqueueError {
	if box == nil {
		return .Closed
	}
	diag := diagnostic
	if len(diag) == 0 {
		diag = wire_error_diagnostic(code)
	}
	payload, perr := proto.encode_wire_failure(
		proto.WireFailure {
			code       = proto.wire_error_to_u16(code),
			diagnostic = diag,
		},
		box.allocator,
	)
	if perr != .None {
		return .OutOfMemory
	}
	defer delete(payload, box.allocator)
	return outbox_enqueue(box, opcode, stream_id, payload, release_slot)
}

outbox_take_next :: proc(box: ^ConnOutbox) -> (QueuedFrame, bool) {
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	return outbox_take_next_locked(box)
}

outbox_take_next_locked :: proc(box: ^ConnOutbox) -> (QueuedFrame, bool) {
	if len(box.rr_order) == 0 {
		return {}, false
	}
	idx := box.rr_index
	if idx >= len(box.rr_order) {
		idx = 0
	}
	stream_id := box.rr_order[idx]
	q := box.queues[stream_id]
	if len(q) == 0 {
		outbox_rr_remove_locked(box, idx)
		return {}, false
	}
	frame := q[0]
	ordered_remove(&q, 0)
	box.queues[stream_id] = q
	if outbox_counts_as_data(frame.opcode) {
		n := len(frame.payload)
		used := box.stream_bytes[stream_id] - n
		if used <= 0 {
			delete_key(&box.stream_bytes, stream_id)
		} else {
			box.stream_bytes[stream_id] = used
		}
		box.total_bytes -= n
		if box.total_bytes < 0 {
			box.total_bytes = 0
		}
		server_sub_buffered_bytes(box.server, n)
	}
	if len(q) == 0 {
		delete(q)
		delete_key(&box.queues, stream_id)
		outbox_rr_remove_locked(box, idx)
	} else if len(box.rr_order) > 0 {
		box.rr_index = (idx + 1) % len(box.rr_order)
	}
	return frame, true
}

outbox_drop_stream :: proc(box: ^ConnOutbox, stream_id: proto.StreamId) {
	if box == nil {
		return
	}
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	q, found := box.queues[stream_id]
	retained := 0
	if found {
		for frame in q {
			// Once a cancellation takes the slot, keep its terminal frame
			// even if another handler is still unwinding the same stream.
			if frame.release_slot != INVALID_SESSION_ID {
				q[retained] = frame
				retained += 1
			} else if len(frame.payload) > 0 {
				delete(frame.payload, box.allocator)
			}
		}
		if retained > 0 {
			resize(&q, retained)
			box.queues[stream_id] = q
		} else {
			delete(q)
			delete_key(&box.queues, stream_id)
		}
	}
	n := box.stream_bytes[stream_id]
	if n > 0 {
		box.total_bytes -= n
		if box.total_bytes < 0 {
			box.total_bytes = 0
		}
		server_sub_buffered_bytes(box.server, n)
	}
	delete_key(&box.stream_bytes, stream_id)
	if retained == 0 {
		for i := 0; i < len(box.rr_order); i += 1 {
			if box.rr_order[i] == stream_id {
				outbox_rr_remove_locked(box, i)
				break
			}
		}
	}
	sync.cond_broadcast(&box.cond)
}

OutboxWaitResult :: enum { Ready, Stalled, CallerOverflow }

@(private)
outbox_wait_now :: proc(box: ^ConnOutbox, starting := false) -> time.Tick {
	when ODIN_TEST {
		if box.test_wait_clock != nil {
			return box.test_wait_clock(box, starting, box.test_wait_data)
		}
	}
	return time.tick_now()
}

@(private)
outbox_probe_caller :: proc(box: ^ConnOutbox, source: ^ConnHandler) -> (bool, int) {
	when ODIN_TEST {
		if box.test_probe != nil {
			return box.test_probe(source, box.test_wait_data)
		}
	}
	return caller_input_probe(source)
}

outbox_wait_stream_space :: proc(
	box: ^ConnOutbox,
	stream_id: proto.StreamId,
	needed: int,
	timeout: time.Duration,
	source: ^ConnHandler = nil,
) -> OutboxWaitResult {
	if box == nil {
		return .Stalled
	}
	if source != nil && source.outbox != nil {
		outbox_set_stream_wait(source.outbox, true)
	}
	defer if source != nil && source.outbox != nil {
		outbox_set_stream_wait(source.outbox, false)
	}
	inspect_caller := source != nil && source.role == .Caller && source.conn != nil && cap(source.decoder.buf) > 0
	probing := false
	can_probe := inspect_caller
	previous_timeout: time.Duration
	defer if probing {
		_ = trans.connection_set_recv_timeout(source.conn, previous_timeout)
	}
	wait_started := time.tick_now()
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	when ODIN_TEST {
		if box.test_wait_clock != nil {
			wait_started = outbox_wait_now(box, starting = true)
		}
	}
	// Destination dequeues and successful caller reads renew separate
	// clocks. A dequeue that still leaves DATA blocked cannot renew the
	// caller's budget.
	progress_at := wait_started
	caller_read_at := wait_started
	probe_at := time.tick_add(wait_started, BACKPRESSURE_PING_INTERVAL)
	retry_ping_at := probe_at
	last_used := box.stream_bytes[stream_id]
	for {
		if box.closed {
			return .Stalled
		}
		max_stream := 0
		if box.server != nil {
			max_stream = box.server.max_stream_buffer
		}
		now := outbox_wait_now(box)
		used := box.stream_bytes[stream_id]
		if max_stream <= 0 || used + needed <= max_stream {
			return .Ready
		}
		if used < last_used {
			progress_at = now
		}
		last_used = used
		quiet := time.tick_diff(progress_at, now)
		slice := OUTBOX_WAIT_SLICE
		if timeout > 0 {
			remaining := timeout - quiet
			if remaining <= 0 {
				return .Stalled
			}
			slice = min(slice, remaining)
		}
		if inspect_caller && source.caller_input.deferred_ping && time.tick_diff(retry_ping_at, now) >= 0 {
			// A Ping can be left in a full parser while its previous
			// reply waits for the writer. Check for reclaimed space.
			sync.mutex_unlock(&box.mutex)
			if outbox_queued(source.outbox, proto.CONNECTION_STREAM_ID) == 0 {
				caller_input_take_heartbeats(source)
				can_probe = true
			}
			sync.mutex_lock(&box.mutex)
			retry_ping_at = time.tick_add(now, OUTBOX_WAIT_SLICE)
			continue
		}
		if inspect_caller && time.tick_diff(caller_read_at, now) >= CALLER_OVERFLOW_WAIT && caller_input_overflow(source, stream_id) {
			return .CallerOverflow
		}
		if can_probe && time.tick_diff(probe_at, now) >= 0 {
			// The destination writer must be able to drain during this read.
			sync.mutex_unlock(&box.mutex)
			if !probing {
				previous_timeout = source.conn.recv_timeout
				probing = true
			}
			if source.conn.recv_timeout != slice {
				_ = trans.connection_set_recv_timeout(source.conn, slice)
			}
			probed, read_bytes := outbox_probe_caller(box, source)
			can_probe = probed
			if read_bytes > 0 {
				caller_read_at = time.tick_now()
				when ODIN_TEST {
					if box.test_wait_clock != nil {
						caller_read_at = now
					}
				}
			}
			sync.mutex_lock(&box.mutex)
			continue
		}
		_ = sync.cond_wait_with_timeout(&box.cond, &box.mutex, slice)
	}
}

outbox_set_stream_wait :: proc(box: ^ConnOutbox, waiting: bool) {
	sync.mutex_lock(&box.mutex)
	box.waiting_on_stream = waiting
	sync.cond_broadcast(&box.cond)
	sync.mutex_unlock(&box.mutex)
}

outbox_writer_proc :: proc(box: ^ConnOutbox) {
	allocator := box.allocator
	interval := BACKPRESSURE_PING_INTERVAL
	if box.server != nil && box.server.heartbeat_interval > 0 {
		interval = min(interval, box.server.heartbeat_interval)
	}
	next_ping: time.Tick
	for {
		sync.mutex_lock(&box.mutex)
		ping := false
		for !box.closed {
			if !box.waiting_on_stream || box.writer_hold {
				if !box.writer_hold && outbox_has_frame_locked(box) {
					break
				}
				sync.cond_wait(&box.cond, &box.mutex)
				continue
			}
			// The reader cannot consume the peer's Ping with a DATA frame
			// waiting for space. A broker Ping still proves the path is alive.
			now := time.tick_now()
			left := time.tick_diff(now, next_ping)
			if next_ping == {} || left <= 0 {
				next_ping = time.tick_add(now, interval)
				ping = true
				break
			}
			if outbox_has_frame_locked(box) {
				break
			}
			_ = sync.cond_wait_with_timeout(&box.cond, &box.mutex, left)
		}
		if box.closed && !outbox_has_frame_locked(box) {
			sync.mutex_unlock(&box.mutex)
			return
		}
		frame: QueuedFrame
		ok := ping
		if !ping {
			frame, ok = outbox_take_next_locked(box)
		}
		sync.mutex_unlock(&box.mutex)
		if !ok {
			continue
		}
		if ping {
			frame.opcode = .Ping
			payload, err := proto.encode_ping(proto.Ping{nonce = u64(time.time_to_unix_nano(time.now()))}, allocator)
			if err != .None {
				continue
			}
			frame.payload = payload
		}
		terr, perr := trans.write_frame(box.conn, frame.opcode, frame.payload, frame.stream_id, allocator)
		if len(frame.payload) > 0 {
			delete(frame.payload, allocator)
		}
		sync.mutex_lock(&box.mutex)
		failed := terr != .None || perr != .None
		if failed {
			box.closed = true
		}
		relay_release_cancelled_slot(box.server, frame.release_slot)
		sync.cond_broadcast(&box.cond)
		sync.mutex_unlock(&box.mutex)
		if failed {
			return
		}
	}
}

server_register_outbox :: proc(server: ^Server, conn: ^trans.Connection, box: ^ConnOutbox) {
	sync.mutex_lock(&server.outbox_mutex)
	defer sync.mutex_unlock(&server.outbox_mutex)
	server.outboxes[conn] = box
}

server_unregister_outbox :: proc(server: ^Server, conn: ^trans.Connection) {
	sync.mutex_lock(&server.outbox_mutex)
	defer sync.mutex_unlock(&server.outbox_mutex)
	delete_key(&server.outboxes, conn)
}

server_lookup_outbox :: proc(server: ^Server, conn: ^trans.Connection) -> ^ConnOutbox {
	if server == nil || conn == nil {
		return nil
	}
	sync.mutex_lock(&server.outbox_mutex)
	defer sync.mutex_unlock(&server.outbox_mutex)
	box, found := server.outboxes[conn]
	if !found || !outbox_acquire(box) {
		return nil
	}
	return box
}

server_enqueue_frame :: proc(
	server: ^Server,
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId,
	origin: Maybe(StreamPeer) = nil,
) -> OutboxEnqueueError {
	box := server_lookup_outbox(server, conn)
	if box == nil {
		return .Closed
	}
	defer outbox_release(box)
	return outbox_enqueue(box, opcode, stream_id, payload, origin = origin)
}

server_enqueue_failure :: proc(
	server: ^Server,
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	code: proto.WireError,
	stream_id: proto.StreamId,
) -> OutboxEnqueueError {
	box := server_lookup_outbox(server, conn)
	if box == nil {
		return .Closed
	}
	defer outbox_release(box)
	return outbox_enqueue_failure(box, opcode, code, stream_id)
}

// The relay row is already gone. Transfer its admission slot to the
// terminal frame so a replacement OPEN cannot be sent before it.
server_enqueue_agent_cancel :: proc(
	server: ^Server,
	stream: RelayStream,
	opcode: proto.Opcode,
	payload: []u8 = nil,
	failure: proto.WireError = .None,
	diagnostic := "",
) {
	if stream.open_pending {
		return
	}
	box := server_lookup_outbox(server, stream.agent_conn)
	if box != nil {
		defer outbox_release(box)
		err: OutboxEnqueueError
		if failure != .None {
			err = outbox_enqueue_failure(box, opcode, failure, stream.id, diagnostic, stream.agent_session)
		} else {
			err = outbox_enqueue(box, opcode, stream.id, payload, stream.agent_session)
		}
		if err == .None {
			return
		}
		if err != .Closed {
			trans.connection_note_close(stream.agent_conn, .InternalError)
			trans.connection_shutdown_both(stream.agent_conn)
		}
	}
	relay_release_cancelled_slot(server, stream.agent_session)
}

// Holds the outbox writer so queued frames stay observable. Same package
// tests use this; production never sets it.
outbox_set_writer_hold :: proc(box: ^ConnOutbox, hold: bool) {
	if box == nil {
		return
	}
	sync.mutex_lock(&box.mutex)
	box.writer_hold = hold
	sync.cond_broadcast(&box.cond)
	sync.mutex_unlock(&box.mutex)
}

outbox_queued :: proc(box: ^ConnOutbox, stream_id: proto.StreamId) -> int {
	if box == nil {
		return 0
	}
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	q, found := box.queues[stream_id]
	if !found {
		return 0
	}
	return len(q)
}

server_drop_stream_queues :: proc(server: ^Server, stream: RelayStream) {
	if caller := server_lookup_outbox(server, stream.caller_conn); caller != nil {
		outbox_drop_stream(caller, stream.id)
		outbox_release(caller)
	}
	if agent := server_lookup_outbox(server, stream.agent_conn); agent != nil {
		outbox_drop_stream(agent, stream.id)
		outbox_release(agent)
	}
}
