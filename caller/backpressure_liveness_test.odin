package caller

import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "core:bytes"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

when ODIN_TEST {
	// Run the admitted caller reader without reconnecting, so a replacement
	// socket cannot mask a watchdog drop.
	start_liveness_session :: proc(c: ^Caller) -> bool {
		caller_bind_session(c, c.conn)
		if proto.decoder_init(&c.decoder) != .None {
			return false
		}
		c.last_recv = time.tick_now()
		c.last_ping = c.last_recv
		c.connected = true
		c.writer = thread.create_and_start_with_poly_data(c, caller_writer_proc)
		c.reader = thread.create_and_start_with_poly_data(c, proc(c: ^Caller) {
			_ = caller_read_session(c)
		})
		return c.writer != nil && c.reader != nil
	}

	UploadBroker :: struct {
		handler: brk.ConnHandler,
		stop:  bool, // atomic
	}

	ProbePongs :: struct {
		mutex:       sync.Mutex,
		count:       int,
		last:        time.Tick,
		longest_gap: time.Duration,
		first:       sync.Sema,
	}

	record_probe_pong :: proc(_: proto.Pong, data: rawptr) {
		// Count the broker's backpressure Pings as well. The caller writer
		// can coalesce a test reply with a newer backpressure reply.
		record_probe_receive(data)
	}

	record_probe_receive :: proc(data: rawptr) {
		pongs := (^ProbePongs)(data)
		now := time.tick_now()
		sync.mutex_lock(&pongs.mutex)
		pongs.count += 1
		pongs.longest_gap = max(pongs.longest_gap, time.tick_diff(pongs.last, now))
		pongs.last = now
		if pongs.count == 1 {
			sync.sema_post(&pongs.first)
		}
		sync.mutex_unlock(&pongs.mutex)
	}

	send_liveness_probe :: proc(socket: ^trans.Connection) -> bool {
		payload, err := proto.encode_ping({nonce = u64(time.time_to_unix_nano(time.now()))})
		defer delete(payload)
		if err != .None {
			return false
		}
		terr, perr := trans.write_frame(socket, .Ping, payload)
		return terr == .None && perr == .None
	}

	read_upload_broker :: proc(b: ^UploadBroker) {
		h := &b.handler
		_ = proto.decoder_init(&h.decoder)
		defer proto.decoder_destroy(&h.decoder)
		_ = trans.connection_set_recv_timeout(h.conn, 50 * time.Millisecond)
		for !sync.atomic_load(&b.stop) {
			frame, err, perr := brk.conn_read_frame(h)
			if err == .Timeout {
				continue
			}
			if err != .None || perr != .None {
				return
			}
			closed := brk.conn_handle_frame(h, frame)
			proto.frame_destroy(&frame, h.server.allocator)
			if closed {
				return
			}
		}
	}

	LivenessUpload :: struct {
		blocked:    ^Conn,
		sibling:    ^Conn,
		socket:     ^trans.Connection,
		reset_seen: sync.Sema,
		stop:       bool, // atomic; stop after the in-flight write
	}

	BOUNDARY_SIBLING_SIZE :: 2 * (proto.HEADER_SIZE + size_of(proto.Pong))

	liveness_upload_proc :: proc(u: ^LivenessUpload) {
		chunk: [8 * 1024]u8
		if u.sibling != nil {
			// Put a caller Ping at the decoder boundary. After the broker
			// consumes it, the sibling DATA frame crosses the same boundary.
			for left := proto.DECODER_BUFFER_CAP; left > 0; {
				n := min(len(chunk), left - proto.HEADER_SIZE)
				if _, err := conn_write(u.blocked, chunk[:n]); err != .None {
					return
				}
				left -= proto.HEADER_SIZE + n
			}
			ping, perr := proto.encode_ping({nonce = max(u64) - 1})
			defer delete(ping)
			if perr != .None {
				return
			}
			if terr, err := trans.write_frame(u.socket, .Ping, ping); terr != .None || err != .None {
				return
			}
			sibling_chunk: [BOUNDARY_SIBLING_SIZE]u8
			for &b in sibling_chunk {
				b = 's'
			}
			if _, err := conn_write(u.sibling, sibling_chunk[:]); err != .None {
				return
			}
		}
		for !sync.atomic_load(&u.stop) {
			if _, err := conn_write(u.blocked, chunk[:]); err != .None {
				break
			}
			if u.sibling != nil {
				if _, err := conn_write(u.sibling, []u8{'s'}); err != .None {
					return
				}
			}
		}
		if u.sibling == nil {
			return
		}
		sync.sema_wait(&u.reset_seen)
		if sync.atomic_load(&u.stop) {
			return
		}
		// RESET has reached the caller and the in-flight upload has returned.
		// Queue trailing DATA and then a sibling marker while the test thread
		// keeps draining the sibling socket.
		if !caller_write(u.socket, .Data, []u8{'x'}, u.blocked.stream_id) {
			return
		}
		if _, err := conn_write(u.sibling, []u8{'r'}); err != .None {
			return
		}
		for !sync.atomic_load(&u.stop) {
			if _, err := conn_write(u.sibling, []u8{'s'}); err != .None {
				break
			}
			time.sleep(25 * time.Millisecond)
		}
	}

	liveness_stream :: proc(c: ^Caller, server: ^brk.Server, src, dest: ^trans.Connection, sid: proto.StreamId) -> ^Conn {
		stream := conn_new(c)
		stream.stream_id = sid
		c.streams[sid] = stream
		_ = trans.connection_acquire(src)
		_ = trans.connection_acquire(dest)
		server.streams[sid] = {id = sid, state = .Open, caller_conn = src, agent_conn = dest}
		return stream
	}

	OVERFLOW_PARTIAL_DRAINS :: 3

	OverflowDrain :: struct {
		source:  ^brk.ConnHandler,
		sid:     proto.StreamId,
		waiting: sync.Sema,
		started: time.Tick,
		drained: int, // atomic
	}

	overflow_drain_clock :: proc(box: ^brk.ConnOutbox, starting: bool, data: rawptr) -> time.Tick {
		trial := (^OverflowDrain)(data)
		now := time.tick_now()
		if starting {
			trial.started = now
			sync.sema_post(&trial.waiting)
			return now
		}
		drain_step :: brk.BACKPRESSURE_PING_INTERVAL / (OVERFLOW_PARTIAL_DRAINS - 1)
		elapsed := time.tick_diff(trial.started, now)
		drained := sync.atomic_load(&trial.drained)
		for drained < OVERFLOW_PARTIAL_DRAINS &&
		    elapsed >= brk.CALLER_OVERFLOW_WAIT - brk.BACKPRESSURE_PING_INTERVAL + time.Duration(drained) * drain_step &&
		    brk.caller_input_overflow(trial.source, trial.sid) {
			// Leave one queued piece even at the recovery deadline. The
			// pending DATA needs the whole queue and still cannot fit.
			frame, ok := brk.outbox_take_next_locked(box)
			if !ok {
				break
			}
			delete(frame.payload, box.allocator)
			drained += 1
			sync.atomic_store(&trial.drained, drained)
		}
		return now
	}

	@(test)
	test_caller_watchdog_survives_full_destination :: proc(t: ^testing.T) {
		hold_duration :: 3 * max(DEAD_PEER_TIMEOUT, DEFAULT_SEND_STALL_TIMEOUT)
		testing.set_fail_timeout(t, hold_duration + 10 * time.Second)
		blocked_id: proto.StreamId = 7
		sibling_id: proto.StreamId = 9

		socket, broker_socket, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
		ping_observation := ProbePongs{last = time.tick_now()}
		c := Caller{conn = socket, streams = make(map[proto.StreamId]^Conn)}
		c.config.test_ping_received = record_probe_receive
		c.config.test_ping_user = &ping_observation
		blocked, sibling: ^Conn
		defer {
			caller_destroy(&c)
			conn_release(sibling)
			conn_release(blocked)
		}
		defer trans.connection_destroy(broker_socket)
		if !testing.expect_value(t, net.set_option(socket.socket, .Send_Buffer_Size, 16 * 1024), net.Socket_Option_Error.None) {
			return
		}
		blocked_socket, blocked_peer, blocked_err := trans.test_stream_pair()
		if !testing.expect_value(t, blocked_err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(blocked_socket)
		defer trans.connection_destroy(blocked_peer)
		sibling_socket, sibling_peer, sibling_err := trans.test_stream_pair()
		if !testing.expect_value(t, sibling_err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(sibling_socket)
		defer trans.connection_destroy(sibling_peer)

		server: brk.Server
		brk.server_init(&server, nil, {})
		defer brk.server_destroy(&server)
		server.max_stream_buffer = 8 * 1024
		blocked = liveness_stream(&c, &server, broker_socket, blocked_socket, blocked_id)
		sibling = liveness_stream(&c, &server, broker_socket, sibling_socket, sibling_id)

		src := UploadBroker{handler = {server = &server, conn = broker_socket, state = .Authenticated, role = .Caller}}
		dst := brk.ConnHandler{server = &server, conn = blocked_socket}
		healthy := brk.ConnHandler{server = &server, conn = sibling_socket}
		handlers := [?]^brk.ConnHandler{&src.handler, &dst, &healthy}
		defer {
			brk.conn_stop_outbox(&healthy)
			brk.conn_stop_outbox(&dst)
			brk.conn_stop_outbox(&src.handler)
		}
		for h in handlers {
			if !testing.expect(t, brk.conn_start_outbox(h), "start broker outbox") {
				return
			}
		}
		if !testing.expect(t, start_liveness_session(&c) && caller_start_stall(&c), "start caller reader, writer and watchdog") {
			return
		}

		brk.outbox_set_writer_hold(dst.outbox, true)
		partial_drain := OverflowDrain{source = &src.handler, sid = blocked_id}
		dst.outbox.test_wait_data = &partial_drain
		dst.outbox.test_wait_clock = overflow_drain_clock
		upload := LivenessUpload{blocked = blocked, sibling = sibling, socket = socket}
		start := time.tick_now()
		pong_observation := ProbePongs{last = start}
		server.test_pong = record_probe_pong
		server.test_pong_data = &pong_observation
		reader := thread.create_and_start_with_poly_data(&src, read_upload_broker)
		writer: ^thread.Thread
		defer {
			sync.atomic_store(&upload.stop, true)
			sync.sema_post(&upload.reset_seen)
			sync.atomic_store(&src.stop, true)
			brk.outbox_close(dst.outbox)
			trans.connection_shutdown_both(socket)
			if writer != nil {
				thread.destroy(writer)
			}
			if reader != nil {
				thread.destroy(reader)
			}
		}
		if !testing.expect(t, reader != nil, "start broker reader") {
			return
		}
		first_data: [8 * 1024]u8
		for _ in 0 ..< OVERFLOW_PARTIAL_DRAINS + 1 {
			_, send_err := conn_write(blocked, first_data[:len(first_data) / (OVERFLOW_PARTIAL_DRAINS + 1)])
			if !testing.expect_value(t, send_err, ConnError.None) {
				return
			}
		}
		_, pending_err := conn_write(blocked, first_data[:])
		if !testing.expect_value(t, pending_err, ConnError.None) ||
		   !testing.expect(t, sync.sema_wait_with_timeout(&partial_drain.waiting, DEAD_PEER_TIMEOUT), "the broker held the pending DATA") {
			return
		}
		// Exercise a caller Ping and a broker Ping while the pending DATA
		// holds the reader. Start the sustained upload once the broker has
		// processed the matching Pong through read-ahead.
		ping, _ := proto.encode_ping({nonce = max(u64)})
		defer delete(ping)
		ping_terr, ping_perr := trans.write_frame(socket, .Ping, ping)
		if !testing.expect(t, ping_terr == .None && ping_perr == .None && send_liveness_probe(broker_socket),
			"send keepalives in both directions while waiting for DATA space") ||
		   !testing.expect(t, sync.sema_wait_with_timeout(&pong_observation.first, DEAD_PEER_TIMEOUT), "the broker read a Pong while DATA was held") {
			return
		}
		writer = thread.create_and_start_with_poly_data(&upload, liveness_upload_proc)
		if !testing.expect(t, writer != nil, "start sustained caller upload") {
			return
		}

		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		_ = trans.connection_set_recv_timeout(sibling_peer, 10 * time.Millisecond)
		next_probe := time.tick_since(start) + CALLER_PING_INTERVAL
		last_upload: time.Tick
		longest_upload_gap, first_sibling, reset_at: time.Duration
		received := 0
		recovered := false
		for time.tick_since(start) < hold_duration {
			elapsed := time.tick_since(start)
			if elapsed >= next_probe {
				if !testing.expect(t, send_liveness_probe(broker_socket), "A1: Ping write failed") {
					return
				}
				next_probe += CALLER_PING_INTERVAL
			}
			sync.mutex_lock(&c.mutex)
			admitted, reason := c.connected, c.disconnect_reason
			sync.mutex_unlock(&c.mutex)
			if !testing.expectf(t, admitted && reason == "", "A1: uploading caller lost its session after %v (reason=%s)",
				elapsed, reason) {
				return
			}
			if reset_at == 0 {
				sync.mutex_lock(&blocked.mutex)
				got_reset := blocked.reset
				sync.mutex_unlock(&blocked.mutex)
				if got_reset {
					reset_at = time.tick_since(start)
					if !testing.expect(t, reset_at >= brk.CALLER_OVERFLOW_WAIT,
						"A1: broker reset the upload before the send-watchdog budget") {
						return
					}
					sync.sema_post(&upload.reset_seen)
				}
			}
			data, data_err, data_perr := trans.read_frame(sibling_peer, &decoder)
			if data_err == .Timeout {
				continue
			}
			expected_len := BOUNDARY_SIBLING_SIZE if received == 0 else 1
			valid := data_err == .None && data_perr == .None && data.header.opcode == .Data &&
				data.header.stream_id == sibling_id && len(data.payload) == expected_len
			if valid && received > 0 && bytes.equal(data.payload, []u8{'r'}) {
				valid = !recovered
				recovered = true
			} else {
				for b in data.payload {
					valid = valid && b == 's'
				}
			}
			proto.frame_destroy(&data)
			if !testing.expect(t, valid, "A1: sibling destination received unexpected data") {
				return
			}
			if received == 0 {
				first_sibling = time.tick_since(start)
			} else {
				longest_upload_gap = max(longest_upload_gap, time.tick_since(last_upload))
			}
			received += 1
			last_upload = time.tick_now()
		}

		sync.mutex_lock(&pong_observation.mutex)
		pongs := pong_observation.count
		longest_pong_gap := max(pong_observation.longest_gap, time.tick_since(pong_observation.last))
		sync.mutex_unlock(&pong_observation.mutex)
		testing.expectf(t, pongs >= 3, "A1: broker read only %d Pongs during the hold", pongs)
		sync.mutex_lock(&ping_observation.mutex)
		pings := ping_observation.count
		longest_ping_gap := max(ping_observation.longest_gap, time.tick_since(ping_observation.last))
		sync.mutex_unlock(&ping_observation.mutex)
		testing.expectf(t, pings >= 3 && longest_ping_gap < DEAD_PEER_TIMEOUT,
			"A1: caller read %d Pings during the hold with longest gap %v", pings, longest_ping_gap)
		testing.expect_value(t, caller_stream_load(&c), 1)
		sync.mutex_lock(&blocked.mutex)
		caller_reset := blocked.reset
		sync.mutex_unlock(&blocked.mutex)
		testing.expect(t, caller_reset && reset_at != 0, "A1: caller did not receive the saturated stream RESET during the hold")
		testing.expect(t, recovered, "A1: broker did not relay sibling DATA after the trailing DATA for the reset stream")
		resets := brk.metrics_snapshot(&server).resets
		drains := sync.atomic_load(&partial_drain.drained)
		testing.expect_value(t, drains, OVERFLOW_PARTIAL_DRAINS)
		testing.expect_value(t, resets[.StreamBuffer], 1)
		testing.expect_value(t, resets[.StreamNotFound], 0)
		if _, still_open := brk.relay_lookup_stream(&server, blocked_id); still_open {
			testing.expect(t, false, "A1: saturated stream survived instead of receiving RESET")
			return
		}
		if received > 0 {
			longest_upload_gap = max(longest_upload_gap, time.tick_since(last_upload))
		}
		testing.expectf(t, received > 0 && longest_upload_gap < DEFAULT_SEND_STALL_TIMEOUT,
			"A1: %d sibling frames during the hold with longest upload gap %v", received, longest_upload_gap)

		testing.expect_value(t, brk.outbox_queued(dst.outbox, blocked_id), 1)
		brk.outbox_set_writer_hold(dst.outbox, false)
		reset_decoder: proto.FrameDecoder
		_ = proto.decoder_init(&reset_decoder)
		defer proto.decoder_destroy(&reset_decoder)
		_ = trans.connection_set_recv_timeout(blocked_peer, time.Second)
		reset, reset_err, reset_perr := trans.read_frame(blocked_peer, &reset_decoder)
		defer proto.frame_destroy(&reset)
		failure, failure_err := proto.decode_wire_failure(reset.payload)
		defer delete(failure.diagnostic)
		testing.expect(t, reset_err == .None && reset_perr == .None && reset.header.opcode == .Reset &&
			reset.header.stream_id == blocked_id && failure_err == .None &&
			failure.code == proto.wire_error_to_u16(.InternalError), "A1: blocked destination did not receive stream overflow RESET")
		fmt.printfln("A1: caller read %d Pings over %v (longest gap %v), broker read %d Pongs (longest gap %v), RESET at %v after %d partial drains, and relayed %d sibling DATA frames (first at %v, longest gap %v)",
			pings, time.tick_since(start), longest_ping_gap, pongs, longest_pong_gap, reset_at, drains, received, first_sibling, longest_upload_gap)
	}

	SlowDrainClock :: struct {
		now:       time.Tick, // guarded by the destination outbox mutex
		sampled:   time.Tick,
		blocked:   sync.Sema,
		observed:  sync.Sema,
	}

	slow_drain_clock :: proc(_: ^brk.ConnOutbox, starting: bool, data: rawptr) -> time.Tick {
		clock := (^SlowDrainClock)(data)
		if starting {
			sync.sema_post(&clock.blocked)
		} else if clock.sampled != clock.now {
			clock.sampled = clock.now
			sync.sema_post(&clock.observed)
		}
		return clock.now
	}

	@(test)
	test_caller_slow_drain_survives_sustained_upload :: proc(t: ^testing.T) {
		drain_interval :: brk.BACKPRESSURE_PING_INTERVAL / 2
		drain_cycles :: 16
		upload_bytes :: 8 * 1024
		drain_bytes :: upload_bytes / drain_cycles
		#assert(drain_cycles * (drain_bytes + proto.HEADER_SIZE) < proto.DECODER_BUFFER_CAP)
		testing.set_fail_timeout(t, 3 * DEAD_PEER_TIMEOUT)
		sid: proto.StreamId = 7
		socket, broker_socket, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(broker_socket)
		c := Caller{conn = socket, streams = make(map[proto.StreamId]^Conn)}
		stream: ^Conn
		defer {
			caller_destroy(&c)
			conn_release(stream)
		}
		dest, peer, dest_err := trans.test_stream_pair()
		if !testing.expect_value(t, dest_err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(dest)
		defer trans.connection_destroy(peer)
		server: brk.Server
		brk.server_init(&server, nil, {})
		defer brk.server_destroy(&server)
		server.max_stream_buffer = upload_bytes
		pongs := ProbePongs{last = time.tick_now()}
		server.test_pong = record_probe_pong
		server.test_pong_data = &pongs
		stream = liveness_stream(&c, &server, broker_socket, dest, sid)
		src := UploadBroker{handler = {server = &server, conn = broker_socket, state = .Authenticated, role = .Caller}}
		dst := brk.ConnHandler{server = &server, conn = dest}
		defer brk.conn_stop_outbox(&src.handler)
		defer brk.conn_stop_outbox(&dst)
		if !testing.expect(t, brk.conn_start_outbox(&src.handler) && brk.conn_start_outbox(&dst), "start broker outboxes") ||
		   !testing.expect(t, start_liveness_session(&c) && caller_start_stall(&c), "start caller session") {
			return
		}
		brk.outbox_set_writer_hold(dst.outbox, true)
		clock: SlowDrainClock
		dst.outbox.test_wait_clock = slow_drain_clock
		dst.outbox.test_wait_data = &clock
		// The first pending upload needs the whole queue, so each dequeue
		// makes progress without admitting it until the final piece.
		piece: [drain_bytes]u8
		piece[0] = 'q'
		for _ in 0 ..< drain_cycles {
			if !testing.expect_value(t, brk.outbox_enqueue(dst.outbox, .Data, sid, piece[:]), brk.OutboxEnqueueError.None) {
				return
			}
		}
		reader := thread.create_and_start_with_poly_data(&src, read_upload_broker)
		defer {
			sync.atomic_store(&src.stop, true)
			brk.outbox_close(dst.outbox)
			trans.connection_shutdown_both(socket)
			if reader != nil {
				thread.destroy(reader)
			}
		}
		if !testing.expect(t, reader != nil, "start broker reader") {
			return
		}
		pending: [upload_bytes]u8
		pending[0] = 'p'
		_, send_err := conn_write(stream, pending[:])
		if !testing.expect_value(t, send_err, ConnError.None) ||
		   !testing.expect(t, sync.sema_wait_with_timeout(&clock.blocked, DEAD_PEER_TIMEOUT), "the upload blocked on the full queue") ||
		   !testing.expect(t, send_liveness_probe(broker_socket), "send Ping while the upload waits") {
			return
		}
		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		_ = trans.connection_set_recv_timeout(peer, DEAD_PEER_TIMEOUT)
		following: [drain_cycles][drain_bytes]u8
		for cycle in 0 ..< drain_cycles {
			// Keep uploading while the first pending frame waits. Pace
			// writes by the drain events so read-ahead always has room.
			following[cycle][0] = u8(cycle)
			if _, write_err := conn_write(stream, following[cycle][:]); !testing.expect_value(t, write_err, ConnError.None) {
				return
			}
			// Move test time and dequeue under the same mutex so the broker
			// observes the drain at that tick, independent of scheduling.
			sync.mutex_lock(&dst.outbox.mutex)
			clock.now = time.tick_add(clock.now, drain_interval)
			queued, ok := brk.outbox_take_next_locked(dst.outbox)
			sync.cond_broadcast(&dst.outbox.cond)
			sync.mutex_unlock(&dst.outbox.mutex)
			if !testing.expect(t, ok, "the destination queue was empty at a drain event") {
				return
			}
			defer delete(queued.payload, dst.outbox.allocator)
			if !testing.expect(t, sync.sema_wait_with_timeout(&clock.observed, DEAD_PEER_TIMEOUT), "broker observed the partial drain") {
				return
			}
			if cycle + 1 == int(brk.BACKPRESSURE_PING_INTERVAL / drain_interval) {
				if !testing.expect(t, sync.sema_wait_with_timeout(&pongs.first, DEAD_PEER_TIMEOUT),
					"broker read a Pong before any partial drain could admit the pending DATA") {
					return
				}
				testing.expect_value(t, brk.outbox_queued(dst.outbox, sid), drain_cycles - cycle - 1)
			}
			write_err, write_perr := trans.write_frame(dest, queued.opcode, queued.payload, queued.stream_id)
			if !testing.expect(t, write_err == .None && write_perr == .None, "write one queued frame") {
				return
			}
			frame, terr, perr := trans.read_frame(peer, &decoder)
			valid := terr == .None && perr == .None && frame.header.opcode == .Data &&
				frame.header.stream_id == sid && bytes.equal(frame.payload, piece[:])
			proto.frame_destroy(&frame)
			if !testing.expect(t, valid, "the paused destination resumed with DATA") {
				return
			}
		}
		if !testing.expect(t, sync.sema_wait_with_timeout(&clock.blocked, DEAD_PEER_TIMEOUT),
			"the final drain admitted the pending frame and the reader advanced to the following DATA") {
			return
		}
		brk.outbox_set_writer_hold(dst.outbox, false)
		for i in 0 ..< drain_cycles + 1 {
			expected := pending[:] if i == 0 else following[i - 1][:]
			frame, terr, perr := trans.read_frame(peer, &decoder)
			valid := terr == .None && perr == .None && frame.header.opcode == .Data &&
				frame.header.stream_id == sid && bytes.equal(frame.payload, expected)
			proto.frame_destroy(&frame)
			if !testing.expectf(t, valid, "slow destination lost or reordered DATA at frame %d", i) {
				return
			}
		}
		testing.expect_value(t, brk.metrics_snapshot(&server).resets[.StreamBuffer], 0)
		testing.expect_value(t, caller_stream_load(&c), 1)
		testing.expect(t, caller_is_connected(&c), "the caller session survived the slow drain")
		fmt.printfln("A1: slow destination admitted the pending frame at simulated %v and delivered all %d DATA bytes with no RESET",
			drain_cycles * drain_interval, 3 * upload_bytes)
	}

	PausedUpload :: enum { Small, WithParserSpace, Completed }

	paused_destination_trial :: proc(t: ^testing.T, stall_timeout: time.Duration, mode: PausedUpload = .Small) {
		stream_id: proto.StreamId = 7
		required_pings :: 5
		chunk_size :: 8 * 1024
		wire_chunk_size :: chunk_size + proto.HEADER_SIZE
		// After the first two DATA frames, fill the decoder with full
		// chunks and a final DATA frame ending one byte into the tail.
		// The existing HALF_CLOSE then fits behind it.
		full_chunks :: proto.DECODER_BUFFER_CAP / wire_chunk_size
		final_chunk_size :: proto.DECODER_BUFFER_CAP + 1 - full_chunks * wire_chunk_size - proto.HEADER_SIZE
		socket, broker_socket, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(socket)
		defer trans.connection_destroy(broker_socket)
		dest, peer, dest_err := trans.test_stream_pair()
		if !testing.expect_value(t, dest_err, trans.TransportError.None) {
			return
		}
		defer trans.connection_destroy(dest)
		defer trans.connection_destroy(peer)

		chunks: [2 + full_chunks + 1][chunk_size]u8
		payloads: [len(chunks)][]u8
		upload := payloads[:3]
		switch mode {
		case .Small:
		case .WithParserSpace:
			upload = payloads[:2 + full_chunks]
		case .Completed:
			upload = payloads[:]
		}
		for &payload, i in upload {
			for &b, j in chunks[i] {
				b = u8((i + j) % 251)
			}
			payload = chunks[i][:]
		}
		if mode == .Completed {
			last := len(upload) - 1
			upload[last] = upload[last][:final_chunk_size]
		}
		server: brk.Server
		brk.server_init(&server, nil, {})
		defer brk.server_destroy(&server)
		server.max_stream_buffer = chunk_size
		server.stream_stall_timeout = stall_timeout
		pongs := ProbePongs{last = time.tick_now()}
		if mode == .WithParserSpace {
			server.test_pong = record_probe_pong
			server.test_pong_data = &pongs
		}
		_ = trans.connection_acquire(broker_socket)
		_ = trans.connection_acquire(dest)
		server.streams[stream_id] = {id = stream_id, state = .Open, caller_conn = broker_socket, agent_conn = dest}

		src := UploadBroker{handler = {server = &server, conn = broker_socket, state = .Authenticated, role = .Caller}}
		dst := brk.ConnHandler{server = &server, conn = dest}
		defer brk.conn_stop_outbox(&src.handler)
		defer brk.conn_stop_outbox(&dst)
		if !testing.expect(t, brk.conn_start_outbox(&src.handler) && brk.conn_start_outbox(&dst), "start broker outboxes") {
			return
		}
		brk.outbox_set_writer_hold(dst.outbox, true)
		clock: SlowDrainClock
		if mode == .WithParserSpace {
			dst.outbox.test_wait_clock = slow_drain_clock
			dst.outbox.test_wait_data = &clock
		}
		reader := thread.create_and_start_with_poly_data(&src, read_upload_broker)
		defer {
			sync.atomic_store(&src.stop, true)
			brk.outbox_close(dst.outbox)
			trans.connection_shutdown_both(socket)
			if reader != nil {
				thread.destroy(reader)
			}
		}
		if !testing.expect(t, reader != nil, "start broker reader") {
			return
		}

		// One frame fills the queue and the next makes the broker reader wait.
		for payload in upload[:2] {
			terr, perr := trans.write_frame(socket, .Data, payload, stream_id)
			if !testing.expectf(t, terr == .None && perr == .None, "write DATA for timeout %v (%v/%v)", stall_timeout, terr, perr) {
				return
			}
		}

		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		_ = trans.connection_set_recv_timeout(socket, 50 * time.Millisecond)
		start := time.tick_now()
		first_ping: time.Tick
		pings := 0
		for pings < required_pings {
			if time.tick_since(start) >= (required_pings + 1) * brk.BACKPRESSURE_PING_INTERVAL {
				testing.expectf(t, false, "broker sent only %d of %d backpressure Pings", pings, required_pings)
				return
			}
			frame, terr, perr := trans.read_frame(socket, &decoder)
			if terr == .Timeout {
				continue
			}
			defer proto.frame_destroy(&frame)
			if !testing.expectf(t, terr == .None && perr == .None && frame.header.opcode == .Ping,
				"paused upload with timeout %v got %v (%v/%v) after %v", stall_timeout, frame.header.opcode, terr, perr, time.tick_since(start)) {
				return
			}
			if first_ping == {} {
				first_ping = time.tick_now()
				// The first Ping confirms the broker reader is already waiting.
				// Leave DATA unread on the socket and delay Pong replies
				// even though the caller has finished uploading.
				if mode == .WithParserSpace {
					if !testing.expect(t, sync.sema_wait_with_timeout(&clock.blocked, DEAD_PEER_TIMEOUT), "the larger upload entered the outbox wait") {
						return
					}
					sync.mutex_lock(&dst.outbox.mutex)
					clock.now = time.tick_add(clock.now, brk.BACKPRESSURE_PING_INTERVAL)
					sync.cond_broadcast(&dst.outbox.cond)
					sync.mutex_unlock(&dst.outbox.mutex)
				}
				for payload in upload[2:] {
					terr, perr = trans.write_frame(socket, .Data, payload, stream_id)
					if !testing.expect(t, terr == .None && perr == .None, "write remaining DATA") {
						return
					}
				}
				if mode == .Completed {
					terr, perr = trans.write_frame(socket, .HalfClose, nil, stream_id)
					if !testing.expect(t, terr == .None && perr == .None, "write HALF_CLOSE") {
						return
					}
				}
			}
			pings += 1
			if mode == .WithParserSpace && pings == required_pings {
				// Drive the wait past the early reset point before reading the
				// Pong queued behind the larger upload. There is still parser room.
				sync.mutex_lock(&dst.outbox.mutex)
				clock.now = time.tick_add(clock.now, DEFAULT_SEND_STALL_TIMEOUT)
				sync.cond_broadcast(&dst.outbox.cond)
				sync.mutex_unlock(&dst.outbox.mutex)
				pong, pong_err := proto.encode_pong({nonce = 1})
				defer delete(pong)
				reply_terr, reply_perr := trans.write_frame(socket, .Pong, pong)
				if !testing.expect(t, pong_err == .None && reply_terr == .None && reply_perr == .None, "reply with parser space still available") {
					return
				}
			}
		}
		paused := time.tick_since(first_ping)
		if mode == .WithParserSpace {
			testing.expect(t, sync.sema_wait_with_timeout(&pongs.first, DEAD_PEER_TIMEOUT),
				"broker read a Pong behind the larger upload while the outbox remained held")
		}
		_, open := brk.relay_lookup_stream(&server, stream_id)
		testing.expect(t, open, "paused stream was reset")
		brk.outbox_set_writer_hold(dst.outbox, false)
		proto.decoder_reset(&decoder)
		_ = trans.connection_set_recv_timeout(peer, time.Second)
		delivered := 0
		for payload in upload {
			frame, terr, perr := trans.read_frame(peer, &decoder)
			defer proto.frame_destroy(&frame)
			if !testing.expectf(t, terr == .None && perr == .None && frame.header.opcode == .Data &&
				frame.header.stream_id == stream_id && bytes.equal(payload, frame.payload),
				"paused upload lost or reordered DATA (timeout %v, opcode %v, %v/%v)", stall_timeout, frame.header.opcode, terr, perr) {
				return
			}
			delivered += len(frame.payload)
		}
		if mode == .Completed {
			frame, terr, perr := trans.read_frame(peer, &decoder)
			defer proto.frame_destroy(&frame)
			testing.expect(t, terr == .None && perr == .None && frame.header.opcode == .HalfClose &&
				frame.header.stream_id == stream_id, "the destination received HALF_CLOSE after DATA")
		}
		fmt.printfln("A8: paused caller kept stream with timeout %v for %v through %d Pings and delivered all %d DATA bytes",
			stall_timeout, paused, pings, delivered)
	}

	@(test)
	test_review_paused_destination_keeps_queued_data :: proc(t: ^testing.T) {
		testing.set_fail_timeout(t, 25 * time.Second)
		paused_destination_trial(t, brk.DEFAULT_STREAM_STALL_TIMEOUT)
		paused_destination_trial(t, 0)
	}

	@(test)
	test_review_paused_destination_keeps_completed_upload_beyond_decoder :: proc(t: ^testing.T) {
		testing.set_fail_timeout(t, 25 * time.Second)
		paused_destination_trial(t, brk.DEFAULT_STREAM_STALL_TIMEOUT, .Completed)
		paused_destination_trial(t, 0, .Completed)
	}

	@(test)
	test_review_paused_destination_keeps_larger_upload_with_parser_space :: proc(t: ^testing.T) {
		testing.set_fail_timeout(t, 25 * time.Second)
		paused_destination_trial(t, brk.DEFAULT_STREAM_STALL_TIMEOUT, .WithParserSpace)
		paused_destination_trial(t, 0, .WithParserSpace)
	}

	DialWriteHold :: struct {
		release: sync.Sema,
	}

	hold_connect_completion :: proc(user: rawptr) {
		hold := (^DialWriteHold)(user)
		sync.sema_wait(&hold.release)
	}

	SlowCleanupDial :: struct {
		caller: ^Caller,
		elapsed: time.Duration,
		conn: ^Conn,
		err: CallerError,
		done: sync.Sema,
	}

	measure_cleanup_dial :: proc(d: ^SlowCleanupDial) {
		start := time.tick_now()
		d.conn, d.err = dial(d.caller, TEST_SERVICE)
		d.elapsed = time.tick_since(start)
		sync.sema_post(&d.done)
	}

	slow_cleanup_dial_trial :: proc(t: ^testing.T, deadline: time.Duration) -> time.Duration {
		socket, peer, err := trans.test_stream_pair()
		if !testing.expect_value(t, err, trans.TransportError.None) {
			return 0
		}
		defer trans.connection_destroy(peer)
		hold: DialWriteHold
		c := Caller{conn = socket, streams = make(map[proto.StreamId]^Conn)}
		c.config.dial_timeout = deadline
		c.config.test_connect_written = hold_connect_completion
		c.config.test_connect_user = &hold
		defer caller_destroy(&c)
		if !testing.expect(t, start_liveness_session(&c), "start caller reader and writer") {
			return 0
		}
		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		_ = trans.connection_set_recv_timeout(peer, deadline)
		call := SlowCleanupDial{caller = &c}
		dialer := thread.create_and_start_with_poly_data(&call, measure_cleanup_dial)
		if !testing.expect(t, dialer != nil, "start dial") {
			return 0
		}
		defer {
			thread.destroy(dialer)
			conn_destroy(call.conn)
		}
		released := false
		defer if !released {
			sync.sema_post(&hold.release)
		}
		frame, terr, perr := trans.read_frame(peer, &decoder)
		defer proto.frame_destroy(&frame)
		if !testing.expect(t, terr == .None && perr == .None && frame.header.opcode == .Connect, "peer received CONNECT") {
			return 0
		}
		sid: proto.StreamId = 9
		terr, perr = trans.write_frame(peer, .ConnectOk, nil, sid)
		if !testing.expect(t, terr == .None && perr == .None, "peer sent CONNECT_OK") {
			return 0
		}
		// The peer accepted CONNECT while the writer still has not reported
		// completion. Keep cleanup stalled until past the allowed return time.
		start := time.tick_now()
		for caller_stream_load(&c) == 0 && time.tick_since(start) < deadline / 2 {
			time.sleep(time.Millisecond)
		}
		if !testing.expect_value(t, caller_stream_load(&c), 1) {
			return 0
		}
		done := sync.sema_wait_with_timeout(&call.done, deadline + 150 * time.Millisecond)
		sync.sema_post(&hold.release)
		released = true
		thread.join(dialer)
		testing.expectf(t, done && call.elapsed <= deadline + 100 * time.Millisecond,
			"A3: failed dial exceeded deadline + 100ms (elapsed=%v, deadline=%v)", call.elapsed, deadline)
		testing.expect_value(t, call.err, CallerError.Timeout)
		testing.expect(t, call.conn == nil, "A3: failed dial returned a stream")
		testing.expect_value(t, caller_stream_load(&c), 0)
		if done {
			cleanup_opcodes := [?]proto.Opcode{.HalfClose, .Close}
			for opcode in cleanup_opcodes {
				cleanup, read_err, decode_err := trans.read_frame(peer, &decoder)
				testing.expect(t, read_err == .None && decode_err == .None &&
					cleanup.header.opcode == opcode && cleanup.header.stream_id == sid, "A3: accepted stream was not closed on its owning session")
				proto.frame_destroy(&cleanup)
			}
		}
		return call.elapsed
	}

	@(test)
	test_failed_dial_deadline_includes_slow_cleanup :: proc(t: ^testing.T) {
		deadline :: 300 * time.Millisecond
		max_elapsed: time.Duration
		for _ in 0 ..< 3 {
			max_elapsed = max(max_elapsed, slow_cleanup_dial_trial(t, deadline))
		}
		fmt.printfln("A3: failed dial maximum %v across 3 trials (deadline %v, allowance 100ms)", max_elapsed, deadline)
	}
}
