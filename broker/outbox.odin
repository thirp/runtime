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
	if outbox_counts_as_data(opcode) {
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
	_, aerr := append(&q, QueuedFrame{opcode = opcode, stream_id = stream_id, payload = copied})
	if aerr != .None {
		if n > 0 {
			delete(copied, box.allocator)
		}
		if outbox_counts_as_data(opcode) {
			server_sub_buffered_bytes(box.server, n)
		}
		box.queues[stream_id] = q
		return .OutOfMemory
	}
	box.queues[stream_id] = q
	if outbox_counts_as_data(opcode) {
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
	return outbox_enqueue(box, opcode, stream_id, payload)
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
	if found {
		for frame in q {
			if len(frame.payload) > 0 {
				delete(frame.payload, box.allocator)
			}
		}
		delete(q)
		delete_key(&box.queues, stream_id)
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
	for i := 0; i < len(box.rr_order); i += 1 {
		if box.rr_order[i] == stream_id {
			outbox_rr_remove_locked(box, i)
			break
		}
	}
	sync.cond_broadcast(&box.cond)
}

outbox_wait_stream_space :: proc(
	box: ^ConnOutbox,
	stream_id: proto.StreamId,
	needed: int,
	timeout: time.Duration,
) -> bool {
	if box == nil {
		return false
	}
	deadline := time.now()
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	for {
		if box.closed {
			return false
		}
		max_stream := 0
		if box.server != nil {
			max_stream = box.server.max_stream_buffer
		}
		used := box.stream_bytes[stream_id]
		if max_stream <= 0 || used + needed <= max_stream {
			return true
		}
		remaining := timeout - time.since(deadline)
		if remaining <= 0 {
			return false
		}
		if !sync.cond_wait_with_timeout(&box.cond, &box.mutex, remaining) {
			return false
		}
	}
}

outbox_writer_proc :: proc(box: ^ConnOutbox) {
	allocator := box.allocator
	for {
		sync.mutex_lock(&box.mutex)
		for !box.closed && !outbox_has_frame_locked(box) {
			sync.cond_wait(&box.cond, &box.mutex)
		}
		if box.closed && !outbox_has_frame_locked(box) {
			sync.mutex_unlock(&box.mutex)
			return
		}
		frame, ok := outbox_take_next_locked(box)
		sync.mutex_unlock(&box.mutex)
		if !ok {
			continue
		}
		terr, perr := trans.write_frame(box.conn, frame.opcode, frame.payload, frame.stream_id, allocator)
		if len(frame.payload) > 0 {
			delete(frame.payload, allocator)
		}
		sync.mutex_lock(&box.mutex)
		sync.cond_broadcast(&box.cond)
		failed := terr != .None || perr != .None
		if failed {
			box.closed = true
		}
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
) -> OutboxEnqueueError {
	box := server_lookup_outbox(server, conn)
	if box == nil {
		return .Closed
	}
	defer outbox_release(box)
	return outbox_enqueue(box, opcode, stream_id, payload)
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
