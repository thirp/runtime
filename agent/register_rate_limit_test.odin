package agent

import brk "../broker"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Stop the agent at the start of a RATE_LIMITED wait at least this long.
// The cap is 15s; a sleep that ignores stop would still be in that wait.
REGISTER_BACKOFF_STOP_AFTER :: 7 * time.Second

@(private)
backoff_mu: sync.Mutex

@(private)
backoff_watch: ^Agent

@(private)
backoff_after: time.Duration

@(private)
backoff_fired: bool

@(private)
backoff_fired_at: time.Time

agent_test_arm_backoff_stop :: proc(agent: ^Agent, after: time.Duration) {
	sync.mutex_lock(&backoff_mu)
	backoff_watch = agent
	backoff_after = after
	backoff_fired = false
	backoff_fired_at = {}
	sync.mutex_unlock(&backoff_mu)
}

agent_test_clear_backoff_stop :: proc() {
	sync.mutex_lock(&backoff_mu)
	backoff_watch = nil
	backoff_after = 0
	backoff_fired = false
	sync.mutex_unlock(&backoff_mu)
}

// Called on the handshake thread just before the RATE_LIMITED sleep.
agent_test_note_register_backoff :: proc(agent: ^Agent, delay: time.Duration) {
	sync.mutex_lock(&backoff_mu)
	watch := backoff_watch
	after := backoff_after
	already := backoff_fired
	sync.mutex_unlock(&backoff_mu)
	if already || agent == nil || agent != watch || delay < after {
		return
	}
	sync.mutex_lock(&backoff_mu)
	if backoff_fired || agent != backoff_watch {
		sync.mutex_unlock(&backoff_mu)
		return
	}
	backoff_fired = true
	backoff_fired_at = time.now()
	sync.mutex_unlock(&backoff_mu)
	agent_stop(agent)
}

agent_test_backoff_stop_fired :: proc() -> (fired: bool, at: time.Time) {
	sync.mutex_lock(&backoff_mu)
	defer sync.mutex_unlock(&backoff_mu)
	return backoff_fired, backoff_fired_at
}

rl_log_sink :: proc(text: string) {
	cap := (^log.Capture)(context.user_ptr)
	if cap == nil {
		return
	}
	log.capture_sink(cap, text)
}

capture_text :: proc(cap: ^log.Capture) -> string {
	sync.mutex_lock(&cap.mutex)
	defer sync.mutex_unlock(&cap.mutex)
	return strings.clone(string(cap.text[:]))
}

// More services than the broker's register burst. The agent keeps the session,
// waits out RATE_LIMITED, and ends with every service registered.
@(test)
test_agent_register_rate_limited_registers_all :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	fx.server.register_rate = brk.rate_limit_config(5, 2 * time.Second)
	// Short heartbeat: the broker Pings while a register wait is in progress.
	fx.server.heartbeat_interval = 300 * time.Millisecond

	cap: log.Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	logger: log.Logger
	log.logger_init(&logger, .Info, rl_log_sink)
	context.user_ptr = &cap

	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig {
				broker   = broker_endpoint(t, &fx),
				token    = TEST_TOKEN_HOST,
				insecure = true,
				logger   = &logger,
			},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	N :: 12
	local := trans.loopback_endpoint(9)
	for i in 0 ..< N {
		name := fmt.tprintf("demo/svc%02d", i)
		testing.expect_value(
			t,
			register_service(&agent, must_service(t, name), LocalTarget{address = local}),
			AgentError.None,
		)
	}

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc, context)
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	start := time.now()
	for time.since(start) < 15 * time.Second && brk.service_count(&fx.reg) < N {
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, brk.service_count(&fx.reg), N)
	// Past the point where a stale partial set would have settled.
	time.sleep(1500 * time.Millisecond)
	testing.expect_value(t, brk.service_count(&fx.reg), N)
	testing.expect(t, agent_is_connected(&agent))
	_, sessions, _ := brk.registry_metrics(&fx.reg)
	testing.expect_value(t, sessions, 1)

	text := capture_text(&cap)
	defer delete(text)
	testing.expect(t, strings.contains(text, fmt.tprintf("\"event\":\"%s\"", LOG_EVENT_RATE_LIMITED)))
	testing.expect(t, strings.contains(text, fmt.tprintf("\"event\":\"%s\"", LOG_EVENT_REGISTERED)))
	testing.expect_value(t, strings.count(text, fmt.tprintf("\"event\":\"%s\"", LOG_EVENT_REGISTERED)), N)
	testing.expect(t, !strings.contains(text, "\"event\":\"auth_failed\""))
	testing.expect(t, !strings.contains(text, TEST_TOKEN_HOST))
}

// A long RATE_LIMITED wait must still notice stop. The armed stop runs at the
// start of a wait of at least 7s; joining has to finish well under that.
@(test)
test_agent_stop_during_register_backoff :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	// One token, no refill during the test, so every retry is RATE_LIMITED
	// and the wait doubles up to the 15s cap.
	fx.server.register_rate = brk.rate_limit_config(1, time.Hour)

	agent: Agent
	testing.expect_value(
		t,
		agent_init(&agent, AgentConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_HOST, insecure = true}),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	local := trans.loopback_endpoint(9)
	for i in 0 ..< 2 {
		name := fmt.tprintf("demo/stop%02d", i)
		testing.expect_value(
			t,
			register_service(&agent, must_service(t, name), LocalTarget{address = local}),
			AgentError.None,
		)
	}

	agent_test_arm_backoff_stop(&agent, REGISTER_BACKOFF_STOP_AFTER)
	defer agent_test_clear_backoff_stop()

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer {
		agent_stop(&agent)
		if th != nil {
			thread.join(th)
			thread.destroy(th)
			th = nil
		}
	}

	start := time.now()
	for time.since(start) < 30 * time.Second {
		fired, _ := agent_test_backoff_stop_fired()
		if fired {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	fired, at := agent_test_backoff_stop_fired()
	testing.expect(t, fired)
	if !fired {
		return
	}
	thread.join(th)
	elapsed := time.since(at)
	thread.destroy(th)
	th = nil
	testing.expect(t, elapsed < 3 * time.Second)
}

@(test)
test_registered_log_skips_services_not_live :: proc(t: ^testing.T) {
	cap: log.Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	logger: log.Logger
	log.logger_init(&logger, .Info, rl_log_sink)
	context.user_ptr = &cap

	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig {
				broker   = trans.loopback_endpoint(1),
				token    = TEST_TOKEN_HOST,
				insecure = true,
				logger   = &logger,
			},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	local := trans.loopback_endpoint(9)
	live_id := must_service(t, "demo/live")
	idle_id := must_service(t, "demo/idle")
	testing.expect_value(t, register_service(&agent, live_id, LocalTarget{address = local}), AgentError.None)
	testing.expect_value(t, register_service(&agent, idle_id, LocalTarget{address = local}), AgentError.None)
	agent_mark_live(&agent, live_id)
	agent_log_registered(&agent)

	text := capture_text(&cap)
	defer delete(text)
	testing.expect_value(t, strings.count(text, fmt.tprintf("\"event\":\"%s\"", LOG_EVENT_REGISTERED)), 1)
	testing.expect(t, strings.contains(text, "demo/live"))
	testing.expect(t, !strings.contains(text, "demo/idle"))
	testing.expect(t, !strings.contains(text, TEST_TOKEN_HOST))
}

// An OPEN for an already-registered service can arrive after RATE_LIMITED and
// before the next REGISTER reply. The handshake must refuse that stream and
// finish the set on the same session.
@(test)
test_open_during_register_backoff_keeps_session :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	fx.server.register_rate = brk.rate_limit_config(2, 2 * time.Second)

	cap: log.Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	logger: log.Logger
	log.logger_init(&logger, .Info, rl_log_sink)
	context.user_ptr = &cap

	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig {
				broker   = broker_endpoint(t, &fx),
				token    = TEST_TOKEN_HOST,
				insecure = true,
				logger   = &logger,
			},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)
	N :: 6
	local := trans.loopback_endpoint(9)
	for i in 0 ..< N {
		name := fmt.tprintf("demo/open%02d", i)
		testing.expect_value(
			t,
			register_service(&agent, must_service(t, name), LocalTarget{address = local}),
			AgentError.None,
		)
	}

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc, context)
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}

	rate_event := fmt.tprintf("\"event\":\"%s\"", LOG_EVENT_RATE_LIMITED)
	start := time.now()
	ready := false
	for time.since(start) < 10 * time.Second {
		text := capture_text(&cap)
		hit := strings.contains(text, rate_event)
		delete(text)
		if hit && brk.service_count(&fx.reg) >= 1 && !agent_is_connected(&agent) {
			ready = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, ready)
	if !ready {
		return
	}

	live_i := -1
	for i in 0 ..< N {
		name := fmt.tprintf("demo/open%02d", i)
		if _, found := brk.lookup_service(&fx.reg, must_service(t, name)); found {
			live_i = i
			break
		}
	}
	testing.expect(t, live_i >= 0)
	if live_i < 0 {
		return
	}
	testing.expect(t, !agent_is_connected(&agent))
	expect_connect_failed(t, &fx, fmt.tprintf("demo/open%02d", live_i), proto.WireError.LocalServiceUnavailable)

	start = time.now()
	for time.since(start) < 15 * time.Second && brk.service_count(&fx.reg) < N {
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, brk.service_count(&fx.reg), N)
	testing.expect(t, agent_is_connected(&agent))
	_, sessions, _ := brk.registry_metrics(&fx.reg)
	testing.expect_value(t, sessions, 1)
}
