package agent

import brk "../broker"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

SilentPeerLog :: struct {
	mu:      sync.Mutex,
	text:    [dynamic]u8,
	idle_at: time.Time,
}

// The agent logs from its own thread, whose context has no user_ptr, so the
// sink reads a package global. Only this test sets it.
silent_peer_cap: ^SilentPeerLog

silent_peer_log_sink :: proc(text: string) {
	cap := sync.atomic_load(&silent_peer_cap)
	if cap == nil {
		return
	}
	sync.mutex_lock(&cap.mu)
	defer sync.mutex_unlock(&cap.mu)
	if strings.contains(text, "\"event\":\"disconnected\"") &&
	   strings.contains(text, "\"reason\":\"idle\"") {
		cap.idle_at = time.now()
	}
	append(&cap.text, ..transmute([]u8)text)
}

// Separate cap from the silent-peer test so the two can run in parallel.
healthy_idle_cap: ^SilentPeerLog

healthy_idle_log_sink :: proc(text: string) {
	cap := sync.atomic_load(&healthy_idle_cap)
	if cap == nil {
		return
	}
	sync.mutex_lock(&cap.mu)
	defer sync.mutex_unlock(&cap.mu)
	append(&cap.text, ..transmute([]u8)text)
}

// Exercise the production 45s watchdog. Existing proxy splices stay open
// and silent; the reconnect gets a new splice that forwards normally.
@(test)
test_agent_reconnect_after_silent_peer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 75 * time.Second)
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	// Keep the fixture's 30s broker session_timeout. The paused proxy never
	// forwards the broker's FIN, so the agent sees only silence. The broker
	// drops the old registration before the 45s agent timer fires, as in the
	// production hang (broker reported AGENT_UNAVAILABLE).

	echo: EchoFixture
	ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	proxy: ByteProxy
	byte_proxy_start(t, &proxy, broker_endpoint(t, &fx))
	defer byte_proxy_stop(&proxy)

	cap: SilentPeerLog
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	logger: log.Logger
	log.logger_init(&logger, .Info, silent_peer_log_sink)
	sync.atomic_store(&silent_peer_cap, &cap)
	defer sync.atomic_store(&silent_peer_cap, nil)

	agent: Agent
	err := agent_init(&agent, AgentConfig {
		broker = proxy.ep,
		token = TEST_TOKEN_HOST,
		insecure = true,
		logger = &logger,
	})
	testing.expect_value(t, err, AgentError.None)
	if err != .None {
		return
	}
	defer agent_destroy(&agent)
	testing.expect_value(t, agent_read_idle_limit(&agent), READ_IDLE_TIMEOUT)
	sid := must_service(t, TEST_SERVICE)
	testing.expect_value(t, register_service(&agent, sid, LocalTarget{address = ep}), AgentError.None)

	run := AgentRunArg{agent = &agent}
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)
	before, found := brk.lookup_service_for_environment(&fx.reg, "", sid, "org/dev")
	testing.expect(t, found, "initial registration missing")
	silent_peer_echo(t, &fx, "before")

	// Keep the old Connection allocated so pointer reuse cannot fake a swap.
	sync.mutex_lock(&agent.mutex)
	old := agent.live_conn
	held := old != nil && trans.connection_acquire(old)
	sync.mutex_unlock(&agent.mutex)
	testing.expect(t, held, "no live connection to blackhole")
	if !held {
		return
	}
	defer trans.connection_release(old)
	byte_proxy_blackhole(&proxy)
	start := time.now()
	dropped := false
	replaced := false
	drop_elapsed: time.Duration
	for time.since(start) < 55 * time.Second {
		if !dropped && sync.atomic_load(&old.closed) {
			dropped = true
			drop_elapsed = time.since(start)
		}
		sync.mutex_lock(&agent.mutex)
		replaced = agent.connected && agent.live_conn != nil && agent.live_conn != old
		sync.mutex_unlock(&agent.mutex)
		after, registered := brk.lookup_service_for_environment(&fx.reg, "", sid, "org/dev")
		if replaced && registered && after.agent_session != before.agent_session {
			break
		}
		replaced = false
		time.sleep(20 * time.Millisecond)
	}
	reconnect_elapsed := time.since(start)
	testing.expect(t, dropped, "silent peer socket never dropped")
	testing.expect(t, drop_elapsed >= 40 * time.Second, "idle detection fired before 40s")
	testing.expect(t, drop_elapsed <= 50 * time.Second, "idle detection was later than 50s")
	testing.expect(t, replaced, "silent peer never reconnected and re-registered")
	if !replaced {
		return
	}
	testing.expect(t, reconnect_elapsed - drop_elapsed <= 5 * time.Second, "reconnect took more than 5s after drop")
	silent_peer_echo(t, &fx, "after")

	sync.mutex_lock(&cap.mu)
	text := strings.clone(string(cap.text[:]))
	idle_elapsed := time.diff(start, cap.idle_at)
	sync.mutex_unlock(&cap.mu)
	defer delete(text)
	testing.expect(t, idle_elapsed >= 40 * time.Second && idle_elapsed <= 50 * time.Second, "missing or mistimed reason=idle")
	testing.expect_value(t, strings.count(text, "\"event\":\"disconnected\""), 1)
	testing.expect_value(t, strings.count(text, "\"reason\":\"idle\""), 2)
	testing.expect(t, strings.contains(text, "\"event\":\"reconnect_scheduled\""), "missing reconnect log")
	testing.expect_value(t, strings.count(text, "\"event\":\"registered\""), 2)
	fmt.printf("silent peer: drop=%v reconnect=%v\n%s", drop_elapsed, reconnect_elapsed, text)
}

silent_peer_echo :: proc(t: ^testing.T, fx: ^TestBroker, want: string) {
	caller := dial_broker(t, fx)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	stream := caller_connect_ok(t, caller, &decoder, TEST_SERVICE)
	must_write(t, caller, .Data, transmute([]u8)want, stream)
	got := must_read_opcode(t, caller, &decoder, .Data)
	testing.expect_value(t, string(got.payload), want)
	proto.frame_destroy(&got)
}

// A quiet but healthy session must stay up past 45s. The shared fixture
// uses a 30s broker heartbeat and 30s session_timeout; this test sets
// the production defaults (15s Ping, 45s session timeout) so the
// broker's real ping behavior is what keeps last_recv fresh.
@(test)
test_agent_stays_up_on_healthy_idle_session :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 180 * time.Second)
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	fx.server.heartbeat_interval = brk.DEFAULT_HEARTBEAT_INTERVAL
	fx.server.session_timeout = brk.DEFAULT_SESSION_TIMEOUT

	echo: EchoFixture
	ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	proxy: ByteProxy
	byte_proxy_start(t, &proxy, broker_endpoint(t, &fx))
	defer byte_proxy_stop(&proxy)

	cap: SilentPeerLog
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	logger: log.Logger
	log.logger_init(&logger, .Info, healthy_idle_log_sink)
	sync.atomic_store(&healthy_idle_cap, &cap)
	defer sync.atomic_store(&healthy_idle_cap, nil)

	agent: Agent
	err := agent_init(&agent, AgentConfig {
		broker = proxy.ep,
		token = TEST_TOKEN_HOST,
		insecure = true,
		logger = &logger,
	})
	testing.expect_value(t, err, AgentError.None)
	if err != .None {
		return
	}
	defer agent_destroy(&agent)
	testing.expect_value(t, agent_read_idle_limit(&agent), READ_IDLE_TIMEOUT)
	sid := must_service(t, TEST_SERVICE)
	testing.expect_value(t, register_service(&agent, sid, LocalTarget{address = ep}), AgentError.None)

	run := AgentRunArg{agent = &agent}
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)

	sync.mutex_lock(&agent.mutex)
	held_conn := agent.live_conn
	held := held_conn != nil && trans.connection_acquire(held_conn)
	sync.mutex_unlock(&agent.mutex)
	testing.expect(t, held, "no live connection at start")
	if !held {
		return
	}
	defer trans.connection_release(held_conn)

	start := time.now()
	same := true
	for time.since(start) < 120 * time.Second {
		sync.mutex_lock(&agent.mutex)
		live := agent.live_conn
		connected := agent.connected
		sync.mutex_unlock(&agent.mutex)
		if live != held_conn || !connected || sync.atomic_load(&held_conn.closed) {
			same = false
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	elapsed := time.since(start)
	testing.expect(t, same, "live_conn changed or session dropped during idle")
	testing.expect(t, elapsed >= 120 * time.Second, "idle window was shorter than 120s")

	sync.mutex_lock(&agent.mutex)
	final := agent.live_conn
	sync.mutex_unlock(&agent.mutex)
	testing.expect(t, final == held_conn, "live_conn changed after the idle window")

	sync.mutex_lock(&cap.mu)
	text := strings.clone(string(cap.text[:]))
	sync.mutex_unlock(&cap.mu)
	defer delete(text)
	testing.expect_value(t, strings.count(text, "\"reason\":\"idle\""), 0)
	testing.expect_value(t, strings.count(text, "\"event\":\"registered\""), 1)
	silent_peer_echo(t, &fx, "healthy")

	fmt.printf("healthy idle: elapsed=%v live_conn_unchanged=%v\n%s", elapsed, same && final == held_conn, text)
}

// Copied from the caller liveness harness: only existing splices pause.
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
// agent's reconnect) starts unpaused, so there is a path again.
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
