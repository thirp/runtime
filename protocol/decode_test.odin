package protocol

import "core:slice"
import "core:testing"

init_decoder :: proc(t: ^testing.T) -> FrameDecoder {
	decoder: FrameDecoder
	err := decoder_init(&decoder)
	testing.expect_value(t, err, ProtocolError.None)
	return decoder
}

@(test)
test_decoder_needs_more_on_partial_header :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	payload, _ := encode_ping(Ping{nonce = 1})
	defer delete(payload)
	bytes := encode_test_frame(t, .Ping, CONNECTION_STREAM_ID, payload)
	defer delete(bytes)

	push_all(t, &decoder, bytes[:8])
	_, ok, err := decoder_next(&decoder)
	testing.expect_value(t, err, ProtocolError.None)
	testing.expect(t, !ok)
}

@(test)
test_decoder_needs_more_on_partial_payload :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	payload, _ := encode_ping(Ping{nonce = 1})
	defer delete(payload)
	bytes := encode_test_frame(t, .Ping, CONNECTION_STREAM_ID, payload)
	defer delete(bytes)

	push_all(t, &decoder, bytes[:HEADER_SIZE+2])
	_, ok, err := decoder_next(&decoder)
	testing.expect_value(t, err, ProtocolError.None)
	testing.expect(t, !ok)

	push_all(t, &decoder, bytes[HEADER_SIZE+2:])
	frame, ok2, err2 := decoder_next(&decoder)
	testing.expect_value(t, err2, ProtocolError.None)
	testing.expect(t, ok2)
	defer frame_destroy(&frame)
	testing.expect_value(t, frame.header.opcode, Opcode.Ping)
	testing.expect(t, slice.equal(frame.payload, payload))
}

@(test)
test_decoder_extracts_multiple_frames_in_one_push :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	p1, _ := encode_ping(Ping{nonce = 11})
	defer delete(p1)
	p2, _ := encode_pong(Pong{nonce = 22})
	defer delete(p2)
	b1 := encode_test_frame(t, .Ping, CONNECTION_STREAM_ID, p1)
	defer delete(b1)
	b2 := encode_test_frame(t, .Pong, CONNECTION_STREAM_ID, p2)
	defer delete(b2)

	joined := make([]u8, len(b1) + len(b2))
	defer delete(joined)
	copy(joined, b1)
	copy(joined[len(b1):], b2)
	push_all(t, &decoder, joined)

	f1, ok1, e1 := decoder_next(&decoder)
	testing.expect_value(t, e1, ProtocolError.None)
	testing.expect(t, ok1)
	defer frame_destroy(&f1)
	testing.expect_value(t, f1.header.opcode, Opcode.Ping)

	f2, ok2, e2 := decoder_next(&decoder)
	testing.expect_value(t, e2, ProtocolError.None)
	testing.expect(t, ok2)
	defer frame_destroy(&f2)
	testing.expect_value(t, f2.header.opcode, Opcode.Pong)

	_, ok3, e3 := decoder_next(&decoder)
	testing.expect_value(t, e3, ProtocolError.None)
	testing.expect(t, !ok3)
}

@(test)
test_decoder_rejects_invalid_opcode :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	bytes := encode_test_frame(t, .Ping, CONNECTION_STREAM_ID, nil)
	defer delete(bytes)
	bytes[1] = 99
	push_all(t, &decoder, bytes)
	_, ok, err := decoder_next(&decoder)
	testing.expect(t, !ok)
	testing.expect_value(t, err, ProtocolError.InvalidOpcode)
	_, _, err2 := decoder_next(&decoder)
	testing.expect_value(t, err2, ProtocolError.InvalidOpcode)
}

@(test)
test_decoder_rejects_invalid_version :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	bytes := encode_test_frame(t, .Ping, CONNECTION_STREAM_ID, nil)
	defer delete(bytes)
	bytes[0] = 0
	push_all(t, &decoder, bytes)
	_, _, err := decoder_next(&decoder)
	testing.expect_value(t, err, ProtocolError.InvalidVersion)
}

@(test)
test_decoder_rejects_oversized_length_without_waiting :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Data,
		length    = MAX_FRAME_PAYLOAD,
		stream_id = make_stream_id(1),
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	encoded[4] = 0
	encoded[5] = 1
	encoded[6] = 0
	encoded[7] = 1
	push_all(t, &decoder, encoded[:])
	_, ok, nerr := decoder_next(&decoder)
	testing.expect(t, !ok)
	testing.expect_value(t, nerr, ProtocolError.FrameTooLarge)
}

@(test)
test_decoder_rejects_nonzero_flags :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	bytes := encode_test_frame(t, .Ping, CONNECTION_STREAM_ID, nil)
	defer delete(bytes)
	bytes[3] = 1
	push_all(t, &decoder, bytes)
	_, _, err := decoder_next(&decoder)
	testing.expect_value(t, err, ProtocolError.InvalidFlags)
}

@(test)
test_decoder_malformed_corpus_does_not_panic :: proc(t: ^testing.T) {
	corpus := [][]u8 {
		{},
		{1},
		{1, 20},
		{1, 20, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0},
		{0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 20, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 16, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 16, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9},
		{1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
	}
	for sample in corpus {
		decoder := init_decoder(t)
		_ = decoder_push(&decoder, sample)
		_, _, _ = decoder_next(&decoder)
		decoder_destroy(&decoder)
	}
}

@(test)
test_decoder_rejects_buffer_full :: proc(t: ^testing.T) {
	decoder := init_decoder(t)
	defer decoder_destroy(&decoder)

	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Data,
		length    = MAX_FRAME_PAYLOAD,
		stream_id = make_stream_id(1),
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	push_all(t, &decoder, encoded[:])

	almost := make([]u8, int(MAX_FRAME_PAYLOAD) - 1)
	defer delete(almost)
	push_all(t, &decoder, almost)

	overflow := [2]u8{1, 2}
	ferr := decoder_push(&decoder, overflow[:])
	testing.expect_value(t, ferr, ProtocolError.BufferFull)
}
