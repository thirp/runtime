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
	sync.cond_signal(&conn.cond)
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

conn_destroy :: proc(conn: ^Conn) {
	if conn == nil {
		return
	}
	conn_close(conn)
	sync.mutex_lock(&conn.mutex)
	delete(conn.inbound)
	conn.inbound = {}
	sync.mutex_unlock(&conn.mutex)
	free(conn)
}

conn_push_inbound :: proc(conn: ^Conn, data: []u8) {
	if len(data) == 0 {
		return
	}
	sync.mutex_lock(&conn.mutex)
	defer sync.mutex_unlock(&conn.mutex)
	for len(conn.inbound)+len(data) > CONN_INBOUND_CAP && !conn.closed && !conn.reset {
		sync.cond_wait(&conn.cond, &conn.mutex)
	}
	if conn.closed || conn.reset {
		return
	}
	_, err := append(&conn.inbound, ..data)
	_ = err
	sync.cond_signal(&conn.cond)
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
