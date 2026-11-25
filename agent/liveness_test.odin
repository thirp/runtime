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
	dead_at: time.Time,
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
	   strings.contains(text, "\"reason\":\"dead_peer\"") {
		cap.dead_at = time.now()
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

@(test)
test_agent_keepalive_yields_to_outbound_traffic :: proc(t: ^testing.T) {
	conn := trans.Connection{refs = 1, last_write = time.tick_now()}
	next, err := trans.connection_write_if_idle(&conn, []u8{1}, HEARTBEAT_INTERVAL, HEARTBEAT_WRITE_TIMEOUT)
	testing.expect_value(t, err, trans.TransportError.None)
	testing.expect(t, next > 0 && next <= HEARTBEAT_INTERVAL, "recent outbound write did not defer the heartbeat")
	sync.mutex_lock(&conn.write_mutex)
	defer sync.mutex_unlock(&conn.write_mutex)
	_, busy := trans.connection_write_if_idle(&conn, []u8{1}, HEARTBEAT_INTERVAL, HEARTBEAT_WRITE_TIMEOUT)
	testing.expect_value(t, busy, trans.TransportError.WouldBlock)
}

when ODIN_TEST {
	@(test)
	test_agent_receive_deadline_while_writer_is_held :: proc(t: ^testing.T) {
		session := trans.Connection{refs = 1}
		agent := Agent{}
		agent.config.test_heartbeat_interval = 10 * time.Millisecond
		agent.config.test_dead_peer_timeout = 80 * time.Millisecond
		relay := AgentRelay{agent = &agent, broker = &session}
		keepalive := AgentKeepalive{relay = &relay, last_recv = time.tick_now()}
		sync.mutex_lock(&session.write_mutex)
		defer sync.mutex_unlock(&session.write_mutex)
		th := thread.create_and_start_with_poly_data(&keepalive, agent_keepalive)
		if !testing.expect(t, th != nil, "keepalive worker did not start") {
			return
		}
		start := time.tick_now()
		for !thread.is_done(th) && time.tick_since(start) < time.Second {
			time.sleep(5 * time.Millisecond)
		}
		finished := thread.is_done(th)
		agent_keepalive_stop(&keepalive)
		thread.join(th)
		thread.destroy(th)
		testing.expect(t, finished && keepalive.dead, "a held writer deferred the receive deadline")
	}

	@(test)
	test_agent_keepalive_interruption_preserves_session_and_streams :: proc(t: ^testing.T) {
		session := trans.Connection{refs = 1, test_interrupt_poll = true}
		origin := trans.Connection{refs = 1}
		agent := Agent{connected = true, live_conn = &session}
		relay := AgentRelay{agent = &agent, broker = &session}
		agent.live_relay = &relay
		stream_id := proto.StreamId(1)
		relay.streams[stream_id] = AgentLocalStream{local = &origin}
		defer delete(relay.streams)

		next, keep_running := agent_keepalive_probe(&agent, &session, 1)
		testing.expect(t, !session.test_interrupt_poll, "probe did not reach the injected interruption")
		testing.expect(t, keep_running, "an interrupted wait stopped the keepalive")
		testing.expect_value(t, next, HEARTBEAT_WRITE_TIMEOUT)
		testing.expect(t, agent.connected && agent.live_conn == &session && !session.closed, "agent session closed")
		stream, found := relay.streams[stream_id]
		testing.expect(t, found && !stream.closed && stream.local == &origin && !origin.closed, "stream closed")
	}

	// The injected error affects only the legacy reader's Ping write.
	// The agent owns its real TCP session and must perform any disconnect;
	// nothing in the fixture closes that session to force the broker's RESET.
	@(test)
	test_agent_slow_upload_survives_heartbeat_write_fault :: proc(t: ^testing.T) {
		slow_upload_heartbeat_case(t, true)
		slow_upload_heartbeat_case(t, false)
	}

	@(test)
	test_agent_one_way_upload_keeps_outbound_session_alive :: proc(t: ^testing.T) {
		testing.set_fail_timeout(t, 60 * time.Second)
		slow_upload_heartbeat_case(t, false, paced = true)
	}

	slow_upload_heartbeat_case :: proc(t: ^testing.T, legacy: bool, paced := false) {
		origin_listener, lerr := trans.listener_listen(trans.loopback_endpoint(0))
		if !testing.expect_value(t, lerr, trans.TransportError.None) {
			return
		}
		defer trans.listener_close(&origin_listener)
		origin_ep, eerr := trans.listener_endpoint(origin_listener)
		if !testing.expect_value(t, eerr, trans.TransportError.None) {
			return
		}
		fx: TestBroker
		start_test_broker(t, &fx, heartbeat = 60 * time.Second if paced else 30 * time.Second)
		defer stop_test_broker(&fx)
		probe: HeartbeatProbe
		agent: Agent
		logger: log.Logger
		log.logger_init(&logger, .Debug)
		cfg := AgentConfig {
			broker   = broker_endpoint(t, &fx),
			token    = TEST_TOKEN_HOST,
			insecure = true,
			logger   = &logger,
		}
		when ODIN_TEST {
			cfg.test_legacy_heartbeat = legacy
			if !paced {
				cfg.test_heartbeat_probe = &probe
			}
		}
		err := agent_init(&agent, cfg)
		if !testing.expect_value(t, err, AgentError.None) {
			return
		}
		defer agent_destroy(&agent)
		service := must_service(t, TEST_SERVICE)
		testing.expect_value(t, register_service(&agent, service, LocalTarget{address = origin_ep}), AgentError.None)
		run := AgentRunArg{agent = &agent}
		th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
		if !testing.expect(t, th != nil, "agent thread") {
			return
		}
		defer {
			agent_stop(&agent)
			thread.join(th)
			thread.destroy(th)
		}
		wait_agent_connected(t, &agent)
		sync.mutex_lock(&agent.mutex)
		session := agent.live_conn
		held := trans.connection_acquire(session)
		sync.mutex_unlock(&agent.mutex)
		if !testing.expect(t, held, "no original agent session") {
			return
		}
		defer trans.connection_release(session)

		caller := dial_broker(t, &fx)
		if caller == nil {
			return
		}
		defer trans.connection_destroy(caller)
		dec: proto.FrameDecoder
		handshake_caller(t, caller, &dec)
		defer proto.decoder_destroy(&dec)
		stream := caller_connect_ok(t, caller, &dec, TEST_SERVICE)
		if !testing.expect(t, stream != proto.CONNECTION_STREAM_ID, "upload stream did not open") {
			return
		}
		if !testing.expect_value(t, trans.listener_wait_acceptable(&origin_listener, 2 * time.Second), trans.TransportError.None) {
			return
		}
		origin, aerr := trans.listener_accept(&origin_listener)
		if !testing.expect_value(t, aerr, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(origin)
		_ = trans.connection_set_recv_timeout(origin, 2 * time.Second)
		// Read the first upload byte, then hold the origin before the body.
		// This also proves the relay handled genuine inbound DATA before the
		// test advances the heartbeat schedule at its next normal read timeout.
		must_write(t, caller, .Data, []u8{'S'}, stream)
		first: [1]u8
		n, rerr := trans.connection_read(origin, first[:])
		if !testing.expect(t, rerr == .None && n == 1 && first[0] == 'S', "origin did not start the upload") {
			return
		}
		when ODIN_TEST {
			if !legacy && !paced {
				// Drive one worker iteration on the live session. The same
				// stream and origin socket must still carry the body and reply.
				sync.atomic_store(&session.test_interrupt_poll, true)
				next, keep_running := agent_keepalive_probe(&agent, session, 1, idle = 0)
				consumed := !sync.atomic_exchange(&session.test_interrupt_poll, false)
				if !testing.expect(t, consumed && keep_running && next == HEARTBEAT_WRITE_TIMEOUT, "agent did not defer the interrupted probe") {
					return
				}
			}
		}
		if paced {
			// The origin sends nothing for longer than the broker's 30 s
			// session timeout. Check the next byte each second so replacing the
			// session or losing the stream cannot pass by reconnecting.
			for tick in 0 ..< 33 {
				time.sleep(time.Second)
				b := u8(tick)
				must_write(t, caller, .Data, []u8{b}, stream)
				n, rerr = trans.connection_read(origin, first[:])
				if !testing.expectf(t, rerr == .None && n == 1 && first[0] == b, "upload lost at second %d (%v)", tick + 1, rerr) {
					return
				}
			}
		}
		body: [16 * 1024]u8
		for &b in body {
			b = 'x'
		}
		must_write(t, caller, .Data, body[:], stream)
		if !paced {
			sync.atomic_store(&probe.armed, true)
			if !testing.expect(t, sync.sema_wait_with_timeout(&probe.done, 2 * time.Second), "no relay read timeout during upload") {
				return
			}
			testing.expect(t, probe.recent_frame, "probe ran without recent inbound traffic")
			testing.expect_value(t, probe.fault_observed, legacy)
		}
		if legacy {
			reset := must_read_opcode(t, caller, &dec, .Reset)
			defer proto.frame_destroy(&reset)
			testing.expect_value(t, reset.header.stream_id, stream)
			failure, ferr := proto.decode_wire_failure(reset.payload)
			defer delete(failure.diagnostic)
			testing.expect_value(t, ferr, proto.ProtocolError.None)
			code, _ := proto.wire_error_from_u16(failure.code)
			testing.expect_value(t, code, proto.WireError.AgentUnavailable)
			testing.expect(t, sync.atomic_load(&session.closed), "agent left the failed session open")
			fmt.printf("slow upload heartbeat old condition: injected Ping write Timeout=%v, caller received %s\n", probe.fault_observed, proto.wire_error_name(code))
			return
		}
		got: [len(body)]u8
		for total := 0; total < len(got); {
			count, read_err := trans.connection_read(origin, got[total:])
			if !testing.expect_value(t, read_err, trans.TransportError.None) {
				return
			}
			total += count
		}
		testing.expect_value(t, string(got[:]), string(body[:]))
		must_write(t, caller, .HalfClose, nil, stream)
		_, eof := trans.connection_read(origin, first[:])
		testing.expect_value(t, eof, trans.TransportError.Closed)
		response := "received"
		testing.expect_value(t, trans.connection_write(origin, transmute([]u8)response), trans.TransportError.None)
		reply := must_read_opcode(t, caller, &dec, .Data)
		defer proto.frame_destroy(&reply)
		testing.expect_value(t, reply.header.stream_id, stream)
		testing.expect_value(t, string(reply.payload), response)
		sync.mutex_lock(&agent.mutex)
		same := agent.connected && agent.live_conn == session && !sync.atomic_load(&session.closed)
		sync.mutex_unlock(&agent.mutex)
		testing.expect(t, same, "agent session changed during the upload")
		fmt.printf("slow upload heartbeat current condition: %d body bytes, origin reply %q, same agent session=%v\n", len(body), string(reply.payload), same)
	}
}

// The proxy accepts TCP bytes without returning frames. Holding the session
// writer simulates DATA backpressure while a real stream is open and active.
@(test)
test_agent_reconnect_after_silent_peer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 12 * time.Second)
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	endpoint := broker_endpoint(t, &fx)
	if endpoint.port == 0 {
		return
	}

	echo: EchoFixture
	ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	proxy: ByteProxy
	byte_proxy_start(t, &proxy, endpoint)
	defer byte_proxy_stop(&proxy)

	cap: SilentPeerLog
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	logger: log.Logger
	log.logger_init(&logger, .Info, silent_peer_log_sink)
	sync.atomic_store(&silent_peer_cap, &cap)
	defer sync.atomic_store(&silent_peer_cap, nil)

	agent: Agent
	config := AgentConfig {
		broker = proxy.ep,
		token = TEST_TOKEN_HOST,
		insecure = true,
		logger = &logger,
	}
	data_write_started: sync.Sema
	when ODIN_TEST {
		config.test_heartbeat_interval = 100 * time.Millisecond
		config.test_dead_peer_timeout = 750 * time.Millisecond
		config.test_data_write_started = &data_write_started
	}
	err := agent_init(&agent, config)
	if !testing.expect_value(t, err, AgentError.None) {
		return
	}
	defer agent_destroy(&agent)
	sid := must_service(t, TEST_SERVICE)
	testing.expect_value(t, register_service(&agent, sid, LocalTarget{address = ep}), AgentError.None)

	run := AgentRunArg{agent = &agent}
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	if !testing.expect(t, th != nil, "agent thread") {
		return
	}
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)
	before, found := brk.lookup_service_for_environment(&fx.reg, "", sid, "org/dev")
	testing.expect(t, found, "initial registration missing")

	caller := dial_broker(t, &fx)
	if caller == nil {
		return
	}
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	stream := caller_connect_ok(t, caller, &decoder, TEST_SERVICE)
	must_write(t, caller, .Data, []u8{'e'}, stream)
	got := must_read_opcode(t, caller, &decoder, .Data)
	testing.expect_value(t, string(got.payload), "e")
	proto.frame_destroy(&got)
	if !testing.expect(t, sync.sema_wait_with_timeout(&data_write_started, time.Second), "first echo never reached the writer") {
		return
	}

	// Keep the old Connection allocated so pointer reuse cannot fake a swap.
	sync.mutex_lock(&agent.mutex)
	old := agent.live_conn
	held := old != nil && trans.connection_acquire(old)
	sync.mutex_unlock(&agent.mutex)
	if !testing.expect(t, held, "no live connection to blackhole") {
		return
	}
	defer trans.connection_release(old)
	start: time.Time
	{
		sync.mutex_lock(&old.write_mutex)
		defer sync.mutex_unlock(&old.write_mutex)
		must_write(t, caller, .Data, []u8{'b'}, stream)
		if !testing.expect(t, sync.sema_wait_with_timeout(&data_write_started, 500 * time.Millisecond),
			"second echo never reached the held writer") {
			return
		}
		byte_proxy_blackhole(&proxy)
		start = time.now()
		for !sync.atomic_load(&old.closed) && time.since(start) < 1500 * time.Millisecond {
			time.sleep(10 * time.Millisecond)
		}
		if !testing.expect(t, sync.atomic_load(&old.closed) && time.since(start) < 1500 * time.Millisecond,
			"busy agent did not close the silent socket within 1.5s") {
			return
		}
	}

	replaced := false
	for time.since(start) < 4 * time.Second {
		sync.mutex_lock(&agent.mutex)
		replaced = agent.connected && agent.live_conn != nil && agent.live_conn != old
		sync.mutex_unlock(&agent.mutex)
		after, registered := brk.lookup_service_for_environment(&fx.reg, "", sid, "org/dev")
		if replaced && registered && after.agent_session != before.agent_session {
			break
		}
		replaced = false
		time.sleep(10 * time.Millisecond)
	}
	if !testing.expect(t, replaced, "silent peer never reconnected and re-registered within 4s") {
		return
	}
	silent_peer_echo(t, &fx, "after")

	sync.mutex_lock(&cap.mu)
	text := strings.clone(string(cap.text[:]))
	dead_elapsed := time.diff(start, cap.dead_at)
	sync.mutex_unlock(&cap.mu)
	defer delete(text)
	testing.expect(t, dead_elapsed >= 0 && dead_elapsed < 2 * time.Second, "missing or mistimed reason=dead_peer")
	testing.expect_value(t, strings.count(text, "\"event\":\"disconnected\""), 1)
	testing.expect_value(t, strings.count(text, "\"reason\":\"dead_peer\""), 2)
	testing.expect_value(t, strings.count(text, "\"event\":\"registered\""), 2)
}

@(test)
test_agent_stays_connected_while_broker_waits_for_slow_caller :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	endpoint := broker_endpoint(t, &fx)
	if endpoint.port == 0 {
		return
	}
	// Two one-byte echoes deterministically fill the slow caller's outbox
	// and block the broker's reader for this agent on the second echo.
	fx.server.max_stream_buffer = 1
	echo: EchoFixture
	origin := start_echo(t, &echo)
	defer stop_echo(&echo)
	deadline :: 3500 * time.Millisecond
	agent: Agent
	config := AgentConfig{broker = endpoint, token = TEST_TOKEN_HOST, insecure = true}
	when ODIN_TEST {
		config.test_heartbeat_interval = 100 * time.Millisecond
		config.test_dead_peer_timeout = deadline
	}
	if !testing.expect_value(t, agent_init(&agent, config), AgentError.None) {
		return
	}
	defer agent_destroy(&agent)
	sid := must_service(t, TEST_SERVICE)
	if !testing.expect_value(t, register_service(&agent, sid, LocalTarget{address = origin}), AgentError.None) {
		return
	}
	run := AgentRunArg{agent = &agent}
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	if !testing.expect(t, th != nil, "agent thread") {
		return
	}
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)
	caller := dial_broker(t, &fx)
	if caller == nil {
		return
	}
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	stream := caller_connect_ok(t, caller, &decoder, TEST_SERVICE)
	relay, found := brk.relay_lookup_stream(&fx.server, stream)
	if !testing.expect(t, found, "broker stream missing") {
		return
	}
	source := brk.server_lookup_outbox(&fx.server, relay.agent_conn)
	dest := brk.server_lookup_outbox(&fx.server, relay.caller_conn)
	defer brk.outbox_release(source)
	defer brk.outbox_release(dest)
	if !testing.expect(t, source != nil && dest != nil, "broker outbox missing") {
		return
	}
	sync.mutex_lock(&agent.mutex)
	socket := agent.live_conn
	held := trans.connection_acquire(socket)
	sync.mutex_unlock(&agent.mutex)
	if !testing.expect(t, held, "agent session missing") {
		return
	}
	defer trans.connection_release(socket)
	brk.outbox_set_writer_hold(dest, true)
	defer brk.outbox_set_writer_hold(dest, false)
	must_write(t, caller, .Data, []u8{'a'}, stream)
	start := time.tick_now()
	for brk.outbox_queued(dest, stream) == 0 && time.tick_since(start) < time.Second {
		time.sleep(5 * time.Millisecond)
	}
	if !testing.expect_value(t, brk.outbox_queued(dest, stream), 1) {
		return
	}
	must_write(t, caller, .Data, []u8{'b'}, stream)
	start = time.tick_now()
	waiting := false
	for time.tick_since(start) < time.Second {
		sync.mutex_lock(&source.mutex)
		waiting = source.waiting_on_stream
		sync.mutex_unlock(&source.mutex)
		if waiting {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !testing.expect(t, waiting, "second echo never blocked on the caller outbox") {
		return
	}
	{
		// A full upstream TCP send buffer can also keep the agent's writer
		// unavailable. Incoming broker Pings must still reach the watchdog.
		sync.mutex_lock(&socket.write_mutex)
		defer sync.mutex_unlock(&socket.write_mutex)
		time.sleep(deadline + brk.BACKPRESSURE_PING_INTERVAL + 500 * time.Millisecond)
		if !testing.expect(t, !sync.atomic_load(&socket.closed), "agent disconnected while the broker waited for stream space") {
			return
		}
	}
	brk.outbox_set_writer_hold(dest, false)
	for want in ([2]u8{'a', 'b'}) {
		frame := must_read_opcode(t, caller, &decoder, .Data)
		defer proto.frame_destroy(&frame)
		testing.expect(t, len(frame.payload) == 1 && frame.payload[0] == want, "queued echo did not resume in order")
	}
	must_write(t, caller, .Data, []u8{'c'}, stream)
	frame := must_read_opcode(t, caller, &decoder, .Data)
	defer proto.frame_destroy(&frame)
	testing.expect_value(t, string(frame.payload), "c")
	sync.mutex_lock(&agent.mutex)
	same := agent.connected && agent.live_conn == socket
	sync.mutex_unlock(&agent.mutex)
	testing.expect(t, same, "agent changed sessions during the wait")
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

// A quiet but healthy session must stay up across many production
// keepalive intervals. Use the broker's production timers too.
@(test)
test_agent_stays_up_on_healthy_idle_session :: proc(t: ^testing.T) {
	if !RUN_FLAKY { return }
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
	testing.expect_value(t, agent_dead_peer_limit(&agent), DEAD_PEER_TIMEOUT)
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
	testing.expect_value(t, strings.count(text, "\"reason\":\"dead_peer\""), 0)
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
	reset:  bool,
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
		sync.mutex_lock(&p.mu)
		target := p.target
		sync.mutex_unlock(&p.mu)
		up, derr := trans.connection_dial(target)
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
	for !sync.atomic_load(&p.stop) && !sync.atomic_load(&link.stop) && !sync.atomic_load(&link.reset) {
		if sync.atomic_load(&link.pause) {
			_, err := trans.connection_read(link.client, buf[:])
			if err != .None && err != .Timeout {
				return
			}
			continue
		}
		if !proxy_copy(link.client, link.up, buf[:], &link.pause) {
			return
		}
		if sync.atomic_load(&link.pause) || sync.atomic_load(&link.stop) || sync.atomic_load(&p.stop) {
			continue
		}
		if !proxy_copy(link.up, link.client, buf[:], &link.pause) {
			return
		}
	}
}

proxy_copy :: proc(from, to: ^trans.Connection, buf: []u8, paused: ^bool) -> bool {
	n, err := trans.connection_read(from, buf)
	if err == .Timeout {
		return true
	}
	if err != .None {
		return false
	}
	return sync.atomic_load(paused) || trans.connection_write(to, buf[:n]) == .None
}

proxy_link_done :: proc(link: ^ProxyLink) {
	p := link.proxy
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	for i := 0; i < len(p.links); i += 1 {
		if p.links[i] == link {
			ordered_remove(&p.links, i)
			break
		}
	}
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
