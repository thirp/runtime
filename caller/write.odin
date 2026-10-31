package caller

import proto "../protocol"
import trans "../transport"
import "base:runtime"
import "core:bytes"
import "core:sync"
import "core:thread"
import "core:time"

// One frame waiting for the session writer. Control frames (everything but
// DATA) are pulled first at each frame boundary. The socket write for the
// frame already in flight is not interrupted.
WriteJob :: struct {
	conn:      ^trans.Connection,
	opcode:    proto.Opcode,
	payload:   []u8,
	stream_id: proto.StreamId,
	control:   bool,
	started:   bool,
	done:      bool,
	ok:        bool,
	// Waiter gave up. If the socket write has not started, the waiter
	// removes and frees the job. If it has, the drainer frees it.
	abandoned: bool,
	cancelled: bool,
	// Generation of conn when this job was queued. check_gen is a dial's
	// CONNECT and matches only the live session. Every other frame matches
	// the live session or the drain that still has this generation. A
	// Connection reused at the same address does not.
	gen:       int,
	check_gen: bool,
	// No waiter. The writer releases conn and frees the job. A late
	// CONNECT_OK RESET uses this so the reader does not block on the write.
	release_conn: bool,
}

@(private)
session_owner_mu: sync.Mutex

@(private)
session_owner: map[^trans.Connection]^Caller

caller_bind_session :: proc(c: ^Caller, conn: ^trans.Connection) {
	if c == nil || conn == nil {
		return
	}
	sync.mutex_lock(&session_owner_mu)
	defer sync.mutex_unlock(&session_owner_mu)
	// Heap, not the test tracking allocator. Parallel tests share this map,
	// and charging the allocation to whichever test created it reports a leak
	// when another test frees it.
	if session_owner == nil {
		session_owner = make(map[^trans.Connection]^Caller, runtime.heap_allocator())
	}
	session_owner[conn] = c
}

caller_unbind_session :: proc(conn: ^trans.Connection) {
	if conn == nil {
		return
	}
	sync.mutex_lock(&session_owner_mu)
	defer sync.mutex_unlock(&session_owner_mu)
	if session_owner == nil {
		return
	}
	delete_key(&session_owner, conn)
	if len(session_owner) == 0 {
		delete(session_owner)
		session_owner = nil
	}
}

caller_for_conn :: proc(conn: ^trans.Connection) -> ^Caller {
	if conn == nil {
		return nil
	}
	sync.mutex_lock(&session_owner_mu)
	defer sync.mutex_unlock(&session_owner_mu)
	if session_owner == nil {
		return nil
	}
	return session_owner[conn]
}

caller_send_stall :: proc(c: ^Caller) -> time.Duration {
	if c == nil {
		return 0
	}
	v := c.config.send_stall_timeout
	if v < 0 {
		return 0
	}
	if v == 0 {
		return DEFAULT_SEND_STALL_TIMEOUT
	}
	return v
}

caller_begin_write :: proc(c: ^Caller) -> bool {
	sync.mutex_lock(&c.write_mu)
	defer sync.mutex_unlock(&c.write_mu)
	if c.queues_closed || sync.atomic_load(&c.stop) {
		return false
	}
	c.write_waiters += 1
	return true
}

caller_end_write :: proc(c: ^Caller) {
	sync.mutex_lock(&c.write_mu)
	c.write_waiters -= 1
	sync.cond_broadcast(&c.write_cond)
	sync.mutex_unlock(&c.write_mu)
}

caller_write :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId = proto.CONNECTION_STREAM_ID,
) -> bool {
	c := caller_for_conn(conn)
	if c == nil {
		return false
	}
	if !caller_begin_write(c) {
		return false
	}
	defer caller_end_write(c)
	job := caller_enqueue(c, conn, opcode, payload, stream_id)
	if job == nil {
		return false
	}
	return caller_wait_job(c, job)
}

// Enqueue and wait until the frame is written or the deadline passes.
// On deadline the frame is dropped if the socket write has not started.
// The session is not closed here.
caller_write_until :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId,
	deadline: time.Time,
	has_deadline: bool,
	gen: int = 0,
	check_gen: bool = false,
) -> (ok: bool, timed_out: bool, sent: bool) {
	c := caller_for_conn(conn)
	if c == nil {
		return false, false, false
	}
	if !caller_begin_write(c) {
		return false, false, false
	}
	defer caller_end_write(c)
	job := caller_enqueue(c, conn, opcode, payload, stream_id, gen, check_gen)
	if job == nil {
		return false, false, false
	}
	if !has_deadline {
		wrote := caller_wait_job(c, job)
		return wrote, false, wrote
	}
	sync.mutex_lock(&c.write_mu)
	for !job.done {
		left := time.diff(time.now(), deadline)
		if left <= 0 {
			job.abandoned = true
			job.cancelled = true
			started := job.started
			if !started {
				caller_remove_job(c, job)
				sync.mutex_unlock(&c.write_mu)
				caller_free_job(job)
				return false, true, false
			}
			sync.mutex_unlock(&c.write_mu)
			// The socket write has started. The frame may already be out.
			return false, true, true
		}
		_ = sync.cond_wait_with_timeout(&c.write_cond, &c.write_mu, left)
	}
	ok = job.ok
	sync.mutex_unlock(&c.write_mu)
	caller_free_job(job)
	return ok, false, ok
}

caller_enqueue :: proc(
	c: ^Caller,
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId,
	gen: int = 0,
	check_gen: bool = false,
	release_conn: bool = false,
) -> ^WriteJob {
	// A detached job is freed on the writer thread. The test tracking
	// allocator is thread-local, so that alloc and free go through the heap.
	alloc := context.allocator
	if release_conn {
		alloc = runtime.heap_allocator()
	}
	job, aerr := new(WriteJob, alloc)
	if aerr != .None {
		return nil
	}
	job.release_conn = release_conn
	// CONNECT and a late RESET pass the generation they snapshotted.
	// Anything else takes the generation the socket has right now.
	job_gen := gen
	if !check_gen && !release_conn {
		sync.mutex_lock(&c.mutex)
		looked, found := caller_generation_of(c, conn)
		sync.mutex_unlock(&c.mutex)
		if found {
			job_gen = looked
		} else {
			job_gen = -1
		}
	}
	if len(payload) > 0 {
		cloned, cerr := bytes.clone_safe(payload, alloc)
		if cerr != nil {
			caller_free_job(job)
			return nil
		}
		job.payload = cloned
	}
	job.conn = conn
	job.opcode = opcode
	job.stream_id = stream_id
	job.gen = job_gen
	job.check_gen = check_gen
	job.control = opcode != .Data
	sync.mutex_lock(&c.write_mu)
	if c.queues_closed {
		sync.mutex_unlock(&c.write_mu)
		caller_free_job(job)
		return nil
	}
	q := &c.data_q
	if job.control {
		q = &c.control_q
	}
	if _, err := append(q, job); err != .None {
		sync.mutex_unlock(&c.write_mu)
		caller_free_job(job)
		return nil
	}
	start := !c.writing
	if start {
		c.writing = true
	}
	sync.cond_broadcast(&c.write_cond)
	sync.mutex_unlock(&c.write_mu)
	if start {
		caller_drain(c)
	}
	return job
}

caller_wait_job :: proc(c: ^Caller, job: ^WriteJob) -> bool {
	sync.mutex_lock(&c.write_mu)
	for !job.done {
		sync.cond_wait(&c.write_cond, &c.write_mu)
	}
	ok := job.ok
	sync.mutex_unlock(&c.write_mu)
	caller_free_job(job)
	return ok
}

caller_remove_job :: proc(c: ^Caller, job: ^WriteJob) {
	q := &c.data_q
	if job.control {
		q = &c.control_q
	}
	for i := 0; i < len(q); i += 1 {
		if q[i] == job {
			ordered_remove(q, i)
			return
		}
	}
}

// Writer owns this job: no waiter will free it. A release_conn job also
// drops the socket reference it took from the reader.
caller_finish_detached :: proc(job: ^WriteJob) {
	if job == nil {
		return
	}
	if job.release_conn && job.conn != nil {
		trans.connection_release(job.conn)
		job.conn = nil
	}
	caller_free_job(job)
}

caller_free_job :: proc(job: ^WriteJob) {
	if job == nil {
		return
	}
	alloc := context.allocator
	if job.release_conn {
		alloc = runtime.heap_allocator()
	}
	if len(job.payload) > 0 {
		delete(job.payload, alloc)
	}
	free(job, alloc)
}

caller_pop_job :: proc(c: ^Caller) -> ^WriteJob {
	if len(c.control_q) > 0 {
		job := c.control_q[0]
		ordered_remove(&c.control_q, 0)
		return job
	}
	if len(c.data_q) > 0 {
		job := c.data_q[0]
		ordered_remove(&c.data_q, 0)
		return job
	}
	return nil
}

caller_drain :: proc(c: ^Caller) {
	for {
		sync.mutex_lock(&c.write_mu)
		job := caller_pop_job(c)
		if job == nil {
			c.writing = false
			sync.cond_broadcast(&c.write_cond)
			sync.mutex_unlock(&c.write_mu)
			return
		}
		if job.cancelled || job.abandoned {
			sync.mutex_unlock(&c.write_mu)
			caller_finish_detached(job)
			continue
		}
		job.started = true
		c.write_inflight = true
		c.write_conn = job.conn
		conn := job.conn
		opcode := job.opcode
		payload := job.payload
		stream_id := job.stream_id
		sync.mutex_unlock(&c.write_mu)

		ok := false
		sync.mutex_lock(&c.mutex)
		// Do not touch conn unless this matches; the job may not hold a ref.
		// check_gen is a dial's CONNECT: only the live session it
		// snapshotted. Every other frame must match that generation on
		// the live session or on the drain parked from it. Pointer
		// equality is not enough once the address is reused.
		live := false
		if job.check_gen {
			live = dial_broker_matches(c.conn, conn, c.conn_gen, job.gen)
		} else {
			live = caller_reset_targets(c, conn, job.gen)
		}
		sync.mutex_unlock(&c.mutex)
		if live {
			terr, perr := trans.write_frame(conn, opcode, payload, stream_id)
			ok = terr == .None && perr == .None
			if ok {
				sync.atomic_add(&c.user_send_bytes, len(payload) + proto.HEADER_SIZE)
			}
		}

		sync.mutex_lock(&c.write_mu)
		c.write_inflight = false
		c.write_conn = nil
		abandoned := job.abandoned
		detach := job.release_conn
		if !abandoned && !detach {
			job.done = true
			job.ok = ok
		}
		sync.cond_broadcast(&c.write_cond)
		sync.mutex_unlock(&c.write_mu)
		if abandoned || detach {
			caller_finish_detached(job)
		}
	}
}

// Mark queued frames done so their waiters free them. Does not free: the
// waiter still owns the job. In-flight frames stay with the drainer.
caller_fail_queued :: proc(c: ^Caller) {
	if c == nil {
		return
	}
	sync.mutex_lock(&c.write_mu)
	defer sync.mutex_unlock(&c.write_mu)
	caller_fail_queue(&c.control_q)
	caller_fail_queue(&c.data_q)
	sync.cond_broadcast(&c.write_cond)
}

caller_fail_queue :: proc(q: ^[dynamic]^WriteJob) {
	for len(q) > 0 {
		job := q[0]
		ordered_remove(q, 0)
		if job.release_conn {
			caller_finish_detached(job)
			continue
		}
		job.ok = false
		job.done = true
	}
}

// Refuse new frames, fail anything still queued, and block until the
// current socket write and its waiters have left.
caller_close_writes :: proc(c: ^Caller) {
	if c == nil {
		return
	}
	sync.mutex_lock(&c.write_mu)
	c.queues_closed = true
	caller_fail_queue(&c.control_q)
	caller_fail_queue(&c.data_q)
	sync.cond_broadcast(&c.write_cond)
	sync.mutex_unlock(&c.write_mu)
	caller_wait_writes(c)
}

caller_wait_writes :: proc(c: ^Caller) {
	sync.mutex_lock(&c.write_mu)
	for c.writing || c.write_inflight || c.write_waiters > 0 {
		sync.cond_wait(&c.write_cond, &c.write_mu)
	}
	sync.mutex_unlock(&c.write_mu)
}

// Block until the writer is not inside a send on this socket. Queued
// frames for other sockets, and a send already finished, do not wait.
caller_wait_conn_write :: proc(c: ^Caller, conn: ^trans.Connection) {
	if c == nil || conn == nil {
		return
	}
	sync.mutex_lock(&c.write_mu)
	for c.write_inflight && c.write_conn == conn {
		sync.cond_wait(&c.write_cond, &c.write_mu)
	}
	sync.mutex_unlock(&c.write_mu)
}

caller_delete_queues :: proc(c: ^Caller) {
	if c == nil {
		return
	}
	delete(c.control_q)
	delete(c.data_q)
	c.control_q = nil
	c.data_q = nil
}

// One timer for the session. Wakes on write_cond (enqueue or completion),
// not on a poll. The deadline is absolute: a broadcast that is not send
// progress does not extend it. Idle sessions (nothing in flight) wait
// instead of closing.
caller_stall_proc :: proc(c: ^Caller) {
	baseline: u64
	baseline_set := false
	// Once TCP_INFO has answered, keep that counter. Falling back to bytes
	// queued by write() on a failed sample would move the number and restart
	// the window forever.
	use_tcp := false
	deadline: time.Time
	for !sync.atomic_load(&c.stall_stop) {
		window := caller_send_stall(c)
		sync.mutex_lock(&c.write_mu)
		if sync.atomic_load(&c.stall_stop) {
			sync.mutex_unlock(&c.write_mu)
			return
		}
		inflight := c.write_inflight || c.writing
		if window <= 0 || !inflight {
			baseline_set = false
			use_tcp = false
			sync.cond_wait(&c.write_cond, &c.write_mu)
			sync.mutex_unlock(&c.write_mu)
			continue
		}
		sync.mutex_unlock(&c.write_mu)

		progress := caller_stall_sample(c, &use_tcp, baseline, baseline_set)
		now := time.now()
		if !baseline_set || progress != baseline {
			baseline = progress
			baseline_set = true
			deadline = time.time_add(now, window)
		}
		left := time.diff(now, deadline)
		if left <= 0 {
			again := caller_stall_sample(c, &use_tcp, baseline, true)
			if again != baseline {
				baseline = again
				baseline_set = true
				deadline = time.time_add(time.now(), window)
				continue
			}
			caller_stall_shutdown(c)
			baseline_set = false
			use_tcp = false
			sync.mutex_lock(&c.write_mu)
			for (c.write_inflight || c.writing) && !sync.atomic_load(&c.stall_stop) {
				sync.cond_wait(&c.write_cond, &c.write_mu)
			}
			sync.mutex_unlock(&c.write_mu)
			continue
		}
		sync.mutex_lock(&c.write_mu)
		if sync.atomic_load(&c.stall_stop) {
			sync.mutex_unlock(&c.write_mu)
			return
		}
		if !(c.write_inflight || c.writing) {
			sync.mutex_unlock(&c.write_mu)
			baseline_set = false
			continue
		}
		_ = sync.cond_wait_with_timeout(&c.write_cond, &c.write_mu, left)
		sync.mutex_unlock(&c.write_mu)
	}
}

// tcp is set when the sample is tcpi_bytes_acked. A later failed read keeps
// the previous sample so the stall window does not restart on a different counter.
caller_stall_sample :: proc(c: ^Caller, use_tcp: ^bool, baseline: u64, have_baseline: bool) -> u64 {
	n, tcp := caller_send_progress(c)
	if tcp {
		use_tcp^ = true
		return n
	}
	if use_tcp^ && have_baseline {
		return baseline
	}
	return n
}

// The in-flight socket when it is still the live session or a drain.
// Otherwise the live session. The reference is held across the return.
caller_stall_target :: proc(c: ^Caller) -> (conn: ^trans.Connection, held: bool) {
	sync.mutex_lock(&c.write_mu)
	wc := c.write_conn
	wc_held := wc != nil && trans.connection_acquire(wc)
	sync.mutex_unlock(&c.write_mu)
	sync.mutex_lock(&c.mutex)
	if wc_held && caller_socket_live(c, wc) {
		sync.mutex_unlock(&c.mutex)
		return wc, true
	}
	if wc_held {
		trans.connection_release(wc)
	}
	conn = c.conn
	held = conn != nil && trans.connection_acquire(conn)
	sync.mutex_unlock(&c.mutex)
	return
}

caller_send_progress :: proc(c: ^Caller) -> (n: u64, tcp: bool) {
	conn, held := caller_stall_target(c)
	if held {
		if acked, ok := socket_bytes_acked(conn); ok {
			trans.connection_release(conn)
			return acked, true
		}
		trans.connection_release(conn)
	}
	return u64(sync.atomic_load(&c.user_send_bytes)), false
}

caller_stall_shutdown :: proc(c: ^Caller) {
	conn, held := caller_stall_target(c)
	if !held {
		return
	}
	sync.mutex_lock(&c.mutex)
	// A retired socket stalling drops only that socket. reason=stall is
	// the live session, so the reader logs it and reconnects.
	if conn == c.conn && len(c.disconnect_reason) == 0 {
		c.disconnect_reason = LOG_REASON_STALL
	}
	sync.mutex_unlock(&c.mutex)
	trans.connection_shutdown_both(conn)
	trans.connection_release(conn)
}

caller_start_stall :: proc(c: ^Caller) -> bool {
	if c.stall_thread != nil {
		return true
	}
	c.stall_thread = thread.create_and_start_with_poly_data(c, caller_stall_proc)
	return c.stall_thread != nil
}

caller_stop_stall :: proc(c: ^Caller) {
	if c == nil {
		return
	}
	sync.atomic_store(&c.stall_stop, true)
	sync.mutex_lock(&c.write_mu)
	sync.cond_broadcast(&c.write_cond)
	sync.mutex_unlock(&c.write_mu)
	if c.stall_thread != nil {
		thread.join(c.stall_thread)
		thread.destroy(c.stall_thread)
		c.stall_thread = nil
	}
}
