package agent

import proto "../protocol"
import trans "../transport"
import "core:container/queue"
import "core:sync"

AgentControlFrame :: struct {
	opcode:    proto.Opcode,
	code:      proto.WireError,
	stream_id: proto.StreamId,
}

// Only the relay reader posts here. The writer can wait behind DATA without
// preventing the reader from observing heartbeats or the real close cause.
AgentControlWriter :: struct {
	relay:    ^AgentRelay,
	mutex:    sync.Mutex,
	cond:     sync.Cond,
	pending:  queue.Queue(AgentControlFrame),
	stopping: bool,
}

agent_relay_write_failure :: proc(
	conn: ^trans.Connection,
	writer: ^AgentControlWriter,
	opcode: proto.Opcode,
	code: proto.WireError,
	stream_id: proto.StreamId,
) {
	if writer == nil {
		_ = agent_write_failure(conn, opcode, code, stream_id)
		return
	}
	sync.mutex_lock(&writer.mutex)
	for i in 0 ..< queue.len(writer.pending) {
		if queue.get(&writer.pending, i).stream_id == stream_id {
			sync.mutex_unlock(&writer.mutex)
			return
		}
	}
	_, err := queue.push_back(&writer.pending, AgentControlFrame{opcode, code, stream_id})
	if err == .None {
		sync.cond_signal(&writer.cond)
	}
	sync.mutex_unlock(&writer.mutex)
	if err != .None {
		// Allocation failed and the broker can still own the stream. Report
		// the local failure and let session teardown clear it.
		trans.connection_note_close(conn, .InternalError)
		trans.connection_shutdown_both(conn)
	}
}

agent_control_cancel :: proc(writer: ^AgentControlWriter, stream_id: proto.StreamId) {
	if writer == nil {
		return
	}
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	n := queue.len(writer.pending)
	for i in 0 ..< n {
		if queue.get(&writer.pending, i).stream_id != stream_id {
			continue
		}
		for j in i ..< n - 1 {
			queue.set(&writer.pending, j, queue.get(&writer.pending, j + 1))
		}
		_ = queue.pop_back(&writer.pending)
		return
	}
}

AgentControlAttempt :: struct {
	writer: ^AgentControlWriter,
	frame:  AgentControlFrame,
}

agent_control_claim :: proc(data: rawptr) -> bool {
	attempt := (^AgentControlAttempt)(data)
	writer := attempt.writer
	sync.mutex_lock(&writer.mutex)
	defer sync.mutex_unlock(&writer.mutex)
	if writer.stopping || queue.len(writer.pending) == 0 || queue.front(&writer.pending) != attempt.frame {
		return false
	}
	_ = queue.pop_front(&writer.pending)
	return true
}

agent_control_write :: proc(writer: ^AgentControlWriter) {
	conn := writer.relay.broker
	for {
		sync.mutex_lock(&writer.mutex)
		for !writer.stopping && queue.len(writer.pending) == 0 {
			sync.cond_wait(&writer.cond, &writer.mutex)
		}
		if writer.stopping {
			sync.mutex_unlock(&writer.mutex)
			return
		}
		// Keep the reply cancellable until this worker owns the socket
		// writer. Another stream may be using it for a blocking DATA send.
		frame := queue.front(&writer.pending)
		sync.mutex_unlock(&writer.mutex)
		attempt := AgentControlAttempt{writer, frame}
		if cause := agent_write_failure(conn, frame.opcode, frame.code, frame.stream_id, agent_control_claim, &attempt); cause != .None {
			trans.connection_note_close(conn, cause)
			trans.connection_shutdown_both(conn)
			return
		}
	}
}

agent_control_stop :: proc(writer: ^AgentControlWriter) {
	sync.mutex_lock(&writer.mutex)
	writer.stopping = true
	sync.cond_signal(&writer.cond)
	sync.mutex_unlock(&writer.mutex)
	trans.connection_shutdown_both(writer.relay.broker)
}
