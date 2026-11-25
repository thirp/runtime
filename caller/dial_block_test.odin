package caller

import ag "../agent"
import brk "../broker"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Upload DATA that blocks in the kernel, holding the session write lock.
BlockedUpload :: struct {
	conn:   ^Conn,
	stop:   bool, // atomic; stop after the in-flight frame
	done:   bool,
	sent:   int,
	err:    ConnError, // atomic
	limit:  int,
	// Nanoseconds to sleep after each chunk. Zero sends as fast as the socket allows.
	gap_ns: int,
}

blocked_upload_proc :: proc(u: ^BlockedUpload) {
	chunk := make([]u8, 8 * 1024)
	defer delete(chunk)
	// Stall tests write until they observe backpressure. A paced test
	// can set a finite limit to measure progress through a known upload.
	for !sync.atomic_load(&u.stop) && (u.limit <= 0 || sync.atomic_load(&u.sent) < u.limit) {
		n, werr := conn_write(u.conn, chunk)
		if werr != .None || n != len(chunk) {
			sync.atomic_store(&u.err, werr)
			break
		}
		sync.atomic_add(&u.sent, n)
		gap := time.Duration(sync.atomic_load(&u.gap_ns))
		if gap > 0 {
			time.sleep(gap)
		}
	}
	sync.atomic_store(&u.done, true)
}

DialAttempt :: struct {
	c:    ^Caller,
	sid:  proto.ServiceId,
	conn: ^Conn,
	err:  CallerError,
	done: bool,
}

dial_attempt_proc :: proc(a: ^DialAttempt) {
	a.conn, a.err = dial(a.c, a.sid)
	sync.atomic_store(&a.done, true)
}

// F1: one pending CONNECT shares the session writer with upload DATA.
// A DATA send stuck in the kernel holds that writer. The dial deadline
// abandons the CONNECT. It does not shut the session down, so the upload
// is still running when dial returns Timeout. Releasing the broker hold
// lets the upload finish, and a later dial gets CONNECT_OK on the same
// session.
@(test)
test_dial_behind_blocked_data_times_out_and_recovers :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	// Allow the queued socket bytes to drain after the read hold is released.
	fx.server.max_stream_buffer = fx.server.max_connection_buffer

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: ag.Agent
	run: AgentRunArg
	ath := start_registered_agent(t, &fx, echo_ep, &agent, &run)
	defer stop_agent(&agent, ath)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 500 * time.Millisecond,
				// The dial deadline must not be what ends the session.
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	up_conn, derr := dial(&c, sid)
	testing.expect_value(t, derr, CallerError.None)
	if up_conn == nil {
		return
	}
	defer conn_destroy(up_conn)

	payload := []u8{'h', 'i'}
	n, werr := conn_write(up_conn, payload)
	testing.expect_value(t, werr, ConnError.None)
	testing.expect_value(t, n, 2)
	buf: [8]u8
	rn, rerr := conn_read(up_conn, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:rn]), "hi")

	// Force a transport write stall on this caller socket. An overflowing
	// destination now resets only its stream, so it cannot create the stall.
	broker_conn := hold_broker_caller_reader(&fx.server, up_conn.stream_id)
	if !testing.expect(t, broker_conn != nil, "broker-side caller socket") {
		return
	}
	defer trans.connection_release(broker_conn)
	defer release_broker_caller_reader(broker_conn)
	// Keep the default buffer. A small explicit SO_SNDBUF on Winsock
	// loopback lets sends keep completing even with the broker stalled.
	_ = trans.connection_set_send_timeout(c.conn, 8 * time.Second)

	up := BlockedUpload{conn = up_conn}
	uth := thread.create_and_start_with_poly_data(&up, blocked_upload_proc)
	testing.expect(t, uth != nil, "upload thread")
	if uth == nil {
		return
	}
	defer {
		sync.atomic_store(&up.stop, true)
		release_broker_caller_reader(broker_conn)
		thread.join(uth)
		thread.destroy(uth)
	}

	blocked := false
	last := -1
	changed := time.now()
	wait_start := time.now()
	for time.since(wait_start) < 2 * time.Second {
		if sync.atomic_load(&up.done) {
			break
		}
		sent := sync.atomic_load(&up.sent)
		if sent != last {
			last = sent
			changed = time.now()
		} else if sent > 0 && time.since(changed) >= 200 * time.Millisecond {
			blocked = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expectf(
		t,
		blocked,
		"DATA write did not block (done=%v sent=%d err=%v)",
		sync.atomic_load(&up.done),
		sync.atomic_load(&up.sent),
		sync.atomic_load(&up.err),
	)
	if !blocked {
		return
	}

	attempt := DialAttempt {
		c   = &c,
		sid = sid,
	}
	dth := thread.create_and_start_with_poly_data(&attempt, dial_attempt_proc)
	testing.expect(t, dth != nil, "dial thread")
	if dth == nil {
		return
	}
	defer {
		release_broker_caller_reader(broker_conn)
		thread.join(dth)
		thread.destroy(dth)
		if attempt.conn != nil {
			conn_destroy(attempt.conn)
			attempt.conn = nil
		}
	}

	dial_wait := time.now()
	for !sync.atomic_load(&attempt.done) && time.since(dial_wait) < 2 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(
		t,
		sync.atomic_load(&attempt.done),
		"CONNECT stayed queued behind the blocked DATA write (sent=%d)",
		sync.atomic_load(&up.sent),
	)
	if !sync.atomic_load(&attempt.done) {
		return
	}
	testing.expect_value(t, attempt.err, CallerError.Timeout)
	testing.expect(t, attempt.conn == nil, "timed-out dial returned a stream")
	testing.expect(t, !sync.atomic_load(&up.done), "dial timeout killed the upload")
	testing.expect(t, caller_is_connected(&c), "dial timeout closed the session")
	gen := caller_conn_gen(&c)

	released := sync.atomic_load(&up.sent)
	sync.atomic_store(&up.stop, true)
	release_broker_caller_reader(broker_conn)
	progress := time.now()
	for sync.atomic_load(&up.sent) <= released && !sync.atomic_load(&up.done) && time.since(progress) < 2 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	// The echo of a buffered upload can fill the inbound cap and reset the
	// stream. Survival is more bytes sent on the same session, not err None.
	testing.expectf(
		t,
		sync.atomic_load(&up.sent) > released && caller_conn_gen(&c) == gen && caller_is_connected(&c),
		"upload did not survive the dial timeout (sent=%d released=%d done=%v err=%v gen_same=%v connected=%v)",
		sync.atomic_load(&up.sent),
		released,
		sync.atomic_load(&up.done),
		sync.atomic_load(&up.err),
		caller_conn_gen(&c) == gen,
		caller_is_connected(&c),
	)
	c.config.dial_timeout = 3 * time.Second
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again == nil {
		return
	}
	defer conn_destroy(again)
	n, werr = conn_write(again, payload)
	testing.expect_value(t, werr, ConnError.None)
	testing.expect_value(t, n, 2)
	rn, rerr = conn_read(again, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:rn]), "hi")
}

caller_is_connected :: proc(c: ^Caller) -> bool {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return c.connected
}

caller_conn_gen :: proc(c: ^Caller) -> int {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return c.conn_gen
}

// A socket that accepts no more bytes. The stall window is shorter than
// the dial deadline, so the session restarts on its own and the dial fails
// with a log line. The upload does not survive this one.
@(test)
test_stuck_socket_restarts_session_and_dials_timeout :: proc(t: ^testing.T) {
	delete(stuck_logs.text)
	stuck_logs.text = nil
	defer {
		delete(stuck_logs.text)
		stuck_logs.text = nil
	}
	logger: log.Logger
	log.logger_init(&logger, .Info, stuck_log_sink)

	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: ag.Agent
	run: AgentRunArg
	ath := start_registered_agent(t, &fx, echo_ep, &agent, &run)
	defer stop_agent(&agent, ath)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				logger = &logger,
				dial_timeout = 3 * time.Second,
				send_stall_timeout = 500 * time.Millisecond,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	up_conn, derr := dial(&c, sid)
	testing.expect_value(t, derr, CallerError.None)
	if up_conn == nil {
		return
	}
	defer conn_destroy(up_conn)

	broker_conn := hold_broker_caller_reader(&fx.server, up_conn.stream_id)
	if !testing.expect(t, broker_conn != nil, "broker-side caller socket") {
		return
	}
	defer trans.connection_release(broker_conn)
	defer release_broker_caller_reader(broker_conn)
	// Use the default TCP buffer just as in the blocked-dial test above.
	_ = trans.connection_set_send_timeout(c.conn, 8 * time.Second)

	up := BlockedUpload{conn = up_conn}
	uth := thread.create_and_start_with_poly_data(&up, blocked_upload_proc)
	testing.expect(t, uth != nil, "upload thread")
	if uth == nil {
		return
	}
	defer {
		sync.atomic_store(&up.stop, true)
		release_broker_caller_reader(broker_conn)
		thread.join(uth)
		thread.destroy(uth)
	}

	blocked := false
	last := -1
	changed := time.now()
	wait_start := time.now()
	for time.since(wait_start) < 2 * time.Second {
		if sync.atomic_load(&up.done) {
			break
		}
		sent := sync.atomic_load(&up.sent)
		if sent != last {
			last = sent
			changed = time.now()
		} else if sent > 0 && time.since(changed) >= 150 * time.Millisecond {
			blocked = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(
		t,
		blocked,
		"DATA write did not block (done=%v sent=%d err=%v)",
		sync.atomic_load(&up.done),
		sync.atomic_load(&up.sent),
		sync.atomic_load(&up.err),
	)
	if !blocked {
		return
	}
	gen := caller_conn_gen(&c)

	attempt := DialAttempt {
		c   = &c,
		sid = sid,
	}
	dth := thread.create_and_start_with_poly_data(&attempt, dial_attempt_proc)
	testing.expect(t, dth != nil, "dial thread")
	if dth == nil {
		return
	}
	defer {
		thread.join(dth)
		thread.destroy(dth)
		if attempt.conn != nil {
			conn_destroy(attempt.conn)
			attempt.conn = nil
		}
	}

	dial_wait_start := time.now()
	for !sync.atomic_load(&attempt.done) && time.since(dial_wait_start) < 2 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&attempt.done), "dial did not fail after the stall window")
	if !sync.atomic_load(&attempt.done) {
		return
	}
	testing.expect_value(t, attempt.err, CallerError.Timeout)
	testing.expect(t, attempt.conn == nil, "stalled dial returned a stream")
	// The dial can return before the reader has installed the new session.
	replaced := false
	gen_wait := time.now()
	for time.since(gen_wait) < 2 * time.Second {
		if caller_conn_gen(&c) != gen {
			replaced = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, replaced, "stuck socket did not replace the session")

	up_done := time.now()
	for !sync.atomic_load(&up.done) && time.since(up_done) < 2 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&up.done), "upload still blocked after the session restart")

	log_wait := time.now()
	for time.since(log_wait) < 2 * time.Second {
		if stuck_log_has("connect_timeout") && stuck_log_has("session_lost") && stuck_log_has("disconnected") {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(
		t,
		stuck_log_has("\"event\":\"connect_timeout\",\"service_id\":\"demo/echo\",\"reason\":\"session_lost\""),
		"missing connect_timeout session_lost",
	)
	testing.expect(t, stuck_log_has("\"event\":\"disconnected\",\"reason\":\"stall\""), "missing disconnected stall")
	testing.expect(t, stuck_log_has("\"streams\":"), "missing stream count")

	release_broker_caller_reader(broker_conn)
	back := time.now()
	for !caller_is_connected(&c) && time.since(back) < 3 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, caller_is_connected(&c), "caller did not reconnect")
	c.config.dial_timeout = 3 * time.Second
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again == nil {
		return
	}
	defer conn_destroy(again)
	payload := []u8{'h', 'i'}
	n, werr := conn_write(again, payload)
	testing.expect_value(t, werr, ConnError.None)
	testing.expect_value(t, n, 2)
	buf: [8]u8
	rn, rerr := conn_read(again, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:rn]), "hi")
}

// Slow but still moving. The upload and the agent each take a breath between
// frames, so the socket keeps acknowledging bytes and the stall window must
// not drop the session. CONNECT is pulled ahead of DATA still queued, and
// returns while most of the upload is left.
@(test)
test_slow_upload_connect_succeeds_and_upload_survives :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	fx.server.max_stream_buffer = 32 * 1024

	sink: SinkUp
	sink_ep := sink_start(t, &sink)
	defer sink_stop(&sink)

	agent: ag.Agent
	run: AgentRunArg
	ath := start_registered_agent(t, &fx, sink_ep, &agent, &run)
	defer stop_agent(&agent, ath)
	ag.agent_test_relay_pace(&agent, 20 * time.Millisecond)
	defer ag.agent_test_relay_pace(&agent, 0)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 2 * time.Second,
				// Longer than a scheduling gap under a parallel suite, and
				// shorter than the paced upload below. A wall-clock kill
				// after CONNECT was queued would drop this session.
				send_stall_timeout = 2 * time.Second,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	up_conn, derr := dial(&c, sid)
	testing.expect_value(t, derr, CallerError.None)
	if up_conn == nil {
		return
	}
	defer conn_destroy(up_conn)

	// 8 KiB every 20 ms. The stall window is 2s; this upload stays slow for
	// twice that, so a jitter spike does not look like a stuck socket and
	// the upload is still going when the window has passed.
	up := BlockedUpload {
		conn   = up_conn,
		limit  = 4 * 1024 * 1024,
		gap_ns = int(20 * time.Millisecond),
	}
	uth := thread.create_and_start_with_poly_data(&up, blocked_upload_proc)
	testing.expect(t, uth != nil, "upload thread")
	if uth == nil {
		return
	}
	defer {
		sync.atomic_store(&up.gap_ns, 0)
		ag.agent_test_relay_pace(&agent, 0)
		thread.join(uth)
		thread.destroy(uth)
	}

	moving := false
	wait_start := time.now()
	for time.since(wait_start) < 2 * time.Second {
		if sync.atomic_load(&up.done) {
			break
		}
		if sync.atomic_load(&up.sent) >= 16 * 1024 {
			moving = true
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expectf(
		t,
		moving && !sync.atomic_load(&up.done),
		"upload was not still running (done=%v sent=%d err=%v)",
		sync.atomic_load(&up.done),
		sync.atomic_load(&up.sent),
		sync.atomic_load(&up.err),
	)
	if !moving || sync.atomic_load(&up.done) {
		return
	}
	sent_at_dial := sync.atomic_load(&up.sent)
	gen := caller_conn_gen(&c)

	dial_at := time.now()
	again, aerr := dial(&c, sid)
	dialed := time.since(dial_at)
	testing.expect_value(t, aerr, CallerError.None)
	testing.expectf(
		t,
		dialed < 1 * time.Second,
		"CONNECT waited behind the upload (dialed=%v sent=%d)",
		dialed,
		sent_at_dial,
	)
	testing.expect(t, !sync.atomic_load(&up.done), "upload finished before CONNECT returned")
	testing.expect(t, caller_conn_gen(&c) == gen, "stall closed a moving session")
	if again == nil {
		return
	}
	defer conn_destroy(again)

	// Stay slow for twice the stall window. Bytes are still moving.
	held := time.now()
	for time.since(held) < 4 * time.Second {
		if caller_conn_gen(&c) != gen || sync.atomic_load(&up.done) {
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, caller_conn_gen(&c) == gen, "stall closed a moving session")
	testing.expect(t, !sync.atomic_load(&up.done), "paced upload finished during the stall window")
	testing.expect(t, sync.atomic_load(&up.sent) > sent_at_dial, "paced upload made no progress")

	sync.atomic_store(&up.gap_ns, 0)
	ag.agent_test_relay_pace(&agent, 0)
	up_done := time.now()
	for !sync.atomic_load(&up.done) && time.since(up_done) < 5 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(
		t,
	sync.atomic_load(&up.done) && sync.atomic_load(&up.err) == .None && sync.atomic_load(&up.sent) > sent_at_dial,
		"upload did not survive (done=%v sent=%d at_dial=%d err=%v)",
		sync.atomic_load(&up.done),
		sync.atomic_load(&up.sent),
		sent_at_dial,
		sync.atomic_load(&up.err),
	)
	payload := []u8{'h', 'i'}
	n, werr := conn_write(again, payload)
	testing.expect_value(t, werr, ConnError.None)
	testing.expect_value(t, n, 2)
}

// Local service that reads and drops bytes. Nothing is written back, so a
// paced relay stays on the forward path instead of blocking on an echo.
SinkUp :: struct {
	ln: trans.Listener,
	th: ^thread.Thread,
}

sink_start :: proc(t: ^testing.T, up: ^SinkUp, loc := #caller_location) -> net.Endpoint {
	lerr: trans.TransportError
	up.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	_ = trans.listener_set_recv_timeout(&up.ln, 50 * time.Millisecond)
	ep, eerr := trans.listener_endpoint(up.ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	up.th = thread.create_and_start_with_poly_data(&up.ln, sink_accept_loop)
	return ep
}

sink_stop :: proc(up: ^SinkUp) {
	trans.listener_close(&up.ln)
	if up.th != nil {
		thread.join(up.th)
		thread.destroy(up.th)
		up.th = nil
	}
}

sink_accept_loop :: proc(ln: ^trans.Listener) {
	for {
		conn, err := trans.listener_accept(ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		thread.run_with_poly_data(conn, sink_read_loop)
	}
}

sink_read_loop :: proc(conn: ^trans.Connection) {
	defer trans.connection_destroy(conn)
	// accept() inherits the listener's SO_RCVTIMEO (50ms, so the accept
	// loop can notice close). A paced upload can go quiet for longer than
	// that under a loaded suite. Timeout is not the service going away.
	_ = trans.connection_set_recv_timeout(conn, 0)
	buf: [8 * 1024]u8
	for {
		_, err := trans.connection_read(conn, buf[:])
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
	}
}

stuck_logs: struct {
	mu:   sync.Mutex,
	text: [dynamic]u8,
}

stuck_log_sink :: proc(text: string) {
	sync.mutex_lock(&stuck_logs.mu)
	defer sync.mutex_unlock(&stuck_logs.mu)
	append(&stuck_logs.text, ..transmute([]u8)text)
}

stuck_log_has :: proc(part: string) -> bool {
	sync.mutex_lock(&stuck_logs.mu)
	defer sync.mutex_unlock(&stuck_logs.mu)
	return strings.contains(string(stuck_logs.text[:]), part)
}

// Pause only this broker reader. Its peer can still read, and a replacement
// caller session is unaffected.
hold_broker_caller_reader :: proc(server: ^brk.Server, stream_id: proto.StreamId) -> ^trans.Connection {
	conn, _, found := brk.relay_acquire_peer(server, stream_id, .Caller)
	if !found {
		return nil
	}
	sync.atomic_store(&conn.read_hook, rawptr(hold_caller_socket_read))
	return conn
}

hold_caller_socket_read :: proc(conn: ^trans.Connection) {
	for sync.atomic_load(&conn.read_hook) != nil && !sync.atomic_load(&conn.closed) {
		time.sleep(time.Millisecond)
	}
}

release_broker_caller_reader :: proc(conn: ^trans.Connection) {
	sync.atomic_store(&conn.read_hook, nil)
}

// Broker-side connection for the registered agent, referenced once.
test_agent_outbox :: proc(server: ^brk.Server) -> ^brk.ConnOutbox {
	if server == nil {
		return nil
	}
	sync.mutex_lock(&server.routing_mutex)
	conn: ^trans.Connection
	for _, c in server.agent_conns {
		conn = c
		break
	}
	sync.mutex_unlock(&server.routing_mutex)
	if conn == nil {
		return nil
	}
	return brk.server_lookup_outbox(server, conn)
}
