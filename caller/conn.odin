package caller

import proto "../protocol"
import trans "../transport"
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
	if conn.closed || conn.reset || conn.write_closed {
		sync.mutex_unlock(&conn.mutex)
		return 0, .Closed
	}
	stream_id := conn.stream_id
	caller := conn.caller
	sync.mutex_unlock(&conn.mutex)
	// Snapshot the session under the caller lock and hold a reference.
	// Reading caller.conn again at the write would send this DATA on a
	// session installed after fail_all, ahead of any CONNECT.
	sess := caller_acquire_owned_session(caller, conn, stream_id)
	if sess == nil {
		return 0, .Closed
	}
	defer trans.connection_release(sess)
	if !caller_write(sess, .Data, buf, stream_id) {
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
	stream_id := conn.stream_id
	caller := conn.caller
	sync.mutex_unlock(&conn.mutex)
	sess := caller_acquire_owned_session(caller, conn, stream_id)
	sync.mutex_lock(&conn.mutex)
	if conn.closed || conn.reset || conn.write_closed {
		sync.mutex_unlock(&conn.mutex)
		if sess != nil {
			trans.connection_release(sess)
		}
		return
	}
	conn.write_closed = true
	sync.cond_broadcast(&conn.cond)
	sync.mutex_unlock(&conn.mutex)
	if sess != nil {
		_ = caller_write(sess, .HalfClose, nil, stream_id)
		trans.connection_release(sess)
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
	// Peer already half-closed. The broker ends the stream on the second
	// HALF_CLOSE, so a CLOSE from here is a frame for a stream it has
	// dropped (STREAM_NOT_FOUND) and the other side may already be gone.
	peer_half := conn.eof
	stream_id := conn.stream_id
	caller := conn.caller
	sync.mutex_unlock(&conn.mutex)
	sess := caller_acquire_owned_session(caller, conn, stream_id)
	sync.mutex_lock(&conn.mutex)
	if conn.closed {
		sync.mutex_unlock(&conn.mutex)
		if sess != nil {
			trans.connection_release(sess)
		}
		return
	}
	conn.write_closed = true
	conn.closed = true
	sync.cond_broadcast(&conn.cond)
	sync.mutex_unlock(&conn.mutex)
	if sess != nil {
		if !already_half {
			_ = caller_write(sess, .HalfClose, nil, stream_id)
		}
		if !peer_half {
			_ = caller_write(sess, .Close, nil, stream_id)
		}
		trans.connection_release(sess)
	}
	caller_forget_stream(caller, conn, stream_id)
}

// The session socket this stream may still write, with a reference held.
// Nil when the stream was dropped or the session was swapped: the caller
// must not follow caller.conn onto the replacement.
caller_acquire_owned_session :: proc(c: ^Caller, conn: ^Conn, sid: proto.StreamId) -> ^trans.Connection {
	if c == nil || conn == nil {
		return nil
	}
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	sess := caller_socket_for_stream(c, conn, sid)
	if sess == nil || !trans.connection_acquire(sess) {
		return nil
	}
	return sess
}

// Holds c.mutex. The live session, or a drain that still owns this stream.
caller_socket_for_stream :: proc(c: ^Caller, conn: ^Conn, sid: proto.StreamId) -> ^trans.Connection {
	if c.streams[sid] == conn && c.conn != nil {
		return c.conn
	}
	for d in c.drains {
		if d != nil && !d.closed && d.streams[sid] == conn && d.conn != nil {
			return d.conn
		}
	}
	return nil
}

// Holds c.mutex. True for the current broker socket or a drain not yet closed.
caller_socket_live :: proc(c: ^Caller, conn: ^trans.Connection) -> bool {
	if conn == nil {
		return false
	}
	if c.conn == conn {
		return true
	}
	for d in c.drains {
		if d != nil && !d.closed && d.conn == conn {
			return true
		}
	}
	return false
}

// Holds c.mutex. The generation this socket has now, if it is still the
// live session or an open drain. A Connection allocated later at the same
// address has a different generation.
caller_generation_of :: proc(c: ^Caller, conn: ^trans.Connection) -> (gen: int, ok: bool) {
	if c == nil || conn == nil {
		return 0, false
	}
	if c.conn == conn {
		return c.conn_gen, true
	}
	for d in c.drains {
		if d != nil && !d.closed && d.conn == conn {
			return d.gen, true
		}
	}
	return 0, false
}

caller_forget_stream :: proc(c: ^Caller, conn: ^Conn, sid: proto.StreamId) {
	if c == nil || conn == nil {
		return
	}
	sync.mutex_lock(&c.mutex)
	if c.streams[sid] == conn {
		delete_key(&c.streams, sid)
	}
	for d in c.drains {
		if d != nil && d.streams[sid] == conn {
			delete_key(&d.streams, sid)
		}
	}
	sync.mutex_unlock(&c.mutex)
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
	caller_forget_stream(caller, conn, stream_id)
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
