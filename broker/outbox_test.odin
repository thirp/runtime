package broker

import proto "../protocol"
import trans "../transport"
import "core:bytes"
import "core:testing"
import "core:time"

SID_A :: proto.StreamId(1)
SID_B :: proto.StreamId(2)

make_test_outbox :: proc(server: ^Server, stream_cap: int, conn_cap: int) -> ^ConnOutbox {
	server^ = {}
	server.allocator = context.allocator
	server.max_stream_buffer = stream_cap
	server.max_connection_buffer = conn_cap
	box := new(ConnOutbox)
	outbox_init(box, nil, server)
	return box
}

@(test)
test_outbox_enqueue_data_up_to_stream_cap :: proc(t: ^testing.T) {
	server: Server
	box := make_test_outbox(&server, 8, 64)
	defer outbox_release(box)

	payload := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, payload), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{9}), OutboxEnqueueError.StreamLimit)
	testing.expect_value(t, box.total_bytes, 8)
}

@(test)
test_outbox_connection_cap_fails_before_stream_cap :: proc(t: ^testing.T) {
	server: Server
	box := make_test_outbox(&server, 32, 8)
	defer outbox_release(box)

	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{1, 2, 3, 4, 5}), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_B, []u8{6, 7, 8, 9}), OutboxEnqueueError.ConnectionLimit)
	testing.expect_value(t, box.stream_bytes[SID_A], 5)
}

@(test)
test_outbox_control_frames_enqueue_at_data_cap :: proc(t: ^testing.T) {
	server: Server
	box := make_test_outbox(&server, 4, 4)
	defer outbox_release(box)

	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{1, 2, 3, 4}), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Close, SID_A, nil), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Reset, SID_A, nil), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .HalfClose, SID_A, nil), OutboxEnqueueError.None)
	testing.expect_value(t, box.total_bytes, 4)
}

@(test)
test_outbox_take_next_round_robins_streams :: proc(t: ^testing.T) {
	server: Server
	box := make_test_outbox(&server, 64, 64)
	defer outbox_release(box)

	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{'A', '1'}), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{'A', '2'}), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_B, []u8{'B', '1'}), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_B, []u8{'B', '2'}), OutboxEnqueueError.None)

	a1, ok1 := outbox_take_next(box)
	testing.expect(t, ok1)
	testing.expect_value(t, a1.stream_id, SID_A)
	testing.expect_value(t, string(a1.payload), "A1")
	delete(a1.payload)

	b1, ok2 := outbox_take_next(box)
	testing.expect(t, ok2)
	testing.expect_value(t, b1.stream_id, SID_B)
	testing.expect_value(t, string(b1.payload), "B1")
	delete(b1.payload)

	a2, ok3 := outbox_take_next(box)
	testing.expect(t, ok3)
	testing.expect_value(t, a2.stream_id, SID_A)
	testing.expect_value(t, string(a2.payload), "A2")
	delete(a2.payload)

	b2, ok4 := outbox_take_next(box)
	testing.expect(t, ok4)
	testing.expect_value(t, b2.stream_id, SID_B)
	testing.expect_value(t, string(b2.payload), "B2")
	delete(b2.payload)

	_, ok5 := outbox_take_next(box)
	testing.expect(t, !ok5)
	testing.expect_value(t, box.total_bytes, 0)
}

@(test)
test_outbox_close_frees_remaining_payloads :: proc(t: ^testing.T) {
	server: Server
	box := make_test_outbox(&server, 64, 64)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{1, 2, 3}), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_B, []u8{4, 5}), OutboxEnqueueError.None)
	testing.expect_value(t, box.total_bytes, 5)
	outbox_close(box)
	outbox_clear_queues(box)
	testing.expect_value(t, box.total_bytes, 0)
	testing.expect_value(t, len(box.queues), 0)
	outbox_release(box)
}

@(test)
test_outbox_global_limit_rejects_data :: proc(t: ^testing.T) {
	server: Server
	box := make_test_outbox(&server, 64, 64)
	defer outbox_release(box)
	server.max_buffered_bytes = 4
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{1, 2, 3, 4}), OutboxEnqueueError.None)
	testing.expect_value(t, outbox_enqueue(box, .Data, SID_B, []u8{5}), OutboxEnqueueError.GlobalLimit)
	testing.expect_value(t, box.total_bytes, 4)
}

when ODIN_TEST {
	OutboxWaitScript :: struct {
		now:       time.Tick,
		step:      time.Duration,
		drain_at:  time.Tick,
		remaining: int,
	}

	outbox_wait_script_clock :: proc(box: ^ConnOutbox, starting: bool, data: rawptr) -> time.Tick {
		script := (^OutboxWaitScript)(data)
		if starting {
			return script.now
		}
		script.now = time.tick_add(script.now, script.step)
		if script.remaining > 0 && time.tick_diff(script.drain_at, script.now) >= 0 {
			f, ok := outbox_take_next_locked(box)
			if ok {
				delete(f.payload, box.allocator)
				script.remaining -= 1
			}
		}
		return script.now
	}

	check_outbox_wait :: proc(
		t: ^testing.T, script: ^OutboxWaitScript, needed: int, timeout: time.Duration,
		expected: OutboxWaitResult, elapsed: time.Duration, source: ^ConnHandler = nil,
	) {
		testing.set_fail_timeout(t, 5 * time.Second)
		server: Server
		box := make_test_outbox(&server, 4, 64)
		defer outbox_release(box)
		box.test_wait_clock = outbox_wait_script_clock
		box.test_wait_data = script
		for i in 0 ..< 4 {
			testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{u8(i)}), OutboxEnqueueError.None)
		}
		start := script.now
		testing.expect_value(t, outbox_wait_stream_space(box, SID_A, needed, timeout, source), expected)
		testing.expect_value(t, time.tick_diff(start, script.now), elapsed)
		testing.expect_value(t, script.remaining, 0)
	}

	@(test)
	test_outbox_wait_stream_space_survives_slow_steady_drain :: proc(t: ^testing.T) {
		// The pending frame needs the whole queue to drain. Each partial drain
		// renews the wait, even after the original no-progress budget expires.
		script := OutboxWaitScript{step = 150 * time.Millisecond, remaining = 4}
		check_outbox_wait(t, &script, 4, 300 * time.Millisecond, .Ready, 4 * script.step)
	}

	@(test)
	test_outbox_wait_stream_space_gives_up_without_progress :: proc(t: ^testing.T) {
		script := OutboxWaitScript{step = 150 * time.Millisecond}
		check_outbox_wait(t, &script, 1, 300 * time.Millisecond, .Stalled, 300 * time.Millisecond)
	}

	@(test)
	test_outbox_probes_between_partial_drains :: proc(t: ^testing.T) {
		socket := trans.Connection{closed = true}
		source := ConnHandler{conn = &socket, role = .Caller}
		testing.expect_value(t, proto.decoder_init(&source.decoder), proto.ProtocolError.None)
		defer proto.decoder_destroy(&source.decoder)
		// The first probe merges this byte even though the test socket
		// cannot supply additional bytes. Each drain frees only one
		// byte, so the same four-byte frame remains blocked until t=4s.
		source.caller_input.used = 1
		script := OutboxWaitScript{step = time.Second, remaining = 4}
		check_outbox_wait(t, &script, 4, DEFAULT_STREAM_STALL_TIMEOUT, .Ready, 4 * script.step, &source)
		testing.expect_value(t, source.caller_input.used, 0)
		testing.expect_value(t, len(source.decoder.buf), 1)
	}

	@(test)
	test_outbox_caller_overflow_keeps_deadline_across_partial_drain :: proc(t: ^testing.T) {
		// Seed the exact full-decoder boundary produced by a sustained upload.
		// No socket I/O is needed because both parser buffers are already full.
		conn := trans.Connection{closed = true}
		source := ConnHandler{conn = &conn, state = .Authenticated, role = .Caller}
		testing.expect_value(t, proto.decoder_init(&source.decoder), proto.ProtocolError.None)
		defer proto.decoder_destroy(&source.decoder)
		frame, err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_A}, []u8{1, 2, 3, 4})
		defer delete(frame)
		if !testing.expect_value(t, err, proto.ProtocolError.None) {
			return
		}
		for cap(source.decoder.buf) - len(source.decoder.buf) >= len(frame) {
			if !testing.expect_value(t, proto.decoder_push(&source.decoder, frame), proto.ProtocolError.None) {
				return
			}
		}
		partial := cap(source.decoder.buf) - len(source.decoder.buf)
		testing.expect_value(t, proto.decoder_push(&source.decoder, frame[:partial]), proto.ProtocolError.None)
		tail := &source.caller_input
		for &b, i in tail.tail {
			b = frame[(partial + i) % len(frame)]
		}
		tail.used = len(tail.tail)
		if !testing.expect(t, caller_input_overflow(&source, SID_A), "sustained upload armed the overflow check") {
			return
		}

		// The periodic Pings protect receive liveness, so use the caller's
		// send watchdog. Allow one existing heartbeat interval to resume I/O.
		expected_wait := trans.CALLER_SEND_STALL_TIMEOUT - BACKPRESSURE_PING_INTERVAL
		stalled := OutboxWaitScript{step = time.Second}
		check_outbox_wait(t, &stalled, 4, DEFAULT_STREAM_STALL_TIMEOUT, .CallerOverflow, expected_wait, &source)

		// Free one byte just before the deadline. The same four-byte DATA
		// frame still cannot fit and the caller's parser is still full.
		partial_drain := OutboxWaitScript{
			step = time.Second,
			drain_at = time.tick_add({}, expected_wait - BACKPRESSURE_PING_INTERVAL),
			remaining = 1,
		}
		check_outbox_wait(t, &partial_drain, 4, DEFAULT_STREAM_STALL_TIMEOUT, .CallerOverflow, expected_wait, &source)
		testing.expect(t, caller_input_overflow(&source, SID_A), "the partial drain left the caller parser full")

		// Three consecutive partial drains still leave the four-byte
		// frame waiting. Even the dequeue at the deadline cannot defer RESET.
		repeated_drains := OutboxWaitScript{
			step = time.Second,
			drain_at = time.tick_add({}, expected_wait - BACKPRESSURE_PING_INTERVAL),
			remaining = 3,
		}
		check_outbox_wait(t, &repeated_drains, 4, DEFAULT_STREAM_STALL_TIMEOUT, .CallerOverflow, expected_wait, &source)
		testing.expect(t, caller_input_overflow(&source, SID_A), "repeated dequeues still left the caller parser full")

		// With the same drains, a three-byte frame fits at the deadline
		// and the reader resumes even though read-ahead is still full.
		enough := OutboxWaitScript{
			step = time.Second,
			drain_at = repeated_drains.drain_at,
			remaining = 3,
		}
		check_outbox_wait(t, &enough, 3, DEFAULT_STREAM_STALL_TIMEOUT, .Ready, expected_wait, &source)
	}

	@(test)
	test_outbox_caller_overflow_renews_budget_on_late_read :: proc(t: ^testing.T) {
		conn := trans.Connection{closed = true}
		source := ConnHandler{conn = &conn, role = .Caller}
		testing.expect_value(t, proto.decoder_init(&source.decoder), proto.ProtocolError.None)
		defer proto.decoder_destroy(&source.decoder)
		payload := make([]u8, int(proto.MAX_FRAME_PAYLOAD))
		defer delete(payload)
		data, err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_A}, payload)
		defer delete(data)
		testing.expect_value(t, err, proto.ProtocolError.None)
		testing.expect_value(t, proto.decoder_push(&source.decoder, data), proto.ProtocolError.None)
		copy(source.caller_input.tail[:], data)
		source.caller_input.used = len(source.caller_input.tail) - 1
		testing.expect(t, !caller_input_overflow(&source, SID_A), "read-ahead has space until the late burst")

		server: Server
		box := make_test_outbox(&server, 1, 64)
		defer outbox_release(box)
		testing.expect_value(t, outbox_enqueue(box, .Data, SID_A, []u8{'a'}), OutboxEnqueueError.None)
		script := OutboxWaitScript{step = time.Second}
		box.test_wait_clock = outbox_wait_script_clock
		box.test_wait_data = &script
		box.test_probe = proc(h: ^ConnHandler, data: rawptr) -> (bool, int) {
			clock := (^OutboxWaitScript)(data)
			if time.tick_diff({}, clock.now) < 9 * time.Second {
				return true, 0
			}
			if h.caller_input.used == len(h.caller_input.tail) {
				return false, 0
			}
			h.caller_input.used += 1
			return true, 1
		}
		testing.expect_value(t, outbox_wait_stream_space(box, SID_A, 1, DEFAULT_STREAM_STALL_TIMEOUT, &source), OutboxWaitResult.CallerOverflow)
		testing.expect_value(t, time.tick_diff({}, script.now), 9 * time.Second + CALLER_OVERFLOW_WAIT)
	}
}

@(test)
test_caller_decoder_recovers_max_data_across_tail :: proc(t: ^testing.T) {
	server := Server{allocator = context.allocator}
	h := ConnHandler{server = &server}
	testing.expect_value(t, proto.decoder_init(&h.decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&h.decoder)
	half, half_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .HalfClose, stream_id = SID_A}, nil)
	defer delete(half)
	testing.expect_value(t, half_err, proto.ProtocolError.None)
	payload := make([]u8, int(proto.MAX_FRAME_PAYLOAD))
	defer delete(payload)
	payload[0], payload[len(payload) - 1] = 'a', 'z'
	data, data_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_B}, payload)
	defer delete(data)
	testing.expect_value(t, data_err, proto.ProtocolError.None)
	pong, pong_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Pong}, []u8{0, 0, 0, 0, 0, 0, 0, 7})
	defer delete(pong)
	testing.expect_value(t, pong_err, proto.ProtocolError.None)

	front := len(data) - len(half)
	testing.expect_value(t, proto.decoder_push(&h.decoder, half), proto.ProtocolError.None)
	testing.expect_value(t, proto.decoder_push(&h.decoder, data[:front]), proto.ProtocolError.None)
	tail := &h.caller_input
	tail.used = copy(tail.tail[:], data[front:])
	tail.used += copy(tail.tail[tail.used:], pong)

	first, terr, perr := conn_read_frame(&h)
	defer proto.frame_destroy(&first)
	testing.expect_value(t, terr, trans.TransportError.None)
	testing.expect_value(t, perr, proto.ProtocolError.None)
	testing.expect_value(t, first.header.opcode, proto.Opcode.HalfClose)
	second, data_terr, data_perr := conn_read_frame(&h)
	defer proto.frame_destroy(&second)
	testing.expect_value(t, data_terr, trans.TransportError.None)
	testing.expect_value(t, data_perr, proto.ProtocolError.None)
	testing.expect_value(t, second.header.stream_id, SID_B)
	testing.expect(t, bytes.equal(second.payload, payload), "maximum DATA survived partial tail merge")

	tail.used += copy(tail.tail[tail.used:], pong[tail.used:])
	last, pong_terr, pong_perr := conn_read_frame(&h)
	defer proto.frame_destroy(&last)
	testing.expect_value(t, pong_terr, trans.TransportError.None)
	testing.expect_value(t, pong_perr, proto.ProtocolError.None)
	testing.expect(t, last.header.opcode == .Pong && bytes.equal(last.payload, pong[proto.HEADER_SIZE:]),
		"bytes left in the tail decoded as the next frame")
}

@(test)
test_caller_overflow_scans_past_sibling_data :: proc(t: ^testing.T) {
	h: ConnHandler
	testing.expect_value(t, proto.decoder_init(&h.decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&h.decoder)
	payload := make([]u8, int(proto.MAX_FRAME_PAYLOAD) - proto.HEADER_SIZE)
	defer delete(payload)
	front, front_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_A}, payload)
	defer delete(front)
	testing.expect_value(t, front_err, proto.ProtocolError.None)
	sibling, sibling_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_B}, []u8{'s'})
	defer delete(sibling)
	testing.expect_value(t, sibling_err, proto.ProtocolError.None)
	next, next_err := proto.encode_header({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_A, length = 1})
	testing.expect_value(t, next_err, proto.ProtocolError.None)
	testing.expect_value(t, proto.decoder_push(&h.decoder, front), proto.ProtocolError.None)
	testing.expect_value(t, proto.decoder_push(&h.decoder, sibling[:proto.HEADER_SIZE]), proto.ProtocolError.None)
	tail := &h.caller_input
	tail.used = copy(tail.tail[:], sibling[proto.HEADER_SIZE:])
	testing.expect(t, !caller_input_overflow(&h, SID_A), "the parser still has room")
	tail.used += copy(tail.tail[tail.used:], next[:])
	testing.expect(t, !caller_input_overflow(&h, SID_A), "another DATA header alone does not exhaust the parser")
	tail.used = len(tail.tail)
	testing.expect(t, caller_input_overflow(&h, SID_A), "a complete sibling frame does not hide the next stalled-stream header")

	// The first sibling frame across the limit is too large to finish
	// reading. DATA for the waited stream is already visible before it.
	large, large_err := proto.encode_header({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_B, length = proto.MAX_FRAME_PAYLOAD})
	testing.expect_value(t, large_err, proto.ProtocolError.None)
	copy(h.decoder.buf[len(front):], large[:])
	testing.expect(t, caller_input_overflow(&h, SID_A), "an incomplete sibling frame cannot hide buffered stalled-stream DATA")

	// A final DATA byte can cross the capacity with the stream's
	// HALF_CLOSE immediately behind it. The parser still has all the
	// evidence of completion, despite holding more than one decoder.
	last_data, last_data_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_A}, []u8{'x'})
	defer delete(last_data)
	testing.expect_value(t, last_data_err, proto.ProtocolError.None)
	half, half_err := proto.encode_header({version = proto.PROTOCOL_MAJOR, opcode = .HalfClose, stream_id = SID_A})
	testing.expect_value(t, half_err, proto.ProtocolError.None)
	copy(h.decoder.buf[len(front):], last_data)
	tail.used = copy(tail.tail[:], last_data[proto.HEADER_SIZE:])
	tail.used += copy(tail.tail[tail.used:], half[:])
	remaining := tail.tail[tail.used:]
	control, control_err := proto.encode_header({version = proto.PROTOCOL_MAJOR, opcode = .Ping, length = 8})
	testing.expect_value(t, control_err, proto.ProtocolError.None)
	copy(remaining, control[:])
	tail.used = len(tail.tail)
	testing.expect(t, !caller_input_overflow(&h, SID_A), "a split control header does not override the completed upload")
	copy(remaining, sibling[:])
	testing.expect(t, caller_input_overflow(&h, SID_A), "a split sibling DATA header keeps the completed upload from masking backpressure")

	// A larger final DATA frame leaves only the next version byte.
	end_size := len(tail.tail) - proto.HEADER_SIZE - 1
	end_data, end_err := proto.encode_header({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_A, length = u32(end_size)})
	testing.expect_value(t, end_err, proto.ProtocolError.None)
	copy(h.decoder.buf[len(front):], end_data[:])
	copy(tail.tail[end_size:], half[:])
	tail.tail[len(tail.tail) - 1] = proto.PROTOCOL_MAJOR
	testing.expect(t, caller_input_overflow(&h, SID_A), "a full parser with an ambiguous header prefix protects the session")
}

@(test)
test_caller_read_ahead_answers_boundary_ping :: proc(t: ^testing.T) {
	server: Server
	box := make_test_outbox(&server, 4, 64)
	defer outbox_release(box)
	h := ConnHandler{server = &server, outbox = box, state = .Authenticated, role = .Caller}
	testing.expect_value(t, proto.decoder_init(&h.decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&h.decoder)
	payload := make([]u8, int(proto.MAX_FRAME_PAYLOAD))
	defer delete(payload)
	data, data_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_A}, payload)
	defer delete(data)
	testing.expect_value(t, data_err, proto.ProtocolError.None)
	testing.expect_value(t, proto.decoder_push(&h.decoder, data), proto.ProtocolError.None)
	nonce := []u8{0, 0, 0, 0, 0, 0, 0, 9}
	ping, ping_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Ping}, nonce)
	defer delete(ping)
	testing.expect_value(t, ping_err, proto.ProtocolError.None)
	h.caller_input.used = copy(h.caller_input.tail[:], ping)
	prior := []u8{0, 0, 0, 0, 0, 0, 0, 7}
	testing.expect_value(t, outbox_enqueue(box, .Pong, proto.CONNECTION_STREAM_ID, prior), OutboxEnqueueError.None)
	caller_input_take_heartbeats(&h)
	testing.expect(t, h.caller_input.deferred_ping, "one outstanding reply leaves the next Ping buffered")
	previous, previous_ok := outbox_take_next(box)
	defer delete(previous.payload)
	testing.expect(t, previous_ok && bytes.equal(previous.payload, prior))
	caller_input_take_heartbeats(&h)
	testing.expect(t, !h.caller_input.deferred_ping)
	testing.expect_value(t, h.caller_input.used, 0)
	testing.expect(t, bytes.equal(h.decoder.buf[:], data), "buffered DATA was preserved")
	reply, ok := outbox_take_next(box)
	defer delete(reply.payload)
	testing.expect(t, ok && reply.opcode == .Pong && bytes.equal(reply.payload, nonce), "the Ping was answered asynchronously")
}

@(test)
test_caller_overflow_requires_exhausted_parser_and_data :: proc(t: ^testing.T) {
	h := ConnHandler{state = .Authenticated, role = .Caller}
	testing.expect_value(t, proto.decoder_init(&h.decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&h.decoder)
	payload := make([]u8, int(proto.MAX_FRAME_PAYLOAD))
	defer delete(payload)
	encoded, err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_B}, payload)
	defer delete(encoded)
	testing.expect_value(t, err, proto.ProtocolError.None)
	testing.expect_value(t, proto.decoder_push(&h.decoder, encoded), proto.ProtocolError.None)
	testing.expect(t, !caller_input_overflow(&h, SID_B), "a finite upload filled the decoder with tail space left")

	pong, pong_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Pong}, []u8{0, 0, 0, 0, 0, 0, 0, 1})
	defer delete(pong)
	testing.expect_value(t, pong_err, proto.ProtocolError.None)
	h.caller_input.used = copy(h.caller_input.tail[:], pong)
	caller_input_take_heartbeats(&h)
	testing.expect_value(t, h.caller_input.used, 0)
	testing.expect_value(t, len(h.decoder.buf), cap(h.decoder.buf))

	header, header_err := proto.encode_header({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_B, length = 1})
	testing.expect_value(t, header_err, proto.ProtocolError.None)
	h.caller_input.used = copy(h.caller_input.tail[:], header[:])
	testing.expect(t, !caller_input_overflow(&h, SID_B), "part of the tail is still available")
	// The frame needs the remaining tail plus at least one more byte.
	header, header_err = proto.encode_header({version = proto.PROTOCOL_MAJOR, opcode = .Data, stream_id = SID_B, length = u32(len(h.caller_input.tail))})
	testing.expect_value(t, header_err, proto.ProtocolError.None)
	copy(h.caller_input.tail[:], header[:])
	h.caller_input.used = len(h.caller_input.tail)
	testing.expect(t, caller_input_overflow(&h, SID_A), "sibling DATA can exhaust the session parser while SID_A holds its reader")
	testing.expect(t, caller_input_overflow(&h, SID_B), "a further DATA frame cannot fit")

	// Fill both buffers with control frames alone. They do not establish
	// that the caller is uploading more DATA.
	ping, ping_err := proto.encode_frame({version = proto.PROTOCOL_MAJOR, opcode = .Ping}, []u8{0, 0, 0, 0, 0, 0, 0, 2})
	defer delete(ping)
	testing.expect_value(t, ping_err, proto.ProtocolError.None)
	for &b, i in h.decoder.buf {
		b = ping[i % len(ping)]
	}
	for &b, i in h.caller_input.tail {
		b = ping[(len(h.decoder.buf) + i) % len(ping)]
	}
	testing.expect(t, !caller_input_overflow(&h, SID_A), "control traffic alone cannot cause early RESET")
}
