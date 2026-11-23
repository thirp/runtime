package caller

import ag "../agent"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

when ODIN_TEST {

RESUME_SERVICES :: [?]proto.ServiceId{"demo/one", "demo/two", "demo/three", "demo/four", "demo/five"}
RESUME_CYCLES :: 20
RESUME_SILENCE :: 750 * time.Millisecond
RESUME_PING :: 100 * time.Millisecond
RESUME_IDLE :: 700 * time.Millisecond

@(test)
test_caller_receive_deadline_distinguishes_dead_and_idle :: proc(t: ^testing.T) {
	socket := trans.Connection{refs = 1}
	stream: Conn
	now := time.tick_now()
	c := Caller{conn = &socket, connected = true, last_recv = now, idle_since = time.tick_add(now, -SESSION_IDLE_TIMEOUT)}
	c.streams[1] = &stream
	defer delete(c.streams)
	caller_watch_sessions(&c, now)
	testing.expect(t, c.connected && c.disconnect_reason == "", "a quiet open stream was treated as idle")
	c.last_recv = time.tick_add(now, -DEAD_PEER_TIMEOUT)
	caller_watch_sessions(&c, now)
	testing.expect_value(t, c.disconnect_reason, LOG_REASON_DEAD_PEER)

	clear(&c.streams)
	c.connected = true
	c.disconnect_reason = ""
	c.last_recv = now
	c.idle_since = time.tick_add(now, -SESSION_IDLE_TIMEOUT)
	caller_watch_sessions(&c, now)
	testing.expect_value(t, c.disconnect_reason, LOG_REASON_IDLE)
}

@(test)
test_caller_completed_dial_keeps_its_service_error :: proc(t: ^testing.T) {
	first, second: Conn
	c := Caller{pending = &first}
	caller_handle_connect_failed(&c, .LocalServiceUnavailable)
	c.pending = &second
	caller_fail_all(&c, .Transport)
	testing.expect_value(t, first.dial_error, CallerError.LocalServiceUnavailable)
	testing.expect_value(t, second.dial_error, CallerError.Transport)
	testing.expect(t, c.pending == nil && !c.connected, "a disconnected caller retained a pending dial")
}

@(test)
test_five_services_resume_after_idle_disconnect :: proc(t: ^testing.T) {
	reconnect_five_services(t, silent = false)
}

@(test)
test_five_services_resume_after_silent_drop :: proc(t: ^testing.T) {
	reconnect_five_services(t, silent = true)
}

reconnect_five_services :: proc(t: ^testing.T, silent: bool, cycles := RESUME_CYCLES, production_timers := false) {
	testing.set_fail_timeout(t, 100 * time.Second)
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	endpoint := broker_endpoint(t, &fx)
	if endpoint.port == 0 {
		return
	}
	echo: [len(RESUME_SERVICES)]EchoFixture
	targets: [len(RESUME_SERVICES)]net.Endpoint
	defer for &origin in echo {
		stop_echo(&origin)
	}
	for &origin, i in echo {
		targets[i] = start_echo(t, &origin)
	}
	agent: ag.Agent
	run: AgentRunArg
	ath := start_resume_agent(t, endpoint, &agent, &run, targets[:])
	defer stop_agent(&agent, ath)
	if ath == nil {
		return
	}
	proxy: ByteProxy
	byte_proxy_start(t, &proxy, endpoint)
	defer byte_proxy_stop(&proxy)
	c: Caller
	config := CallerConfig{broker = proxy.ep, token = TEST_TOKEN_CALLER, insecure = true, dial_timeout = 3 * time.Second}
	if !production_timers {
		config.read_idle_timeout = RESUME_SILENCE
		config.ping_interval = RESUME_PING
	}
	if !silent {
		config.session_idle_timeout = RESUME_IDLE
	}
	if !testing.expect_value(t, caller_init(&c, config), CallerError.None) {
		return
	}
	defer caller_destroy(&c)
	services := RESUME_SERVICES
	if !resume_echo_all(t, &c, services[:], time.tick_add(time.tick_now(), 10 * time.Second), -1) {
		return
	}
	for cycle in 1 ..= cycles {
		if !resume_one_cycle(t, &c, &proxy, cycle, silent, production_timers) {
			return
		}
	}
}

resume_one_cycle :: proc(t: ^testing.T, c: ^Caller, proxy: ^ByteProxy, cycle: int, silent, production_timers: bool) -> bool {
	old: ^Conn
	if silent {
		gen := caller_conn_gen(c)
		err: CallerError
		old, err = dial(c, RESUME_SERVICES[0])
		if !testing.expectf(t, err == .None,
			"cycle %d opening %s before the drop: %v (generation %d to %d, disconnect %q)",
			cycle, RESUME_SERVICES[0], err, gen, caller_conn_gen(c), caller_last_disconnect_reason(c)) {
			return false
		}
	}
	defer conn_destroy(old)
	if silent && !testing.expect(t, resume_echo(old, 'x', time.tick_add(time.tick_now(), 2 * time.Second)), "stream never started") {
		return false
	}
	gen := caller_conn_gen(c)
	start := time.tick_now()
	bound := 4 * time.Second if silent && !production_timers else 10 * time.Second
	detect := 1500 * time.Millisecond
	if production_timers {
		detect = 9 * time.Second
	}
	if silent {
		byte_proxy_blackhole(proxy)
	}
	for caller_conn_gen(c) == gen && time.tick_since(start) < detect {
		time.sleep(10 * time.Millisecond)
	}
	if !testing.expectf(t, caller_conn_gen(c) != gen && time.tick_since(start) < detect,
		"cycle %d did not drop the old session within %v", cycle, detect) {
		return false
	}
	deadline := time.tick_add(start, bound)
	if !testing.expectf(t, resume_wait_connected(c, gen, deadline), "cycle %d did not reconnect within %v", cycle, bound) {
		return false
	}
	reason := LOG_REASON_DEAD_PEER if silent else LOG_REASON_IDLE
	if !testing.expect_value(t, caller_last_disconnect_reason(c), reason) ||
	   (silent && !testing.expect(t, conn_finished(old), "dead session left its old stream open")) {
		return false
	}
	services := RESUME_SERVICES
	return resume_echo_all(t, c, services[:], deadline, cycle)
}

@(test)
test_quiet_stream_prevents_idle_disconnect :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	endpoint := broker_endpoint(t, &fx)
	if endpoint.port == 0 {
		return
	}
	echo: EchoFixture
	origin := start_echo(t, &echo)
	defer stop_echo(&echo)
	agent: ag.Agent
	run: AgentRunArg
	ath := start_registered_agent(t, &fx, origin, &agent, &run)
	defer stop_agent(&agent, ath)
	c: Caller
	idle := 1200 * time.Millisecond
	config := CallerConfig{broker = endpoint, token = TEST_TOKEN_CALLER, insecure = true, dial_timeout = 2 * time.Second,
		read_idle_timeout = RESUME_SILENCE, ping_interval = RESUME_PING, session_idle_timeout = idle}
	if !testing.expect_value(t, caller_init(&c, config), CallerError.None) {
		return
	}
	defer caller_destroy(&c)
	sid := must_service(t, TEST_SERVICE)
	stream, err := dial(&c, sid)
	if !testing.expect_value(t, err, CallerError.None) {
		return
	}
	defer conn_destroy(stream)
	gen := caller_conn_gen(&c)
	time.sleep(idle + 500 * time.Millisecond)
	if !testing.expect(t, caller_conn_gen(&c) == gen && caller_is_connected(&c), "quiet open stream did not prevent idle expiry") {
		return
	}
	if !testing.expect(t, resume_echo(stream, 'q', time.tick_add(time.tick_now(), time.Second)), "quiet stream stopped working") {
		return
	}
	conn_close(stream)
	deadline := time.tick_add(time.tick_now(), 4 * time.Second)
	if testing.expect(t, resume_wait_connected(&c, gen, deadline), "empty session did not expire and reconnect") {
		testing.expect_value(t, caller_last_disconnect_reason(&c), LOG_REASON_IDLE)
	}
}

@(test)
test_unavailable_target_recovers_without_affecting_other_services :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	endpoint := broker_endpoint(t, &fx)
	if endpoint.port == 0 {
		return
	}
	echo, recovering: EchoFixture
	healthy := start_echo(t, &echo)
	defer stop_echo(&echo)
	unavailable := start_echo(t, &recovering)
	stop_echo(&recovering)
	targets := [len(RESUME_SERVICES)]net.Endpoint{healthy, healthy, healthy, healthy, unavailable}
	agent: ag.Agent
	run: AgentRunArg
	ath := start_resume_agent(t, endpoint, &agent, &run, targets[:])
	defer stop_agent(&agent, ath)
	if ath == nil {
		return
	}
	c: Caller
	config := CallerConfig{broker = endpoint, token = TEST_TOKEN_CALLER, insecure = true, dial_timeout = 3 * time.Second}
	if !testing.expect_value(t, caller_init(&c, config), CallerError.None) {
		return
	}
	defer caller_destroy(&c)
	services := RESUME_SERVICES
	n := len(services) - 1
	stream, err := dial(&c, services[n])
	conn_destroy(stream)
	if !testing.expect_value(t, err, CallerError.LocalServiceUnavailable) {
		return
	}
	gen := caller_conn_gen(&c)
	if !resume_echo_all(t, &c, services[:n], time.tick_add(time.tick_now(), 4 * time.Second), 0) {
		return
	}
	_ = start_echo_at(t, &recovering, unavailable)
	defer stop_echo(&recovering)
	_ = resume_echo_all(t, &c, services[:], time.tick_add(time.tick_now(), 4 * time.Second), 1)
	testing.expect_value(t, caller_conn_gen(&c), gen)
}

start_resume_agent :: proc(t: ^testing.T, endpoint: net.Endpoint, agent: ^ag.Agent, run: ^AgentRunArg, targets: []net.Endpoint) -> ^thread.Thread {
	config := ag.AgentConfig{broker = endpoint, token = TEST_TOKEN_HOST, insecure = true}
	if !testing.expect_value(t, ag.agent_init(agent, config), ag.AgentError.None) {
		return nil
	}
	for id, i in RESUME_SERVICES {
		if !testing.expect_value(t, ag.register_service(agent, id, {address = targets[i]}), ag.AgentError.None) {
			return nil
		}
	}
	run.agent = agent
	th := thread.create_and_start_with_poly_data(run, agent_run_proc)
	if testing.expect(t, th != nil, "could not start agent") {
		wait_agent_connected(t, agent)
	}
	return th
}

resume_wait_connected :: proc(c: ^Caller, gen: int, deadline: time.Tick) -> bool {
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if caller_conn_gen(c) != gen && caller_is_connected(c) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

resume_echo_all :: proc(t: ^testing.T, c: ^Caller, services: []proto.ServiceId, deadline: time.Tick, cycle: int) -> bool {
	for id, i in services {
		stream, err := dial(c, id)
		defer conn_destroy(stream)
		if !testing.expectf(t, err == .None && stream != nil, "cycle %d %s dial: %v", cycle, id, err) ||
		   !testing.expectf(t, resume_echo(stream, u8(i), deadline), "cycle %d %s did not echo within the bound", cycle, id) {
			return false
		}
	}
	return true
}

resume_echo :: proc(stream: ^Conn, b: u8, deadline: time.Tick) -> bool {
	buf := [1]u8{b}
	if n, err := conn_write(stream, buf[:]); n != 1 || err != .None {
		return false
	}
	sync.mutex_lock(&stream.mutex)
	defer sync.mutex_unlock(&stream.mutex)
	for len(stream.inbound) == 0 && !stream.closed && !stream.reset && !stream.eof {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 {
			return false
		}
		_ = sync.cond_wait_with_timeout(&stream.cond, &stream.mutex, left)
	}
	if len(stream.inbound) != 1 || stream.inbound[0] != b || time.tick_diff(time.tick_now(), deadline) <= 0 {
		return false
	}
	clear(&stream.inbound)
	return true
}

}
