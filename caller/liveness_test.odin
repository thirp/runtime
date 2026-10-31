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

when ODIN_TEST {
// One dead backend must not take the caller's other services down with it.
// The agent bounds the local dial, so the caller hears CONNECT_FAILED. If a
// tombstone still outlives its cap while streams are open, new dials move
// to a fresh broker session and the open streams stay on the old one.
@(test)
test_unreachable_backend_keeps_healthy_stream :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	sink := syn_sink_start(t)
	defer syn_sink_stop(&sink)

	agent: ag.Agent
	run: AgentRunArg
	ath := start_two_service_agent(t, &fx, &agent, &run, echo_ep, sink.ep)
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
				dial_timeout = 10 * time.Second,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid_ok := must_service(t, SVC_A)
	sid_dead := must_service(t, SVC_B)
	stream, serr := dial(&c, sid_ok)
	testing.expect_value(t, serr, CallerError.None)
	if stream == nil {
		return
	}
	defer conn_destroy(stream)

	pump := LivePump{conn = stream, want = 60}
	pth := thread.create_and_start_with_poly_data(&pump, live_pump_proc)
	testing.expect(t, pth != nil, "pump thread")
	if pth == nil {
		return
	}

	healthy := 0
	healthy_bad := 0
	for !sync.atomic_load(&pump.done) {
		dead, derr := dial(&c, sid_dead)
		if dead != nil {
			conn_destroy(dead)
		}
		if derr != .LocalServiceUnavailable {
			healthy_bad += 1
			testing.expectf(t, false, "dead dial err=%v", derr)
			break
		}
		ok, oerr := dial(&c, sid_ok)
		if oerr != .None || ok == nil {
			healthy_bad += 1
			if ok != nil {
				conn_destroy(ok)
			}
			testing.expectf(t, false, "healthy dial err=%v", oerr)
			break
		}
		if !echo_one(ok, u8(healthy)) {
			healthy_bad += 1
			conn_destroy(ok)
			testing.expect(t, false, "healthy echo failed")
			break
		}
		conn_destroy(ok)
		healthy += 1
	}
	thread.join(pth)
	thread.destroy(pth)

	testing.expect(t, healthy_bad == 0, "a healthy dial failed beside the dead backend")
	testing.expect(t, healthy > 0, "no healthy dial completed")
	testing.expectf(t, pump.got == pump.want && pump.err == .None, "stream got %d/%d err=%v", pump.got, pump.want, pump.err)
}

// Cap with an open stream retires the session for new dials. The stream stays.
@(test)
test_tombstone_cap_keeps_live_stream :: proc(t: ^testing.T) {
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
				dial_timeout = 200 * time.Millisecond,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	stream, serr := dial(&c, sid)
	testing.expect_value(t, serr, CallerError.None)
	if stream == nil {
		return
	}
	defer conn_destroy(stream)
	testing.expect(t, echo_one(stream, 'a'), "stream did not echo before the cap")

	box := test_agent_outbox(&fx.server)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer brk.outbox_release(box)
	brk.outbox_set_writer_hold(box, true)
	defer brk.outbox_set_writer_hold(box, false)

	miss, merr := dial(&c, sid)
	testing.expect_value(t, merr, CallerError.Timeout)
	if miss != nil {
		conn_destroy(miss)
	}
	// The cap is at least TOMBSTONE_CAP_FLOOR after the dial returns.
	// It used to be 2 × 200ms, which dropped this stream.
	gen := caller_conn_gen(&c)
	armed := time.now()
	fired := false
	for time.since(armed) < 12 * time.Second {
		if caller_conn_gen(&c) != gen {
			fired = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, fired, "tombstone cap did not retire the session")
	testing.expect(t, time.since(armed) >= 6 * time.Second, "session retired before the tombstone cap")
	brk.outbox_set_writer_hold(box, false)
	testing.expect(t, echo_one(stream, 'b'), "live stream died when the tombstone cap fired")

	c.config.dial_timeout = 5 * time.Second
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again == nil {
		return
	}
	defer conn_destroy(again)
	testing.expect(t, echo_one(again, 'c'), "new dial after retire did not echo")
	testing.expect(t, echo_one(stream, 'd'), "retired stream died after the new dial")
}

// dial_timeout 0 never arms a tombstone, so a held CONNECT does not drop
// the session no matter how long the dial sits there.
@(test)
test_no_dial_timeout_does_not_tombstone :: proc(t: ^testing.T) {
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
				dial_timeout = 0,
				send_stall_timeout = -1,
				// 0 stays unbounded. The wait below is this idle override,
				// not the 10s production default dial_timeout 0 does not use.
				read_idle_timeout = 400 * time.Millisecond,
				ping_interval = 100 * time.Millisecond,
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
	late := LateDial{c = &c, sid = sid}
	lth := thread.create_and_start_with_poly_data(&late, late_dial_proc)
	testing.expect(t, lth != nil, "dial thread")
	if lth == nil {
		return
	}
	defer {
		brk.outbox_set_writer_hold(box, false)
		thread.join(lth)
		thread.destroy(lth)
		if late.conn != nil {
			conn_destroy(late.conn)
			late.conn = nil
		}
	}

	// Past the test idle override. dial_timeout 0 does not arm a tombstone
	// and does not fall through to DEFAULT_DIAL_TIMEOUT.
	time.sleep(c.config.read_idle_timeout + c.config.ping_interval)
	testing.expect(t, !sync.atomic_load(&late.done), "dial returned with no timeout")
	testing.expect(t, caller_conn_gen(&c) == gen, "session dropped with no dial timeout")
	testing.expect(t, caller_is_connected(&c), "session disconnected with no dial timeout")
	sync.mutex_lock(&c.mutex)
	tomb := c.pending_tombstone
	sync.mutex_unlock(&c.mutex)
	testing.expect(t, !tomb, "tombstone armed with no dial timeout")

	brk.outbox_set_writer_hold(box, false)
	wait := time.now()
	for !sync.atomic_load(&late.done) && time.since(wait) < 3 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&late.done), "dial did not finish after the hold")
	testing.expect_value(t, late.err, CallerError.None)
	if late.conn != nil {
		testing.expect(t, echo_one(late.conn, 'z'), "dial did not echo")
	}
}

// The broker pings. A splice that stops forwarding leaves the caller with
// no frames. The read-idle watchdog must drop that session in about 45s.
@(test)
test_idle_blackhole_drops_session :: proc(t: ^testing.T) {
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

	// The fixture closes a quiet session at 30s. That FIN would beat the
	// caller's 45s read-idle and the reason would be peer_close.
	fx.server.session_timeout = 3 * time.Minute

	proxy: ByteProxy
	byte_proxy_start(t, &proxy, broker_endpoint(t, &fx))
	defer byte_proxy_stop(&proxy)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = proxy.ep,
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 5 * time.Second,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	probe, perr := dial(&c, sid)
	testing.expect_value(t, perr, CallerError.None)
	if probe == nil {
		return
	}
	conn_destroy(probe)

	gen := caller_conn_gen(&c)
	byte_proxy_blackhole(&proxy)
	start := time.now()
	dropped := false
	for time.since(start) < 55 * time.Second {
		if caller_conn_gen(&c) != gen {
			dropped = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	elapsed := time.since(start)
	testing.expect(t, dropped, "idle blackhole did not drop the session")
	testing.expect(t, elapsed <= 50 * time.Second, "idle detection was later than 50s")
	testing.expect(t, elapsed >= 40 * time.Second, "idle detection fired early")
	testing.expectf(
		t,
		caller_last_disconnect_reason(&c) == LOG_REASON_IDLE,
		"disconnect reason %q",
		caller_last_disconnect_reason(&c),
	)

	for !caller_is_connected(&c) && time.since(start) < 70 * time.Second {
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, caller_is_connected(&c), "caller did not reconnect")
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again != nil {
		defer conn_destroy(again)
		testing.expect(t, echo_one(again, 'i'), "dial after idle reconnect failed")
	}
}

// A dial that gets no answer on a blackholed path must not leave the caller
// on that socket. The next dial, once a path exists, succeeds.
@(test)
test_blackhole_failed_dial_drops_session :: proc(t: ^testing.T) {
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

	fx.server.session_timeout = 3 * time.Minute

	proxy: ByteProxy
	byte_proxy_start(t, &proxy, broker_endpoint(t, &fx))
	defer byte_proxy_stop(&proxy)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = proxy.ep,
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 2 * time.Second,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	gen := caller_conn_gen(&c)
	byte_proxy_blackhole(&proxy)
	start := time.now()
	miss, merr := dial(&c, sid)
	testing.expect_value(t, merr, CallerError.Timeout)
	if miss != nil {
		conn_destroy(miss)
	}
	dropped := false
	for time.since(start) < 50 * time.Second {
		if caller_conn_gen(&c) != gen {
			dropped = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, dropped, "failed dial left the blackholed session up")
	testing.expect(t, time.since(start) <= 50 * time.Second, "failed dial was not detected within 50s")
	reason := caller_last_disconnect_reason(&c)
	testing.expect(
		t,
		reason == LOG_REASON_IDLE || reason == LOG_REASON_DEAD_PEER || reason == LOG_REASON_TOMBSTONE,
		"disconnect reason was not idle, dead_peer, or tombstone",
	)

	for !caller_is_connected(&c) && time.since(start) < 60 * time.Second {
		time.sleep(20 * time.Millisecond)
	}
	c.config.dial_timeout = 5 * time.Second
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again != nil {
		defer conn_destroy(again)
		testing.expect(t, echo_one(again, 'f'), "dial after blackhole recovery failed")
	}
}

// Caller Pings keep a quiet session up when the broker heartbeat is slow.
@(test)
test_healthy_idle_session_survives :: proc(t: ^testing.T) {
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

	// The fixture heartbeat is 30s, longer than this test's idle limit.
	// Survival is the caller's own Ping, not the broker's.
	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 5 * time.Second,
				send_stall_timeout = -1,
				read_idle_timeout = 1500 * time.Millisecond,
				ping_interval = 400 * time.Millisecond,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	gen := caller_conn_gen(&c)
	time.sleep(4 * time.Second)
	testing.expect(t, caller_conn_gen(&c) == gen, "healthy idle session was replaced")
	testing.expect(t, caller_is_connected(&c), "healthy idle session disconnected")
	sid := must_service(t, TEST_SERVICE)
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again != nil {
		defer conn_destroy(again)
		testing.expect(t, echo_one(again, 'h'), "dial after healthy idle failed")
	}
}

// Idle and ping overrides, shorter than the 60s broker heartbeat.
// Survival is our Ping. Nothing is echoed during the wait: that would
// move last_recv on its own.
@(test)
test_slow_broker_heartbeat_does_not_idle :: proc(t: ^testing.T) {
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

	// Broker heartbeat stays slower than the caller's idle override, so a
	// Pong to our Ping is what keeps the session up.
	fx.server.heartbeat_interval = 60 * time.Second
	fx.server.session_timeout = 30 * time.Second

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 5 * time.Second,
				send_stall_timeout = -1,
				read_idle_timeout = 1500 * time.Millisecond,
				ping_interval = 400 * time.Millisecond,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	gen := caller_conn_gen(&c)
	time.sleep(4 * time.Second)
	testing.expect(t, caller_conn_gen(&c) == gen, "slow broker heartbeat replaced the session")
	testing.expect(t, caller_is_connected(&c), "slow broker heartbeat dropped the session")
	sid := must_service(t, TEST_SERVICE)
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again != nil {
		defer conn_destroy(again)
		testing.expect(t, echo_one(again, 's'), "dial after slow heartbeat idle failed")
	}
}

@(test)
test_dial_timeout_1s_dead_backend_does_not_retire :: proc(t: ^testing.T) {
	short_dial_dead_backend(t, 1 * time.Second)
}

@(test)
test_dial_timeout_2s_dead_backend_does_not_retire :: proc(t: ^testing.T) {
	short_dial_dead_backend(t, 2 * time.Second)
}

// OPEN_FAILED arrives at the agent local-dial default (~5s). The cap floor
// is 7s, so a 1s or 2s dial_timeout must not retire the session. A new
// healthy dial can sit behind the tombstone until that OPEN_FAILED.
short_dial_dead_backend :: proc(t: ^testing.T, dt: time.Duration) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	sink := syn_sink_start(t)
	defer syn_sink_stop(&sink)

	agent: ag.Agent
	run: AgentRunArg
	ath := start_two_service_agent(t, &fx, &agent, &run, echo_ep, sink.ep)
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
				dial_timeout = dt,
				send_stall_timeout = -1,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid_ok := must_service(t, SVC_A)
	sid_dead := must_service(t, SVC_B)
	stream, serr := dial(&c, sid_ok)
	testing.expect_value(t, serr, CallerError.None)
	if stream == nil {
		return
	}
	defer conn_destroy(stream)
	testing.expect(t, echo_one(stream, 'a'), "healthy stream did not echo")

	gen := caller_conn_gen(&c)
	dead, derr := dial(&c, sid_dead)
	testing.expect_value(t, derr, CallerError.Timeout)
	if dead != nil {
		conn_destroy(dead)
	}
	armed := time.now()
	testing.expect(t, caller_conn_gen(&c) == gen, "dead dial retired the session")
	testing.expect(t, echo_one(stream, 'b'), "healthy stream died while the dead dial was tombstoned")

	// Longer than the agent's local dial, shorter than a second cap.
	c.config.dial_timeout = 8 * time.Second
	ok, oerr := dial(&c, sid_ok)
	testing.expect_value(t, oerr, CallerError.None)
	if ok != nil {
		testing.expect(t, echo_one(ok, 'c'), "healthy dial behind the tombstone failed")
		conn_destroy(ok)
	}
	testing.expect(t, caller_conn_gen(&c) == gen, "healthy dial retired the session")

	left := 8 * time.Second - time.since(armed)
	if left > 0 {
		time.sleep(left)
	}
	testing.expect(t, caller_conn_gen(&c) == gen, "cap floor retired the session")
	testing.expect(t, caller_is_connected(&c), "cap floor dropped the session")
	testing.expect(t, echo_one(stream, 'd'), "healthy stream died at the cap floor")

	c.config.dial_timeout = dt
	again, aerr := dial(&c, sid_ok)
	testing.expect_value(t, aerr, CallerError.None)
	if again != nil {
		testing.expect(t, echo_one(again, 'e'), "healthy dial after the floor failed")
		conn_destroy(again)
	}
}

// Three retires. The third drops the oldest drain and that stream dies.
// The newer two stay up. At most MAX_RETIRED_SESSIONS drains keep running.
@(test)
test_retired_session_cap_drops_oldest :: proc(t: ^testing.T) {
	delete(drain_cap_logs.text)
	drain_cap_logs.text = nil
	defer {
		delete(drain_cap_logs.text)
		drain_cap_logs.text = nil
	}
	logger: log.Logger
	log.logger_init(&logger, .Info, drain_cap_log_sink)

	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	// The fixture's 30s session timeout would FIN a drain this test still
	// needs. The cap itself is what the test is timing.
	fx.server.session_timeout = 3 * time.Minute

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

	sid := must_service(t, TEST_SERVICE)
	s1, e1 := dial(&c, sid)
	testing.expect_value(t, e1, CallerError.None)
	if s1 == nil {
		return
	}
	defer conn_destroy(s1)
	testing.expect(t, echo_one(s1, '1'), "stream 1 did not echo")
	testing.expect(t, retire_for_cap(t, &c, sid, box), "first retire")
	testing.expect(t, echo_one(s1, 'a'), "stream 1 died on the first retire")

	s2, e2 := dial(&c, sid)
	testing.expect_value(t, e2, CallerError.None)
	if s2 == nil {
		return
	}
	defer conn_destroy(s2)
	testing.expect(t, echo_one(s2, '2'), "stream 2 did not echo")
	testing.expect(t, retire_for_cap(t, &c, sid, box), "second retire")
	testing.expect(t, echo_one(s1, 'b'), "stream 1 died on the second retire")
	testing.expect(t, echo_one(s2, 'c'), "stream 2 died on the second retire")

	s3, e3 := dial(&c, sid)
	testing.expect_value(t, e3, CallerError.None)
	if s3 == nil {
		return
	}
	defer conn_destroy(s3)
	testing.expect(t, echo_one(s3, '3'), "stream 3 did not echo")
	testing.expect(t, retire_for_cap(t, &c, sid, box), "third retire")

	died := false
	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		if !echo_one(s1, 'x') {
			died = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, died, "oldest retired stream stayed up past the cap")
	testing.expect(t, caller_running_drains(&c) <= MAX_RETIRED_SESSIONS, "more than 2 drains still running")
	testing.expect(t, echo_one(s2, 'd'), "stream 2 died when the oldest drain was dropped")
	testing.expect(t, echo_one(s3, 'e'), "stream 3 died when the oldest drain was dropped")
	testing.expect(
		t,
		drain_cap_log_has("\"event\":\"drain_dropped\"") && drain_cap_log_has("\"reason\":\"retired_limit\""),
		"missing drain_dropped retired_limit",
	)
}

retire_for_cap :: proc(t: ^testing.T, c: ^Caller, sid: proto.ServiceId, box: ^brk.ConnOutbox) -> bool {
	gen := caller_conn_gen(c)
	brk.outbox_set_writer_hold(box, true)
	defer brk.outbox_set_writer_hold(box, false)
	miss, merr := dial(c, sid)
	if merr != .Timeout {
		testing.expect_value(t, merr, CallerError.Timeout)
		if miss != nil {
			conn_destroy(miss)
		}
		return false
	}
	if miss != nil {
		conn_destroy(miss)
	}
	armed := time.now()
	fired := false
	for time.since(armed) < 12 * time.Second {
		if caller_conn_gen(c) != gen {
			fired = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	if !fired || time.since(armed) < 6 * time.Second {
		testing.expect(t, fired, "tombstone cap did not retire")
		testing.expect(t, time.since(armed) >= 6 * time.Second, "retire fired before the cap floor")
		return false
	}
	for !caller_is_connected(c) && time.since(armed) < 20 * time.Second {
		time.sleep(20 * time.Millisecond)
	}
	return caller_is_connected(c)
}

drain_cap_logs: struct {
	mu:   sync.Mutex,
	text: [dynamic]u8,
}

drain_cap_log_sink :: proc(text: string) {
	sync.mutex_lock(&drain_cap_logs.mu)
	defer sync.mutex_unlock(&drain_cap_logs.mu)
	append(&drain_cap_logs.text, ..transmute([]u8)text)
}

drain_cap_log_has :: proc(part: string) -> bool {
	sync.mutex_lock(&drain_cap_logs.mu)
	defer sync.mutex_unlock(&drain_cap_logs.mu)
	if len(drain_cap_logs.text) == 0 {
		return false
	}
	return strings.contains(string(drain_cap_logs.text[:]), part)
}

LivePump :: struct {
	conn: ^Conn,
	want: int,
	got:  int,
	err:  ConnError,
	done: bool,
}

live_pump_proc :: proc(p: ^LivePump) {
	defer sync.atomic_store(&p.done, true)
	for i in 0 ..< p.want {
		if !echo_one(p.conn, u8(i)) {
			p.err = .Closed
			return
		}
		p.got += 1
		time.sleep(time.Second)
	}
}

echo_one :: proc(conn: ^Conn, b: u8) -> bool {
	buf := [1]u8{b}
	n, werr := conn_write(conn, buf[:])
	if werr != .None || n != 1 {
		return false
	}
	got: [1]u8
	rn, rerr := conn_read(conn, got[:])
	return rerr == .None && rn == 1 && got[0] == b
}

ByteProxy :: struct {
	ln:    trans.Listener,
	ep:    net.Endpoint,
	target: net.Endpoint,
	th:    ^thread.Thread,
	stop:  bool,
	mu:    sync.Mutex,
	links: [dynamic]^ProxyLink,
}

ProxyLink :: struct {
	proxy:  ^ByteProxy,
	client: ^trans.Connection,
	up:     ^trans.Connection,
	pause:  bool,
	stop:   bool,
}

byte_proxy_start :: proc(t: ^testing.T, p: ^ByteProxy, target: net.Endpoint, loc := #caller_location) {
	p^ = {}
	p.target = target
	lerr: trans.TransportError
	p.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	_ = trans.listener_set_recv_timeout(&p.ln, 50 * time.Millisecond)
	ep, eerr := trans.listener_endpoint(p.ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	p.ep = ep
	p.th = thread.create_and_start_with_poly_data(p, byte_proxy_accept)
	testing.expect(t, p.th != nil, "proxy thread")
}

byte_proxy_stop :: proc(p: ^ByteProxy) {
	if p == nil {
		return
	}
	sync.atomic_store(&p.stop, true)
	trans.listener_close(&p.ln)
	sync.mutex_lock(&p.mu)
	for link in p.links {
		if link == nil {
			continue
		}
		sync.atomic_store(&link.stop, true)
		if link.client != nil {
			trans.connection_shutdown_both(link.client)
		}
		if link.up != nil {
			trans.connection_shutdown_both(link.up)
		}
	}
	sync.mutex_unlock(&p.mu)
	if p.th != nil {
		thread.join(p.th)
		thread.destroy(p.th)
		p.th = nil
	}
	for {
		sync.mutex_lock(&p.mu)
		n := len(p.links)
		sync.mutex_unlock(&p.mu)
		if n == 0 {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	delete(p.links)
	p.links = nil
}

// Stop forwarding on splices that already exist. A later accept (the
// caller's reconnect) starts unpaused, so there is a path again.
byte_proxy_blackhole :: proc(p: ^ByteProxy) {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	for link in p.links {
		if link != nil {
			sync.atomic_store(&link.pause, true)
		}
	}
}

byte_proxy_accept :: proc(p: ^ByteProxy) {
	for !sync.atomic_load(&p.stop) {
		client, err := trans.listener_accept(&p.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		if sync.atomic_load(&p.stop) {
			trans.connection_destroy(client)
			return
		}
		up, derr := trans.connection_dial(p.target)
		if derr != .None {
			trans.connection_destroy(client)
			continue
		}
		link, aerr := new(ProxyLink)
		if aerr != .None {
			trans.connection_destroy(client)
			trans.connection_destroy(up)
			continue
		}
		link.proxy = p
		link.client = client
		link.up = up
		sync.mutex_lock(&p.mu)
		append(&p.links, link)
		sync.mutex_unlock(&p.mu)
		thread.run_with_poly_data(link, proxy_splice)
	}
}

proxy_splice :: proc(link: ^ProxyLink) {
	p := link.proxy
	defer proxy_link_done(link)
	_ = trans.connection_set_recv_timeout(link.client, 20 * time.Millisecond)
	_ = trans.connection_set_recv_timeout(link.up, 20 * time.Millisecond)
	buf: [4096]u8
	for !sync.atomic_load(&p.stop) && !sync.atomic_load(&link.stop) {
		if sync.atomic_load(&link.pause) {
			time.sleep(5 * time.Millisecond)
			continue
		}
		if !proxy_copy(link.client, link.up, buf[:]) {
			return
		}
		if sync.atomic_load(&link.pause) || sync.atomic_load(&link.stop) || sync.atomic_load(&p.stop) {
			continue
		}
		if !proxy_copy(link.up, link.client, buf[:]) {
			return
		}
	}
}

proxy_copy :: proc(from, to: ^trans.Connection, buf: []u8) -> bool {
	n, err := trans.connection_read(from, buf)
	if err == .Timeout {
		return true
	}
	if err != .None {
		return false
	}
	return trans.connection_write(to, buf[:n]) == .None
}

proxy_link_done :: proc(link: ^ProxyLink) {
	p := link.proxy
	sync.mutex_lock(&p.mu)
	for i := 0; i < len(p.links); i += 1 {
		if p.links[i] == link {
			ordered_remove(&p.links, i)
			break
		}
	}
	sync.mutex_unlock(&p.mu)
	if link.client != nil {
		trans.connection_destroy(link.client)
		link.client = nil
	}
	if link.up != nil {
		trans.connection_destroy(link.up)
		link.up = nil
	}
	free(link)
}
}
