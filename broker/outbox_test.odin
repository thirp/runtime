package broker

import proto "../protocol"
import "core:testing"

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
