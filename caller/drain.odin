package caller

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:time"

// Holds c.mutex. Moves the current broker socket, its streams, and its
// decoder onto a drain. New dials wait until the reader has connected a
// replacement. The parked tombstone is answered on the drain, not bound
// to a dial on the replacement. Past MAX_RETIRED_SESSIONS the oldest
// drain is stopped. Its streams end. This does not wait for that thread.
caller_park_drain :: proc(c: ^Caller) -> ^CallerDrain {
	d, err := new(CallerDrain)
	if err != .None {
		return nil
	}
	d.caller = c
	d.conn = c.conn
	d.gen = c.conn_gen
	d.decoder = c.decoder
	d.streams = c.streams
	d.tombstone = true
	d.last_recv = c.last_recv
	d.last_ping = c.last_ping
	c.conn = nil
	c.decoder = {}
	c.streams = make(map[proto.StreamId]^Conn)
	c.pending_tombstone = false
	c.tombstone_capped = false
	c.connected = false
	if c.drains == nil {
		c.drains = make([dynamic]^CallerDrain)
	}
	caller_drop_excess_drains(c)
	append(&c.drains, d)
	sync.cond_broadcast(&c.cond)
	return d
}

// Holds c.mutex. Stop the oldest drain still running until one slot is
// free for the drain about to be parked.
caller_drop_excess_drains :: proc(c: ^Caller) {
	for caller_count_running_drains(c) >= MAX_RETIRED_SESSIONS {
		oldest: ^CallerDrain
		for d in c.drains {
			if d != nil && !d.stop && !d.closed {
				oldest = d
				break
			}
		}
		if oldest == nil {
			return
		}
		nstreams := len(oldest.streams)
		oldest.stop = true
		if oldest.conn != nil {
			trans.connection_shutdown_both(oldest.conn)
		}
		caller_log(
			c,
			.Info,
			LOG_EVENT_DRAIN_DROPPED,
			log.LogFields {
				streams     = nstreams,
				streams_set = true,
				reason      = LOG_REASON_RETIRED_LIMIT,
			},
		)
	}
}

// Holds c.mutex.
caller_count_running_drains :: proc(c: ^Caller) -> int {
	n := 0
	for d in c.drains {
		if d != nil && !d.stop && !d.closed {
			n += 1
		}
	}
	return n
}

when ODIN_TEST {
	caller_running_drains :: proc(c: ^Caller) -> int {
		if c == nil {
			return 0
		}
		sync.mutex_lock(&c.mutex)
		defer sync.mutex_unlock(&c.mutex)
		return caller_count_running_drains(c)
	}
}

// Holds c.mutex. Wakes drain readers. Does not free them.
caller_signal_drains :: proc(c: ^Caller) {
	for d in c.drains {
		if d == nil {
			continue
		}
		d.stop = true
		if d.conn != nil {
			trans.connection_shutdown_both(d.conn)
		}
	}
}

caller_drain_proc :: proc(d: ^CallerDrain) {
	c := d.caller
	defer {
		sync.mutex_lock(&c.mutex)
		sync.atomic_sub(&c.drain_live, 1)
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mutex)
	}
	defer caller_drain_shutdown(d)
	caller_drain_loop(d)
}

caller_drain_loop :: proc(d: ^CallerDrain) {
	c := d.caller
	for !sync.atomic_load(&c.stop) {
		sync.mutex_lock(&c.mutex)
		if d.stop || d.closed || d.conn == nil || len(d.streams) == 0 {
			sync.mutex_unlock(&c.mutex)
			return
		}
		idle := time.since(d.last_recv) >= caller_read_idle_limit(c)
		last_recv := d.last_recv
		conn := d.conn
		gen := d.gen
		held := trans.connection_acquire(conn)
		sync.mutex_unlock(&c.mutex)
		if !held {
			return
		}
		if idle {
			// This socket only. The live session's disconnect reason stays.
			trans.connection_shutdown_both(conn)
			trans.connection_release(conn)
			return
		}
		caller_maybe_ping(c, conn, last_recv, &d.last_ping)
		_ = trans.connection_set_recv_timeout(conn, CALLER_POLL_INTERVAL)
		frame, terr, perr := trans.read_frame(conn, &d.decoder)
		if terr == .Timeout {
			trans.connection_release(conn)
			continue
		}
		if terr != .None || perr != .None {
			trans.connection_release(conn)
			return
		}
		sync.mutex_lock(&c.mutex)
		d.last_recv = time.now()
		sync.mutex_unlock(&c.mutex)
		end := caller_handle_frame(c, &d.streams, conn, gen, d, frame)
		proto.frame_destroy(&frame)
		trans.connection_release(conn)
		if end != .Continue {
			return
		}
	}
}

caller_drain_shutdown :: proc(d: ^CallerDrain) {
	if d == nil {
		return
	}
	c := d.caller
	sync.mutex_lock(&c.mutex)
	d.closed = true
	d.stop = true
	taken := make([dynamic]^Conn)
	for _, stream in d.streams {
		if stream != nil {
			conn_acquire(stream)
			append(&taken, stream)
		}
	}
	clear(&d.streams)
	conn := d.conn
	d.conn = nil
	for i := 0; i < len(c.drains); i += 1 {
		if c.drains[i] == d {
			ordered_remove(&c.drains, i)
			break
		}
	}
	sync.mutex_unlock(&c.mutex)
	for stream in taken {
		conn_finish(stream, .Transport)
		conn_release(stream)
	}
	delete(taken)
	if conn != nil {
		caller_unbind_session(conn)
		trans.connection_shutdown_both(conn)
		caller_wait_conn_write(c, conn)
		trans.connection_destroy(conn)
	}
	proto.decoder_destroy(&d.decoder)
	delete(d.streams)
	free(d)
}
