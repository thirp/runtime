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

SVC_A :: "demo/svc-a"
SVC_B :: "demo/svc-b"
BANNER_A :: "banner-a"
BANNER_B :: "banner-b"

// Theo's Q1. Two services, one caller. The broker-to-agent outbox is held
// so dial(svc-a) sends CONNECT and times out. dial(svc-b) then runs and the
// hold is released. svc-a's CONNECT_OK must not become svc-b's stream.
@(test)
test_late_connect_ok_does_not_bind_next_service :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	banner_a: BannerUp
	ep_a := banner_start(t, &banner_a, BANNER_A)
	defer banner_stop(&banner_a)
	banner_b: BannerUp
	ep_b := banner_start(t, &banner_b, BANNER_B)
	defer banner_stop(&banner_b)

	agent: ag.Agent
	run: AgentRunArg
	ath := start_two_service_agent(t, &fx, &agent, &run, ep_a, ep_b)
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
				dial_timeout = 400 * time.Millisecond,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	box := test_agent_outbox(&fx.server)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer brk.outbox_release(box)
	brk.outbox_set_writer_hold(box, true)
	defer brk.outbox_set_writer_hold(box, false)

	sid_a := must_service(t, SVC_A)
	sid_b := must_service(t, SVC_B)
	gen := caller_conn_gen(&c)
	first, ferr := dial(&c, sid_a)
	testing.expect_value(t, ferr, CallerError.Timeout)
	testing.expect(t, first == nil, "timed-out dial returned a stream")
	if first != nil {
		conn_destroy(first)
		return
	}
	testing.expect(t, caller_conn_gen(&c) == gen, "dial timeout replaced the session")
	queued := agent_outbox_streams(box)
	testing.expect(t, queued >= 1, "CONNECT did not reach the agent outbox")
	if queued < 1 {
		return
	}

	// svc-b gets a longer deadline than the tombstone cap (2 × 400ms) so it
	// can wait the late reply out. The cap itself stays on the 400ms clock.
	c.config.dial_timeout = 2 * time.Second
	late := LateDial{c = &c, sid = sid_b}
	lth := thread.create_and_start_with_poly_data(&late, late_dial_proc)
	testing.expect(t, lth != nil, "dial thread")
	if lth == nil {
		return
	}
	defer {
		thread.join(lth)
		thread.destroy(lth)
		if late.conn != nil {
			conn_destroy(late.conn)
			late.conn = nil
		}
	}

	// On the broken caller, svc-b's CONNECT is queued behind svc-a's OPEN.
	// Release only after that, or after a bound short of the tombstone cap,
	// so the late CONNECT_OK is delivered while svc-b is in dial.
	wait_b := time.now()
	for time.since(wait_b) < 300 * time.Millisecond {
		if agent_outbox_streams(box) > queued || sync.atomic_load(&late.done) {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	brk.outbox_set_writer_hold(box, false)

	done := time.now()
	for !sync.atomic_load(&late.done) && time.since(done) < 2 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&late.done), "second dial did not return")
	if !sync.atomic_load(&late.done) {
		return
	}
	testing.expect_value(t, late.err, CallerError.None)
	testing.expect(t, late.conn != nil, "second dial returned no stream")
	testing.expect(t, caller_conn_gen(&c) == gen, "late CONNECT_OK dropped the session")
	if late.conn == nil {
		return
	}
	got := read_banner(t, late.conn, len(BANNER_B))
	testing.expectf(t, got == BANNER_B, "dial(svc-b) read %q", got)
}

// The tombstone does not wait forever. Past the cap (at least
// TOMBSTONE_CAP_FLOOR) the session drops, and the disconnect log says why.
@(test)
test_tombstone_cap_drops_the_session :: proc(t: ^testing.T) {
	delete(tomb_logs.text)
	tomb_logs.text = nil
	defer {
		delete(tomb_logs.text)
		tomb_logs.text = nil
	}
	logger: log.Logger
	log.logger_init(&logger, .Info, tomb_log_sink)

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
				dial_timeout = 200 * time.Millisecond,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	box := test_agent_outbox(&fx.server)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer brk.outbox_release(box)
	brk.outbox_set_writer_hold(box, true)
	defer brk.outbox_set_writer_hold(box, false)

	sid := must_service(t, TEST_SERVICE)
	gen := caller_conn_gen(&c)
	first, ferr := dial(&c, sid)
	testing.expect_value(t, ferr, CallerError.Timeout)
	testing.expect(t, first == nil, "timed-out dial returned a stream")
	if first != nil {
		conn_destroy(first)
	}
	testing.expect(t, caller_conn_gen(&c) == gen, "dial timeout replaced the session")
	returned := time.now()

	fired := false
	for time.since(returned) < 12 * time.Second {
		if caller_conn_gen(&c) != gen {
			fired = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, fired, "tombstone cap did not drop the session")
	testing.expect(
		t,
		time.since(returned) >= 6 * time.Second,
		"session dropped before the tombstone cap",
	)
	log_wait := time.now()
	for time.since(log_wait) < 1 * time.Second {
		if tomb_log_has("\"event\":\"disconnected\"") && tomb_log_has("\"reason\":\"tombstone\"") {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(
		t,
		tomb_log_has("\"event\":\"disconnected\"") && tomb_log_has("\"reason\":\"tombstone\""),
		"missing disconnected tombstone",
	)
}

// CONNECT_FAILED for the abandoned CONNECT frees the slot. The session
// stays up, and the next dial reaches its own service.
@(test)
test_late_connect_failed_clears_tombstone :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	banner_b: BannerUp
	ep_b := banner_start(t, &banner_b, BANNER_B)
	defer banner_stop(&banner_b)

	agent: ag.Agent
	testing.expect_value(
		t,
		ag.agent_init(
			&agent,
			ag.AgentConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_HOST, insecure = true},
		),
		ag.AgentError.None,
	)
	sid_a := must_service(t, SVC_A)
	sid_b := must_service(t, SVC_B)
	testing.expect_value(
		t,
		ag.register_service(&agent, sid_a, ag.LocalTarget{address = trans.loopback_endpoint(1)}),
		ag.AgentError.None,
	)
	testing.expect_value(
		t,
		ag.register_service(&agent, sid_b, ag.LocalTarget{address = ep_b}),
		ag.AgentError.None,
	)
	run: AgentRunArg
	run.agent = &agent
	ath := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer stop_agent(&agent, ath)
	wait_agent_connected(t, &agent)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 300 * time.Millisecond,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	box := test_agent_outbox(&fx.server)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer brk.outbox_release(box)
	brk.outbox_set_writer_hold(box, true)
	defer brk.outbox_set_writer_hold(box, false)

	gen := caller_conn_gen(&c)
	first, ferr := dial(&c, sid_a)
	testing.expect_value(t, ferr, CallerError.Timeout)
	testing.expect(t, first == nil, "timed-out dial returned a stream")
	if first != nil {
		conn_destroy(first)
	}
	testing.expect(t, caller_conn_gen(&c) == gen, "dial timeout replaced the session")

	c.config.dial_timeout = 2 * time.Second
	late := LateDial{c = &c, sid = sid_b}
	lth := thread.create_and_start_with_poly_data(&late, late_dial_proc)
	testing.expect(t, lth != nil, "dial thread")
	if lth == nil {
		return
	}
	defer {
		thread.join(lth)
		thread.destroy(lth)
		if late.conn != nil {
			conn_destroy(late.conn)
			late.conn = nil
		}
	}
	// Let the second dial reach the slot, then deliver the OPEN_FAILED.
	entered := time.now()
	for time.since(entered) < 50 * time.Millisecond && !sync.atomic_load(&late.done) {
		time.sleep(5 * time.Millisecond)
	}
	brk.outbox_set_writer_hold(box, false)

	done := time.now()
	for !sync.atomic_load(&late.done) && time.since(done) < 2 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&late.done), "second dial did not return")
	testing.expect_value(t, late.err, CallerError.None)
	testing.expect(t, caller_conn_gen(&c) == gen, "CONNECT_FAILED dropped the session")
	if late.conn == nil {
		return
	}
	got := read_banner(t, late.conn, len(BANNER_B))
	testing.expectf(t, got == BANNER_B, "dial(svc-b) read %q", got)
}

// A replacement session at the same address is not the session a CONNECT
// was written for. The predicate is what the dial's write compares.
@(test)
test_reused_broker_pointer_does_not_match_old_session :: proc(t: ^testing.T) {
	placeholder: trans.Connection
	testing.expect(t, !dial_broker_matches(nil, nil, 1, 1))
	testing.expect(t, !dial_broker_matches(&placeholder, &placeholder, 2, 1))
	testing.expect(t, dial_broker_matches(&placeholder, &placeholder, 4, 4))

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
				dial_timeout = 2 * time.Second,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	reused := 0
	for _ in 0 ..< 5 {
		sync.mutex_lock(&c.mutex)
		old := c.conn
		old_gen := c.conn_gen
		held := old != nil && trans.connection_acquire(old)
		sync.mutex_unlock(&c.mutex)
		testing.expect(t, held, "session had no connection")
		if !held {
			return
		}
		trans.connection_shutdown_both(old)
		trans.connection_release(old)

		back := false
		wait := time.now()
		for time.since(wait) < 2 * time.Second {
			sync.mutex_lock(&c.mutex)
			cur := c.conn
			gen := c.conn_gen
			up := c.connected && cur != nil && gen != old_gen
			sync.mutex_unlock(&c.mutex)
			if up {
				testing.expect(t, !dial_broker_matches(cur, old, gen, old_gen))
				if cur == old {
					reused += 1
				}
				back = true
				break
			}
			time.sleep(5 * time.Millisecond)
		}
		testing.expect(t, back, "caller did not reconnect")
		if !back {
			return
		}
	}
	_ = reused

	sid := must_service(t, TEST_SERVICE)
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

LateDial :: struct {
	c:    ^Caller,
	sid:  proto.ServiceId,
	conn: ^Conn,
	err:  CallerError,
	done: bool,
}

late_dial_proc :: proc(a: ^LateDial) {
	a.conn, a.err = dial(a.c, a.sid)
	sync.atomic_store(&a.done, true)
}

BannerUp :: struct {
	ln:   trans.Listener,
	th:   ^thread.Thread,
	text: string,
}

BannerConn :: struct {
	conn: ^trans.Connection,
	text: string,
}

banner_start :: proc(t: ^testing.T, up: ^BannerUp, text: string, loc := #caller_location) -> net.Endpoint {
	up.text = text
	lerr: trans.TransportError
	up.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	_ = trans.listener_set_recv_timeout(&up.ln, 50 * time.Millisecond)
	ep, eerr := trans.listener_endpoint(up.ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	up.th = thread.create_and_start_with_poly_data(up, banner_accept_loop)
	testing.expect(t, up.th != nil, "banner thread")
	return ep
}

banner_stop :: proc(up: ^BannerUp) {
	if up == nil {
		return
	}
	trans.listener_close(&up.ln)
	if up.th != nil {
		thread.join(up.th)
		thread.destroy(up.th)
		up.th = nil
	}
}

banner_accept_loop :: proc(up: ^BannerUp) {
	for {
		conn, err := trans.listener_accept(&up.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		arg, aerr := new(BannerConn)
		if aerr != .None {
			trans.connection_destroy(conn)
			return
		}
		arg.conn = conn
		arg.text = up.text
		thread.run_with_poly_data(arg, banner_serve_proc)
	}
}

banner_serve_proc :: proc(arg: ^BannerConn) {
	conn := arg.conn
	text := arg.text
	free(arg)
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_recv_timeout(conn, 0)
	if trans.connection_write(conn, transmute([]u8)text) != .None {
		return
	}
	buf: [256]u8
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

read_banner :: proc(t: ^testing.T, conn: ^Conn, n: int) -> string {
	buf := make([]u8, n)
	defer delete(buf)
	rd := BannerRead{conn = conn, buf = buf}
	th := thread.create_and_start_with_poly_data(&rd, banner_read_proc)
	if th == nil {
		testing.expect(t, false, "banner read thread")
		return ""
	}
	wait := time.now()
	for !sync.atomic_load(&rd.done) && time.since(wait) < 2 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	if !sync.atomic_load(&rd.done) {
		conn_close(conn)
	}
	thread.join(th)
	thread.destroy(th)
	if rd.err != .None || rd.n != n {
		testing.expectf(t, false, "banner read err=%v n=%d", rd.err, rd.n)
		return ""
	}
	return string(buf[:rd.n])
}

BannerRead :: struct {
	conn: ^Conn,
	buf:  []u8,
	n:    int,
	err:  ConnError,
	done: bool,
}

banner_read_proc :: proc(rd: ^BannerRead) {
	got := 0
	for got < len(rd.buf) {
		n, err := conn_read(rd.conn, rd.buf[got:])
		got += n
		rd.n = got
		if err != .None {
			rd.err = err
			break
		}
		if n == 0 {
			rd.err = .Closed
			break
		}
	}
	sync.atomic_store(&rd.done, true)
}

start_two_service_agent :: proc(
	t: ^testing.T,
	fx: ^TestBroker,
	agent: ^ag.Agent,
	run: ^AgentRunArg,
	ep_a, ep_b: net.Endpoint,
	loc := #caller_location,
) -> ^thread.Thread {
	testing.expect_value(
		t,
		ag.agent_init(
			agent,
			ag.AgentConfig{broker = broker_endpoint(t, fx, loc), token = TEST_TOKEN_HOST, insecure = true},
		),
		ag.AgentError.None,
		loc,
	)
	testing.expect_value(
		t,
		ag.register_service(agent, must_service(t, SVC_A, loc), ag.LocalTarget{address = ep_a}),
		ag.AgentError.None,
		loc,
	)
	testing.expect_value(
		t,
		ag.register_service(agent, must_service(t, SVC_B, loc), ag.LocalTarget{address = ep_b}),
		ag.AgentError.None,
		loc,
	)
	run.agent = agent
	th := thread.create_and_start_with_poly_data(run, agent_run_proc)
	wait_agent_connected(t, agent, loc)
	return th
}

agent_outbox_streams :: proc(box: ^brk.ConnOutbox) -> int {
	if box == nil {
		return 0
	}
	sync.mutex_lock(&box.mutex)
	defer sync.mutex_unlock(&box.mutex)
	return len(box.queues)
}

tomb_logs: struct {
	mu:   sync.Mutex,
	text: [dynamic]u8,
}

tomb_log_sink :: proc(text: string) {
	sync.mutex_lock(&tomb_logs.mu)
	defer sync.mutex_unlock(&tomb_logs.mu)
	append(&tomb_logs.text, ..transmute([]u8)text)
}

tomb_log_has :: proc(part: string) -> bool {
	sync.mutex_lock(&tomb_logs.mu)
	defer sync.mutex_unlock(&tomb_logs.mu)
	if len(tomb_logs.text) == 0 {
		return false
	}
	return strings.contains(string(tomb_logs.text[:]), part)
}
