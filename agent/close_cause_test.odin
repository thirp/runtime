package agent

import brk "../broker"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import win "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"

CloseFault :: enum { EOF, Reset, TLSAlert, Deadline, Drain }

close_agent_log: log.Capture
close_broker_log: log.Capture

close_agent_sink :: proc(line: string) {
	log.capture_sink(&close_agent_log, line)
}

close_broker_sink :: proc(line: string) {
	log.capture_sink(&close_broker_log, line)
}

enable_abortive_close :: proc(socket: net.TCP_Socket) -> bool {
	when ODIN_OS == .Windows {
		linger := win.LINGER{l_onoff = 1}
		return win.setsockopt(win.SOCKET(socket), win.SOL_SOCKET, win.SO_LINGER, &linger, c.int(size_of(linger))) == 0
	} else {
		linger := posix.linger{l_onoff = 1}
		return posix.setsockopt(posix.FD(socket), posix.SOL_SOCKET, .LINGER, &linger, posix.socklen_t(size_of(linger))) == .OK
	}
}

cut_existing_link :: proc(t: ^testing.T, p: ^ByteProxy, fault: CloseFault) -> bool {
	sync.mutex_lock(&p.mu)
	defer sync.mutex_unlock(&p.mu)
	if !testing.expect_value(t, len(p.links), 1) {
		return false
	}
	link := p.links[0]
	switch fault {
	case .EOF:
		sync.atomic_store(&link.pause, true)
		a := trans.connection_shutdown_write(link.client)
		b := trans.connection_shutdown_write(link.up)
		return testing.expect(t, a == .None && b == .None, "send FIN to both peers")
	case .Reset:
		if !testing.expect(t, enable_abortive_close(link.client.socket) && enable_abortive_close(link.up.socket),
			"enable abortive close on both proxy sockets") {
			return false
		}
		sync.atomic_store(&link.reset, true)
		return true
	case .TLSAlert:
		// An application record with an invalid authentication tag. The
		// agent sends a fatal alert and the proxy forwards it to the broker.
		record: [37]u8
		copy(record[:], []u8{23, 3, 3, 0, 32})
		return testing.expect_value(t, trans.connection_write(link.client, record[:]), trans.TransportError.None)
	case .Deadline:
		sync.atomic_store(&link.pause, true)
		return true
	case .Drain:
		return false
	}
	return false
}

wait_close_log :: proc(t: ^testing.T, capture: ^log.Capture, event, field, value: string, loc := #caller_location) -> bool {
	event_json := fmt.tprintf("\"event\":\"%s\"", event)
	cause_json := fmt.tprintf("\"%s\":\"%s\"", field, value)
	start := time.tick_now()
	for time.tick_since(start) < 6 * time.Second {
		sync.mutex_lock(&capture.mutex)
		lines := string(capture.text[:])
		for line in strings.split_lines_iterator(&lines) {
			if strings.contains(line, event_json) && strings.contains(line, cause_json) {
				sync.mutex_unlock(&capture.mutex)
				return true
			}
		}
		sync.mutex_unlock(&capture.mutex)
		time.sleep(5 * time.Millisecond)
	}
	return testing.expectf(t, false, "%s did not log %s=%s", event, field, value, loc = loc)
}

run_close_fault :: proc(t: ^testing.T, fault: CloseFault, cause: string) {
	close_agent_log.text = make([dynamic]u8)
	defer delete(close_agent_log.text)
	close_broker_log.text = make([dynamic]u8)
	defer delete(close_broker_log.text)
	agent_logger, broker_logger: log.Logger
	log.logger_init(&agent_logger, .Info, close_agent_sink)
	log.logger_init(&broker_logger, .Info, close_broker_sink)

	cert :: "transport/testdata/test_server.crt"
	tls_ctx: ^trans.TlsServerContext
	if fault == .TLSAlert {
		err: trans.TransportError
		tls_ctx, err = trans.tls_server_context_init(cert, "transport/testdata/test_server.key")
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
	}
	fx: TestBroker
	start_test_broker(t, &fx, session_timeout = 2 * time.Second if fault == .Deadline else 30 * time.Second,
		logger = &broker_logger, tls_ctx = tls_ctx)
	defer stop_test_broker(&fx)
	if !fx.server.listening {
		return
	}
	successor: TestBroker
	defer if successor.server.registry != nil {
		stop_test_broker(&successor)
	}
	proxy: ByteProxy
	byte_proxy_start(t, &proxy, broker_endpoint(t, &fx))
	defer byte_proxy_stop(&proxy)
	if proxy.th == nil || proxy.ep.port == 0 {
		return
	}

	agent: Agent
	config := AgentConfig{broker = proxy.ep, token = TEST_TOKEN_HOST, insecure = tls_ctx == nil, logger = &agent_logger}
	if tls_ctx != nil {
		config.tls_ca = cert
		config.tls_server_name = "localhost"
	}
	when ODIN_TEST {
		if fault == .Deadline {
			config.test_read_idle_timeout = 3 * time.Second
		}
	}
	if !testing.expect_value(t, agent_init(&agent, config), AgentError.None) {
		return
	}
	defer agent_destroy(&agent)
	sid := must_service(t, TEST_SERVICE)
	if !testing.expect_value(t, register_service(&agent, sid, LocalTarget{address = trans.loopback_endpoint(9)}), AgentError.None) {
		return
	}
	run := AgentRunArg{agent = &agent}
	worker := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	if !testing.expect(t, worker != nil, "agent worker") {
		return
	}
	hold_teardown := fault == .EOF || fault == .Deadline
	defer if hold_teardown {
		agent_test_clear_stream_wait(&agent)
	}
	defer {
		agent_stop(&agent)
		thread.join(worker)
		thread.destroy(worker)
	}
	wait_agent_connected(t, &agent)
	before, found := brk.lookup_service_for_environment(&fx.reg, "", sid, "org/dev")
	if !testing.expect(t, found, "first registration") {
		return
	}

	// Hold the same teardown counter used by an OPEN worker still dialing
	// locally, so the read exits can check the timestamp across that wait.
	pending: ^AgentRelay
	defer if pending != nil {
		sync.atomic_sub(&pending.opening, 1)
	}
	if hold_teardown {
		sync.mutex_lock(&agent.mutex)
		pending = agent.live_relay
		if pending != nil {
			sync.atomic_add(&pending.opening, 1)
		}
		sync.mutex_unlock(&agent.mutex)
		if !testing.expect(t, pending != nil, "live relay to hold during close") {
			return
		}
	}

	registrations := &fx.reg
	if fault == .Drain {
		brk.server_drain(&fx.server, 0)
		start_test_broker(t, &successor)
		sync.mutex_lock(&proxy.mu)
		proxy.target = broker_endpoint(t, &successor)
		sync.mutex_unlock(&proxy.mu)
		registrations = &successor.reg
	} else if !cut_existing_link(t, &proxy, fault) {
		return
	}
	released_at: time.Time
	if pending != nil {
		agent_test_wait_until_stream_wait(&agent)
		// Keep the two observations distinct even at coarse clock resolution.
		time.sleep(25 * time.Millisecond)
		released_at = time.now()
		sync.atomic_sub(&pending.opening, 1)
		pending = nil
	}
	agent_closed := wait_close_log(t, &close_agent_log, "disconnected", "close_cause", cause)
	broker_closed := wait_close_log(t, &close_broker_log, "session_closed", "reason", "idle_timeout" if fault == .Deadline else cause)
	if !agent_closed || !broker_closed {
		return
	}
	if released_at != {} {
		sync.mutex_lock(&close_agent_log.mutex)
		lines := string(close_agent_log.text[:])
		for line in strings.split_lines_iterator(&lines) {
			if strings.contains(line, "\"event\":\"disconnected\"") {
				record: struct { ts: f64 }
				err := json.unmarshal(transmute([]u8)line, &record)
				testing.expect_value(t, err, nil)
				released_ts := f64(time.time_to_unix_nano(released_at)) / 1e9
				testing.expect(t, record.ts > 0 && record.ts < released_ts, "disconnect timestamp includes teardown wait")
				break
			}
		}
		sync.mutex_unlock(&close_agent_log.mutex)
	}
	start := time.tick_now()
	for time.tick_since(start) < 6 * time.Second {
		after, registered := brk.lookup_service_for_environment(registrations, "", sid, "org/dev")
		if registered && (registrations != &fx.reg || after.agent_session != before.agent_session) && agent_is_connected(&agent) {
			sync.mutex_lock(&close_agent_log.mutex)
			records := string(close_agent_log.text[:])
			registered_twice := strings.count(records, "\"event\":\"registered\"") == 2
			disconnected_once := strings.count(records, "\"event\":\"disconnected\"") == 1
			sync.mutex_unlock(&close_agent_log.mutex)
			testing.expect(t, registered_twice && disconnected_once, "one close and a fresh registration")
			agent_stop(&agent)
			_ = wait_close_log(t, &close_agent_log, "disconnected", "close_cause", "local_close")
			fmt.printf("close fault %v: agent=%s broker=%s re-registered\n", fault, cause, "idle_timeout" if fault == .Deadline else cause)
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, "fresh broker registration missing")
}

@(test)
test_agent_and_broker_log_link_cut_and_restart_causes :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 45 * time.Second)
	run_close_fault(t, .EOF, "peer_eof")
	run_close_fault(t, .Reset, "peer_reset")
	run_close_fault(t, .TLSAlert, "tls_alert")
	run_close_fault(t, .Deadline, "read_deadline")
	run_close_fault(t, .Drain, "broker_drain")
}

@(test)
test_agent_classifies_connection_error_frames :: proc(t: ^testing.T) {
	payload, err := proto.encode_wire_failure({code = proto.wire_error_to_u16(.BrokerDraining), diagnostic = "draining"})
	defer delete(payload)
	testing.expect_value(t, err, proto.ProtocolError.None)
	frame := proto.Frame{header = {opcode = .Error}, payload = payload}
	testing.expect_value(t, agent_relay_error_cause(frame), trans.CloseCause.BrokerDrain)
	frame.header.stream_id = 1
	testing.expect_value(t, agent_relay_error_cause(frame), trans.CloseCause.ProtocolError)
	frame.header.stream_id = proto.CONNECTION_STREAM_ID
	frame.payload = payload[:1]
	testing.expect_value(t, agent_relay_error_cause(frame), trans.CloseCause.ProtocolError)
}
