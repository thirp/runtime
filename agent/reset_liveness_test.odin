package agent

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:container/queue"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

when ODIN_TEST {
	@(test)
	test_agent_cancellation_retires_blocked_terminal_replies :: proc(t: ^testing.T) {
		agent := Agent{}
		relay := AgentRelay{agent = &agent}
		writer := AgentControlWriter{relay = &relay}
		_ = queue.init(&writer.pending)
		defer queue.destroy(&writer.pending)
		live := proto.StreamId(1)
		agent_relay_write_failure(nil, &writer, .Reset, .InternalError, live)
		agent_relay_write_failure(nil, &writer, .Reset, .InternalError, live)
		for i in 2 ..< 2 * DEFAULT_AGENT_MAX_STREAMS {
			id := proto.StreamId(i)
			agent_handle_open(&relay, {header = {opcode = .Open, stream_id = id}}, &writer)
			testing.expect_value(t, queue.len(writer.pending), 2)
			agent_handle_terminal(&relay, id, &writer)
			testing.expect_value(t, queue.len(writer.pending), 1)
		}
		frame := queue.front(&writer.pending)
		testing.expect(t, frame.stream_id == live && frame.opcode == .Reset)
		attempt := AgentControlAttempt{&writer, frame}
		agent_handle_terminal(&relay, live, &writer)
		testing.expect_value(t, queue.len(writer.pending), 0)
		testing.expect(t, !agent_control_claim(&attempt), "a reply selected before cancellation cannot claim the socket")
	}

	ResetRelayTrial :: struct {
		relay: ^AgentRelay,
		decoder: proto.FrameDecoder,
		cause: trans.CloseCause,
		closed_at: time.Time,
		dead_peer: bool,
	}

	reset_relay_log: log.Capture

	reset_relay_log_sink :: proc(line: string) {
		log.capture_sink(&reset_relay_log, line)
	}

	run_reset_relay :: proc(trial: ^ResetRelayTrial) {
		trial.cause, trial.closed_at, trial.dead_peer = agent_relay_loop(trial.relay, &trial.decoder)
		agent_log_disconnected(trial.relay.agent, trial.cause, trial.closed_at, trial.dead_peer)
	}

	@(test)
	test_agent_cancel_churn_keeps_live_session_with_writer_held :: proc(t: ^testing.T) {
		testing.set_fail_timeout(t, 3 * DEAD_PEER_TIMEOUT)
		socket, peer, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(socket)
		defer trans.connection_destroy(peer)
		agent: Agent
		relay := AgentRelay{agent = &agent, broker = socket, streams = make(map[proto.StreamId]AgentLocalStream)}
		defer delete(relay.streams)
		defer agent_clear_all(&relay)
		sentinel: proto.StreamId = 1
		tx := agent_tx_new(&relay.queued_bytes)
		if !testing.expect(t, tx != nil) {
			return
		}
		relay.streams[sentinel] = {tx = tx}
		trial := ResetRelayTrial{relay = &relay}
		_ = proto.decoder_init(&trial.decoder)
		defer proto.decoder_destroy(&trial.decoder)
		sync.mutex_lock(&socket.write_mutex)
		held := true
		reader := thread.create_and_start_with_poly_data(&trial, run_reset_relay)
		defer {
			if held {
				sync.mutex_unlock(&socket.write_mutex)
			}
			trans.connection_shutdown_both(socket)
			if reader != nil {
				thread.destroy(reader)
			}
		}
		if !testing.expect(t, reader != nil) {
			return
		}
		open, open_err := proto.encode_open({service_id = "absent/local"})
		defer delete(open)
		reset, reset_err := proto.encode_wire_failure({code = proto.wire_error_to_u16(.InternalError)})
		defer delete(reset)
		if !testing.expect(t, open_err == .None && reset_err == .None) {
			return
		}
		send := proc(conn: ^trans.Connection, opcode: proto.Opcode, sid: proto.StreamId, data: []u8) -> bool {
			terr, perr := trans.write_frame(conn, opcode, data, sid)
			return terr == .None && perr == .None
		}
		last := proto.StreamId(2 * DEFAULT_AGENT_MAX_STREAMS)
		for id in sentinel + 1 ..< last {
			if !testing.expect(t, send(peer, .Open, id, open) && send(peer, .Reset, id, reset), "send OPEN followed by cancellation") {
				return
			}
		}
		if !testing.expect(t, send(peer, .Open, last, open) && send(peer, .Close, sentinel, nil), "send a live OPEN then the reader marker") {
			return
		}
		start := time.tick_now()
		for {
			current, found := agent_lookup_tx(&relay, sentinel)
			if current != nil {
				agent_tx_release(current)
			}
			if !found {
				break
			}
			if !testing.expect(t, time.tick_since(start) < DEAD_PEER_TIMEOUT, "reader consumed the churn while the writer was held") {
				return
			}
			time.sleep(time.Millisecond)
		}
		testing.expect_value(t, trans.connection_close_cause(socket), trans.CloseCause.None)
		sync.mutex_unlock(&socket.write_mutex)
		held = false
		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		_ = trans.connection_set_recv_timeout(peer, DEAD_PEER_TIMEOUT)
		for {
			frame, terr, perr := trans.read_frame(peer, &decoder)
			defer proto.frame_destroy(&frame)
			if !testing.expect(t, terr == .None && perr == .None, "receive the remaining live reply") {
				return
			}
			if frame.header.opcode == .Ping {
				continue
			}
			testing.expect(t, frame.header.opcode == .OpenFailed && frame.header.stream_id == last,
				"the live reply reached the peer without obsolete replies ahead of it")
			return
		}
	}

	@(test)
	test_agent_reset_reader_preserves_true_close_cause :: proc(t: ^testing.T) {
		testing.set_fail_timeout(t, 3 * DEAD_PEER_TIMEOUT)
		socket, peer, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(socket)
		defer trans.connection_destroy(peer)
		defer delete(reset_relay_log.text)
		logger: log.Logger
		log.logger_init(&logger, .Info, reset_relay_log_sink)
		deadline :: 600 * time.Millisecond
		clock: WatchdogTestClock
		agent := Agent{config = {logger = &logger, max_stream_buffer = 1}}
		agent.config.test_dead_peer_timeout = deadline
		agent.config.test_watchdog_clock = &clock
		relay := AgentRelay{agent = &agent, broker = socket, streams = make(map[proto.StreamId]AgentLocalStream)}
		defer delete(relay.streams)
		defer agent_clear_all(&relay)

		reset_id: proto.StreamId = 7
		open_id: proto.StreamId = 9
		tx := agent_tx_new(&relay.queued_bytes)
		if !testing.expect(t, tx != nil, "allocate local TX queue") {
			return
		}
		relay.streams[reset_id] = {tx = tx}
		if !testing.expect_value(t, agent_tx_enqueue(tx, []u8{'a'}, 1, 0), AgentEnqueueResult.Queued) {
			return
		}
		trial := ResetRelayTrial{relay = &relay}
		_ = proto.decoder_init(&trial.decoder)
		defer proto.decoder_destroy(&trial.decoder)
		thread_handle := thread.create_and_start_with_poly_data(&trial, run_reset_relay)
		if !testing.expect(t, thread_handle != nil, "start agent relay") {
			return
		}
		defer {
			trans.connection_shutdown_both(socket)
			thread.destroy(thread_handle)
		}

		// Model a DATA writer waiting for the remote to read. The mutex hold
		// is independent of OS socket buffer sizes and lets inbound frames
		// from that same remote keep arriving.
		sync.mutex_lock(&socket.write_mutex)
		released := false
		defer if !released {
			sync.mutex_unlock(&socket.write_mutex)
		}
		terr, perr := trans.write_frame(peer, .Data, []u8{'b'}, reset_id)
		if !testing.expectf(t, terr == .None && perr == .None, "send DATA that forces a RESET (%v/%v)", terr, perr) {
			return
		}
		terr, perr = trans.write_frame(peer, .Open, nil, open_id)
		if !testing.expect(t, terr == .None && perr == .None, "send OPEN requiring an immediate failure") {
			return
		}
		ping, _ := proto.encode_ping({nonce = 42})
		defer delete(ping)
		for step in 0 ..= 6 {
			elapsed := time.Duration(step) * (deadline / 2)
			if step > 0 {
				sync.atomic_store(&clock.elapsed, i64(elapsed))
				sync.sema_post(&clock.wake)
				if !testing.expect(t, sync.sema_wait_with_timeout(&clock.checked, DEAD_PEER_TIMEOUT), "watchdog sampled the advanced clock") {
					return
				}
			}
			terr, perr = trans.write_frame(peer, .Ping, ping)
			if !testing.expect(t, terr == .None && perr == .None, "send Ping while the RESET writer is held") {
				return
			}
			if !sync.sema_wait_with_timeout(&clock.ping_read, DEAD_PEER_TIMEOUT) {
				// A synchronous RESET prevents the Ping read. Exercise the
				// real watchdog path before releasing the blocked writer.
				sync.atomic_store(&clock.elapsed, i64(elapsed + deadline))
				sync.sema_post(&clock.wake)
				if !testing.expect(t, sync.sema_wait_with_timeout(&clock.checked, DEAD_PEER_TIMEOUT), "watchdog sampled the blocked reader") {
					return
				}
				sync.mutex_unlock(&socket.write_mutex)
				released = true
				trans.connection_shutdown_both(socket)
				thread.join(thread_handle)
				testing.expectf(t, false, "A2: agent did not read Ping %d while writing RESET (dead_peer=%v, cause=%v)", step, trial.dead_peer, trial.cause)
				return
			}
		}
		sync.mutex_unlock(&socket.write_mutex)
		released = true
		if !testing.expectf(t, terr == .None && perr == .None && trans.connection_close_cause(socket) == .None,
			"A2: live agent lost its session while writing RESET (cause=%v)", trans.connection_close_cause(socket)) {
			thread.join(thread_handle)
			testing.expectf(t, !trial.dead_peer, "A2: live peer reported dead (cause=%v)", trial.cause)
			return
		}

		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		_ = trans.connection_set_recv_timeout(peer, DEAD_PEER_TIMEOUT)
		got_reset, got_open_failure := false, false
		for !(got_reset && got_open_failure) {
			frame, read_err, decode_err := trans.read_frame(peer, &decoder)
			if read_err != .None || decode_err != .None {
				break
			}
			#partial switch frame.header.opcode {
			case .Reset, .OpenFailed:
				failure, failure_err := proto.decode_wire_failure(frame.payload)
				code, _ := proto.wire_error_from_u16(failure.code)
				if frame.header.opcode == .Reset {
					got_reset = frame.header.stream_id == reset_id && failure_err == .None && code == .InternalError
				} else {
					got_open_failure = frame.header.stream_id == open_id && failure_err == .None && code == .ProtocolError
				}
				delete(failure.diagnostic)
			case:
			}
			proto.frame_destroy(&frame)
		}
		testing.expect(t, got_reset, "the queued RESET did not reach the peer")
		testing.expect(t, got_open_failure, "the queued OPEN_FAILED did not reach the peer")

		payload, _ := proto.encode_wire_failure({code = proto.wire_error_to_u16(.BrokerDraining)})
		defer delete(payload)
		terr, perr = trans.write_frame(peer, .Error, payload)
		if !testing.expect(t, terr == .None && perr == .None, "send broker drain") {
			return
		}
		thread.join(thread_handle)
		testing.expect_value(t, trial.cause, trans.CloseCause.BrokerDrain)
		testing.expect(t, !trial.dead_peer, "A2: live peer reported dead")
		line := string(reset_relay_log.text[:])
		testing.expect(t, strings.contains(line, `"event":"disconnected"`) &&
			strings.contains(line, `"close_cause":"broker_drain"`) && !strings.contains(line, "dead_peer"), line)
		fmt.printfln("A2: seven Pings read across three simulated watchdog periods, then RESET, OPEN_FAILED, and close_cause=broker_drain")
	}

	@(test)
	test_agent_small_data_limit_rejects_only_unavailable_stream :: proc(t: ^testing.T) {
		socket, peer, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(socket)
		defer trans.connection_destroy(peer)
		// Keep unsolicited probes out of the reply sequence.
		agent := Agent{config = {max_buffered_bytes = 8, test_heartbeat_interval = DEAD_PEER_TIMEOUT}}
		relay := AgentRelay{agent = &agent, broker = socket}
		trial := ResetRelayTrial{relay = &relay}
		_ = proto.decoder_init(&trial.decoder)
		defer proto.decoder_destroy(&trial.decoder)
		thread_handle := thread.create_and_start_with_poly_data(&trial, run_reset_relay)
		if !testing.expect(t, thread_handle != nil, "start agent relay") {
			return
		}
		defer {
			trans.connection_shutdown_both(socket)
			thread.destroy(thread_handle)
		}

		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		_ = trans.connection_set_recv_timeout(peer, 3 * time.Second)
		stream_id: proto.StreamId = 7
		open_payload, _ := proto.encode_open({service_id = "unavailable"})
		defer delete(open_payload)
		terr, perr := trans.write_frame(peer, .Open, open_payload, stream_id)
		if !testing.expectf(t, terr == .None && perr == .None, "send OPEN (%v/%v)", terr, perr) {
			return
		}
		rejected, read_err, decode_err := trans.read_frame(peer, &decoder)
		if !testing.expectf(t, read_err == .None && decode_err == .None,
			"expected OPEN_FAILED, got %v/%v (agent close cause=%v)", read_err, decode_err,
			trans.connection_close_cause(socket)) {
			return
		}
		defer proto.frame_destroy(&rejected)
		testing.expect_value(t, rejected.header.opcode, proto.Opcode.OpenFailed)
		testing.expect_value(t, rejected.header.stream_id, stream_id)
		failure, failure_err := proto.decode_wire_failure(rejected.payload)
		defer delete(failure.diagnostic)
		testing.expect_value(t, failure_err, proto.ProtocolError.None)
		testing.expect_value(t, failure.code, proto.wire_error_to_u16(.LocalServiceUnavailable))

		nonce :: 42
		ping, _ := proto.encode_ping({nonce = nonce})
		defer delete(ping)
		terr, perr = trans.write_frame(peer, .Ping, ping)
		if !testing.expectf(t, terr == .None && perr == .None, "send Ping on the same session (%v/%v)", terr, perr) {
			return
		}
		reply: proto.Frame
		reply, read_err, decode_err = trans.read_frame(peer, &decoder)
		if !testing.expectf(t, read_err == .None && decode_err == .None, "expected Pong, got %v/%v", read_err, decode_err) {
			return
		}
		defer proto.frame_destroy(&reply)
		testing.expect_value(t, reply.header.opcode, proto.Opcode.Pong)
		pong, pong_err := proto.decode_pong(reply.payload)
		testing.expect_value(t, pong_err, proto.ProtocolError.None)
		testing.expect_value(t, pong.nonce, u64(nonce))
		testing.expect_value(t, trans.connection_close_cause(socket), trans.CloseCause.None)
	}
}
