package protocol

import "core:slice"
import "core:testing"

@(test)
test_encode_frame_round_trip_ping :: proc(t: ^testing.T) {
	payload, perr := encode_ping(Ping{nonce = 0x1122334455667788})
	testing.expect_value(t, perr, ProtocolError.None)
	defer delete(payload)

	bytes := encode_test_frame(t, .Ping, CONNECTION_STREAM_ID, payload)
	defer delete(bytes)

	testing.expect_value(t, len(bytes), HEADER_SIZE + len(payload))
	header, herr := decode_header(bytes)
	testing.expect_value(t, herr, ProtocolError.None)
	testing.expect_value(t, header.opcode, Opcode.Ping)
	testing.expect_value(t, header.length, u32(len(payload)))
	testing.expect_value(t, header.stream_id, CONNECTION_STREAM_ID)
	testing.expect(t, slice.equal(bytes[HEADER_SIZE:], payload))
}

@(test)
test_encode_frame_sets_payload_length :: proc(t: ^testing.T) {
	payload := []u8{1, 2, 3, 4}
	bytes := encode_test_frame(t, .Data, make_stream_id(7), payload)
	defer delete(bytes)
	header, err := decode_header(bytes)
	testing.expect_value(t, err, ProtocolError.None)
	testing.expect_value(t, header.length, u32(4))
	testing.expect(t, slice.equal(bytes[HEADER_SIZE:], payload))
}

@(test)
test_encode_frame_rejects_oversized_payload :: proc(t: ^testing.T) {
	payload := make([]u8, int(MAX_FRAME_PAYLOAD) + 1)
	defer delete(payload)
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Data,
		stream_id = make_stream_id(1),
	}
	_, err := encode_frame(header, payload)
	testing.expect_value(t, err, ProtocolError.FrameTooLarge)
}

@(test)
test_encode_frame_rejects_invalid_stream_id :: proc(t: ^testing.T) {
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Hello,
		stream_id = make_stream_id(9),
	}
	_, err := encode_frame(header, nil)
	testing.expect_value(t, err, ProtocolError.InvalidStreamId)
}
