package caller

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:sync"
import "core:time"

dial :: proc(c: ^Caller, service_id: proto.ServiceId) -> (^Conn, CallerError) {
	if c == nil {
		return nil, .InvalidConfig
	}
	if proto.check_service_id(string(service_id)) != .None {
		return nil, .InvalidServiceId
	}

	stream := conn_new(c)
	if stream == nil {
		return nil, .OutOfMemory
	}

	start := time.now()
	timeout := c.config.dial_timeout
	sync.mutex_lock(&c.mutex)
	for (c.pending != nil || c.pending_tombstone || !c.connected) && !sync.atomic_load(&c.stop) {
		if !dial_wait(c, start, timeout) {
			reason := dial_failure_reason_locked(c, c.conn, 0, false)
			sync.mutex_unlock(&c.mutex)
			caller_log_connect_timeout(c, service_id, reason)
			conn_release(stream)
			return nil, .Timeout
		}
	}
	if sync.atomic_load(&c.stop) {
		sync.mutex_unlock(&c.mutex)
		conn_release(stream)
		return nil, .Closed
	}
	if dial_deadline_hit(start, timeout) {
		reason := dial_failure_reason_locked(c, c.conn, 0, false)
		sync.mutex_unlock(&c.mutex)
		caller_log_connect_timeout(c, service_id, reason)
		conn_release(stream)
		return nil, .Timeout
	}
	c.pending = stream
	c.pending_err = .None
	broker := c.conn
	gen := c.conn_gen
	recv_at := c.recv_gen
	// The write below compares this pointer. Hold a reference so a new
	// session cannot be allocated at the same address until the compare
	// is done. The dial does not keep the reference while it waits.
	held := broker != nil && trans.connection_acquire(broker)
	sync.mutex_unlock(&c.mutex)

	payload, perr := proto.encode_connect(proto.Connect{service_id = service_id})
	if perr != .None {
		dial_clear_pending(c, stream)
		if held {
			trans.connection_release(broker)
		}
		conn_release(stream)
		return nil, .Internal
	}
	defer delete(payload)

	ok := false
	timed_out := false
	sent := false
	if held {
		ok, timed_out, sent = dial_write_connect(broker, payload, gen, start, timeout)
	}

	sync.mutex_lock(&c.mutex)
	same := dial_broker_matches(c.conn, broker, c.conn_gen, gen) && held
	if !ok || !same {
		// Already on the wire of this session: the slot stays a tombstone
		// so the late reply cannot bind to the next dial. A CONNECT that
		// never left, or left on a session that is already gone, does not.
		if sent && same && c.pending == stream {
			dial_arm_tombstone(c, stream)
		} else if c.pending == stream {
			c.pending = nil
			if same {
				c.pending_err = .Timeout
			} else {
				c.pending_err = .Transport
			}
			sync.cond_broadcast(&c.cond)
		}
		reason := dial_failure_reason_locked(c, broker, gen, true)
		sync.mutex_unlock(&c.mutex)
		// A CONNECT that did leave, with nothing read back and the peer
		// retransmitting, is a dead broker socket. Still holding the
		// reference taken for the write.
		if sent && same && (timed_out || timeout > 0) {
			caller_suspect_dead_peer(c, broker, gen, recv_at, time.since(start))
		}
		if held {
			trans.connection_release(broker)
		}
		conn_release(stream)
		// A timed dial that never gets a CONNECT out fails on its own.
		// The session stays up unless the socket itself has stopped making
		// send progress (that timer is not this deadline).
		if timed_out || timeout > 0 {
			caller_log_connect_timeout(c, service_id, reason)
			return nil, .Timeout
		}
		return nil, .Transport
	}
	sync.mutex_unlock(&c.mutex)
	trans.connection_release(broker)

	sync.mutex_lock(&c.mutex)
	for c.pending == stream && !sync.atomic_load(&c.stop) {
		if !dial_wait(c, start, timeout) {
			if c.pending == stream {
				dial_arm_tombstone(c, stream)
			}
			reason := dial_failure_reason_locked(c, broker, gen, true)
			sync.mutex_unlock(&c.mutex)
			caller_suspect_dead_peer(c, broker, gen, recv_at, time.since(start))
			caller_log_connect_timeout(c, service_id, reason)
			conn_release(stream)
			return nil, .Timeout
		}
	}
	if sync.atomic_load(&c.stop) {
		sync.mutex_unlock(&c.mutex)
		conn_release(stream)
		return nil, .Closed
	}
	// CONNECT_OK is the only path that sets accepted. A newer dial may have
	// stored pending_err None for its own slot; that is not success for us.
	if !stream.accepted {
		err := c.pending_err
		if err == .None {
			err = .Transport
		}
		sync.mutex_unlock(&c.mutex)
		conn_release(stream)
		return nil, err
	}
	sync.mutex_unlock(&c.mutex)
	return stream, .None
}

// CONNECT is a control frame: the session writer pulls it ahead of DATA
// queued behind the frame already on the socket. The deadline abandons
// this frame. It does not shut the session down.
dial_write_connect :: proc(
	broker: ^trans.Connection,
	payload: []u8,
	gen: int,
	start: time.Time,
	timeout: time.Duration,
) -> (ok: bool, timed_out: bool, sent: bool) {
	if broker == nil {
		return false, false, false
	}
	if dial_deadline_hit(start, timeout) {
		return false, true, false
	}
	deadline: time.Time
	has_deadline := timeout > 0
	if has_deadline {
		deadline = time.time_add(start, timeout)
	}
	return caller_write_until(
		broker,
		.Connect,
		payload,
		proto.CONNECTION_STREAM_ID,
		deadline,
		has_deadline,
		gen,
		true,
	)
}

// Holds c.mutex. Waits until signalled or the dial deadline. False means
// the deadline passed. timeout <= 0 waits until the session broadcasts.
dial_wait :: proc(c: ^Caller, start: time.Time, timeout: time.Duration) -> bool {
	if timeout <= 0 {
		sync.cond_wait(&c.cond, &c.mutex)
		return true
	}
	left := timeout - time.since(start)
	if left <= 0 {
		return false
	}
	_ = sync.cond_wait_with_timeout(&c.cond, &c.mutex, left)
	return !dial_deadline_hit(start, timeout)
}

dial_clear_pending :: proc(c: ^Caller, stream: ^Conn) {
	sync.mutex_lock(&c.mutex)
	if c.pending == stream {
		c.pending = nil
	}
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
}

// Holds c.mutex. stream's CONNECT is already out. The slot stays taken
// until that reply or the session drops. stream itself is not kept.
dial_arm_tombstone :: proc(c: ^Caller, stream: ^Conn) {
	if c.pending != stream {
		return
	}
	c.pending = nil
	c.pending_err = .Timeout
	c.pending_tombstone = true
	limit := c.config.dial_timeout
	c.tombstone_capped = limit > 0
	if limit > 0 {
		c.tombstone_deadline = time.time_add(time.now(), tombstone_cap_after(limit))
	}
	sync.cond_broadcast(&c.cond)
}

// How long a tombstone may sit after it is armed. At least two dial
// timeouts, and at least the agent local-dial default plus a margin.
tombstone_cap_after :: proc(dial_timeout: time.Duration) -> time.Duration {
	if dial_timeout <= 0 {
		return 0
	}
	scaled := TOMBSTONE_DIAL_TIMEOUTS * dial_timeout
	if scaled < TOMBSTONE_CAP_FLOOR {
		return TOMBSTONE_CAP_FLOOR
	}
	return scaled
}

// Same socket and the same session. A reused address with a new generation
// is a different session; the caller does not have to dereference either.
dial_broker_matches :: proc(cur, snap: ^trans.Connection, cur_gen, snap_gen: int) -> bool {
	if cur == nil || snap == nil {
		return false
	}
	return cur == snap && cur_gen == snap_gen
}

// Holds c.mutex. session_lost when the socket we were using is already
// gone. dial_timeout when this dial's own clock ran out on a live session.
// A stream id is not logged: the broker assigns one only on CONNECT_OK.
dial_failure_reason_locked :: proc(
	c: ^Caller,
	broker: ^trans.Connection,
	gen: int,
	have_gen: bool,
) -> string {
	lost := len(c.disconnect_reason) > 0
	// Pointer and generation only. This does not dereference broker.
	// The reference taken for the CONNECT write is already released on
	// the path that waits for CONNECT_OK.
	if have_gen && (c.conn != broker || c.conn_gen != gen) {
		lost = true
	}
	if lost {
		return LOG_REASON_SESSION_LOST
	}
	return LOG_REASON_DIAL_TIMEOUT
}

dial_failure_reason :: proc(
	c: ^Caller,
	broker: ^trans.Connection,
	gen: int,
	have_gen: bool,
) -> string {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return dial_failure_reason_locked(c, broker, gen, have_gen)
}

caller_log_connect_timeout :: proc(c: ^Caller, service_id: proto.ServiceId, reason: string) {
	caller_log(
		c,
		.Warn,
		LOG_EVENT_CONNECT_TIMEOUT,
		log.LogFields {
			service_id = string(service_id),
			reason     = reason,
		},
	)
}

dial_deadline_hit :: proc(start: time.Time, timeout: time.Duration) -> bool {
	return timeout > 0 && time.since(start) >= timeout
}

// The CONNECT went out and the dial's clock ran out with no frame back.
// Retransmits mean the broker is not acknowledging. A quiet but ACKed
// socket (the agent outbox is held, the broker is fine) is not this.
// A write still in send() belongs to the stall timer.
caller_suspect_dead_peer :: proc(
	c: ^Caller,
	broker: ^trans.Connection,
	gen: int,
	recv_at: int,
	waited: time.Duration,
) {
	if c == nil || broker == nil || waited < DEAD_PEER_MIN_WAIT {
		return
	}
	sync.mutex_lock(&c.mutex)
	if !dial_broker_matches(c.conn, broker, c.conn_gen, gen) || c.recv_gen != recv_at {
		sync.mutex_unlock(&c.mutex)
		return
	}
	conn := c.conn
	held := trans.connection_acquire(conn)
	sync.mutex_unlock(&c.mutex)
	if !held {
		return
	}
	defer trans.connection_release(conn)
	sync.mutex_lock(&c.write_mu)
	busy := c.writing || c.write_inflight
	sync.mutex_unlock(&c.write_mu)
	if busy {
		return
	}
	n, ok := socket_retransmits(conn)
	if !ok || n <= 0 {
		return
	}
	sync.mutex_lock(&c.mutex)
	still := dial_broker_matches(c.conn, conn, c.conn_gen, gen) && c.recv_gen == recv_at
	if still && len(c.disconnect_reason) == 0 {
		c.disconnect_reason = LOG_REASON_DEAD_PEER
	}
	sync.mutex_unlock(&c.mutex)
	if still {
		trans.connection_shutdown_both(conn)
	}
}

dial_join_code :: proc(c: ^Caller, namespace: string, join_code: string) -> (^Conn, CallerError) {
	if len(namespace) == 0 || len(join_code) == 0 {
		return nil, .InvalidServiceId
	}
	parts := [?]string{namespace, "/", join_code}
	id_str, cerr := strings.concatenate(parts[:])
	if cerr != .None {
		return nil, .OutOfMemory
	}
	defer delete(id_str)
	sid, serr := proto.make_service_id(id_str)
	if serr != .None {
		return nil, .InvalidServiceId
	}
	return dial(c, sid)
}
