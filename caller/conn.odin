package caller

import "core:sync"

conn_read :: proc(conn: ^Conn, buf: []u8) -> (n: int, err: ConnError) {
	if conn == nil {
		return 0, .Closed
	}
	sync.mutex_lock(&conn.mutex)
	defer sync.mutex_unlock(&conn.mutex)
	for len(conn.inbound) == 0 && !conn.closed && !conn.reset && !conn.eof {
		sync.cond_wait(&conn.cond, &conn.mutex)
	}
	if conn.reset {
		return 0, .Reset
	}
	if len(conn.inbound) == 0 {
		return 0, .Closed
	}
	n = min(len(buf), len(conn.inbound))
	copy(buf, conn.inbound[:n])
	copy(conn.inbound[:], conn.inbound[n:])
	resize(&conn.inbound, len(conn.inbound) - n)
	sync.cond_broadcast(&conn.cond)
	return n, .None
}

conn_write :: proc(conn: ^Conn, buf: []u8) -> (n: int, err: ConnError) {
	if conn == nil {
		return 0, .Closed
	}
	sync.mutex_lock(&conn.mutex)
	closed := conn.closed || conn.reset || conn.write_closed
	stream_id := conn.stream_id
	caller := conn.caller
	sync.mutex_unlock(&conn.mutex)
	if closed {
		return 0, .Closed
	}
	if caller == nil || caller.conn == nil {
		return 0, .Transport
	}
	if !caller_write(caller.conn, .Data, buf, stream_id) {
		return 0, .Transport
	}
	return len(buf), .None
}

conn_half_close :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	sync.mutex_lock(&conn.mutex)
	if conn.closed || conn.reset || conn.write_closed {
		sync.mutex_unlock(&conn.mutex)
		return
	}
	conn.write_closed = true
	stream_id := conn.stream_id
	caller := conn.caller
	sync.cond_broadcast(&conn.cond)
	sync.mutex_unlock(&conn.mutex)
	if caller != nil && caller.conn != nil {
		_ = caller_write(caller.conn, .HalfClose, nil, stream_id)
	}
}

conn_close :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	sync.mutex_lock(&conn.mutex)
	if conn.closed {
		sync.mutex_unlock(&conn.mutex)
		return
	}
	already_half := conn.write_closed
	conn.write_closed = true
	conn.closed = true
	stream_id := conn.stream_id
	caller := conn.caller
	sync.cond_broadcast(&conn.cond)
	sync.mutex_unlock(&conn.mutex)
	if caller != nil && caller.conn != nil {
		if !already_half {
			_ = caller_write(caller.conn, .HalfClose, nil, stream_id)
		}
		_ = caller_write(caller.conn, .Close, nil, stream_id)
	}
	if caller != nil {
		sync.mutex_lock(&caller.mutex)
		delete_key(&caller.streams, stream_id)
		sync.mutex_unlock(&caller.mutex)
	}
}

// Ends the stream on this side only, sending nothing. For a stream both
// sides have half-closed, which the broker already treats as finished.
conn_end_local :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	sync.mutex_lock(&conn.mutex)
	if conn.closed {
		sync.mutex_unlock(&conn.mutex)
		return
	}
	conn.write_closed = true
	conn.closed = true
	stream_id := conn.stream_id
	caller := conn.caller
	sync.cond_broadcast(&conn.cond)
	sync.mutex_unlock(&conn.mutex)
	if caller != nil {
		sync.mutex_lock(&caller.mutex)
		if caller.streams[stream_id] == conn {
			delete_key(&caller.streams, stream_id)
		}
		sync.mutex_unlock(&caller.mutex)
	}
}

conn_new :: proc(c: ^Caller) -> ^Conn {
	conn, err := new(Conn)
	if err != .None {
		return nil
	}
	conn.caller = c
	conn.inbound = make([dynamic]u8)
	conn.allocator = context.allocator
	conn.refs = 1
	return conn
}

// Ends the stream (if still open) and drops the owner's reference. The
// memory goes when the session reader is not using the stream either.
conn_destroy :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	conn_close(conn)
	conn_release(conn)
}

conn_acquire :: proc(conn: ^Conn) {
	sync.atomic_add(&conn.refs, 1)
}

conn_release :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	if sync.atomic_sub(&conn.refs, 1) != 1 {
		return
	}
	// The last reference can be the session reader's, on a thread whose
	// context allocator is not the one the stream was made with.
	delete(conn.inbound)
	free(conn, conn.allocator)
}

// Runs on the shared session reader and never waits. The protocol has no
// per-stream flow control, so waiting here would stop this session's reader
// and, through the broker's full per-stream queue, the Agent session that
// serves every caller of that service. It returns false (reset this stream)
// when the data would take the stream's backlog past cap. A single frame
// into an empty buffer is always taken.
conn_push_inbound :: proc(conn: ^Conn, data: []u8, cap: int = CONN_INBOUND_CAP) -> (ok: bool) {
	if len(data) == 0 {
		return true
	}
	sync.mutex_lock(&conn.mutex)
	defer sync.mutex_unlock(&conn.mutex)
	if conn.closed || conn.reset {
		return true
	}
	if len(conn.inbound) > 0 && len(conn.inbound)+len(data) > cap {
		return false
	}
	if _, err := append(&conn.inbound, ..data); err != .None {
		return false
	}
	sync.cond_broadcast(&conn.cond)
	return true
}

// Blocks until the peer finished the stream (CLOSE or RESET), this side
// half-closed it, or it was closed locally. Bridges use it after the peer's
// HALF_CLOSE so the local socket is torn down when the stream ends.
conn_wait_done :: proc(conn: ^Conn) -> (peer_finished: bool) {
	if conn == nil {
		return true
	}
	sync.mutex_lock(&conn.mutex)
	defer sync.mutex_unlock(&conn.mutex)
	for !conn.closed && !conn.reset && !conn.write_closed {
		sync.cond_wait(&conn.cond, &conn.mutex)
	}
	return conn.closed || conn.reset
}

// True when the peer reset the stream or it is fully closed (not just EOF).
conn_finished :: proc(conn: ^Conn) -> bool {
	if conn == nil {
		return true
	}
	sync.mutex_lock(&conn.mutex)
	defer sync.mutex_unlock(&conn.mutex)
	return conn.closed || conn.reset
}

// True once the peer half-closed (sent HALF_CLOSE) or finished the stream.
conn_peer_eof :: proc(conn: ^Conn) -> bool {
	if conn == nil {
		return true
	}
	sync.mutex_lock(&conn.mutex)
	defer sync.mutex_unlock(&conn.mutex)
	return conn.eof || conn.closed || conn.reset
}

conn_set_eof :: proc(conn: ^Conn) {
	sync.mutex_lock(&conn.mutex)
	conn.eof = true
	sync.cond_broadcast(&conn.cond)
	sync.mutex_unlock(&conn.mutex)
}

conn_finish :: proc(conn: ^Conn, kind: ConnError) {
	sync.mutex_lock(&conn.mutex)
	if kind == .Reset {
		conn.reset = true
	}
	conn.closed = true
	conn.eof = true
	sync.cond_broadcast(&conn.cond)
	sync.mutex_unlock(&conn.mutex)
}
