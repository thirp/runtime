package protocol

import "core:testing"

@(test)
test_header_size_is_16 :: proc(t: ^testing.T) {
	testing.expect_value(t, HEADER_SIZE, 16)
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Ping,
		flags     = 0,
		length    = 8,
		stream_id = CONNECTION_STREAM_ID,
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	testing.expect_value(t, len(encoded), 16)
}

@(test)
test_header_round_trip_connection_frame :: proc(t: ^testing.T) {
	expect_header_round_trip(t, FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Hello,
		flags     = 0,
		length    = 13,
		stream_id = CONNECTION_STREAM_ID,
	})
}

@(test)
test_header_round_trip_stream_frame :: proc(t: ^testing.T) {
	expect_header_round_trip(t, FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Data,
		flags     = 0,
		length    = 256,
		stream_id = make_stream_id(42),
	})
}

@(test)
test_header_length_is_big_endian :: proc(t: ^testing.T) {
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Data,
		flags     = 0,
		length    = 256,
		stream_id = make_stream_id(1),
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	testing.expect_value(t, encoded[4], u8(0))
	testing.expect_value(t, encoded[5], u8(0))
	testing.expect_value(t, encoded[6], u8(1))
	testing.expect_value(t, encoded[7], u8(0))
}

@(test)
test_header_stream_id_is_big_endian :: proc(t: ^testing.T) {
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Open,
		flags     = 0,
		length    = 0,
		stream_id = make_stream_id(0x0102030405060708),
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	testing.expect_value(t, encoded[8], u8(0x01))
	testing.expect_value(t, encoded[9], u8(0x02))
	testing.expect_value(t, encoded[10], u8(0x03))
	testing.expect_value(t, encoded[11], u8(0x04))
	testing.expect_value(t, encoded[12], u8(0x05))
	testing.expect_value(t, encoded[13], u8(0x06))
	testing.expect_value(t, encoded[14], u8(0x07))
	testing.expect_value(t, encoded[15], u8(0x08))
}

@(test)
test_decode_header_rejects_truncated :: proc(t: ^testing.T) {
	buf: [15]u8
	_, err := decode_header(buf[:])
	testing.expect_value(t, err, ProtocolError.Truncated)
}

@(test)
test_decode_header_rejects_invalid_version :: proc(t: ^testing.T) {
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Ping,
		stream_id = CONNECTION_STREAM_ID,
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	encoded[0] = 0
	_, err = decode_header(encoded[:])
	testing.expect_value(t, err, ProtocolError.InvalidVersion)
	encoded[0] = 2
	_, err = decode_header(encoded[:])
	testing.expect_value(t, err, ProtocolError.InvalidVersion)
}

@(test)
test_decode_header_rejects_invalid_opcode :: proc(t: ^testing.T) {
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Ping,
		stream_id = CONNECTION_STREAM_ID,
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	encoded[1] = 0
	_, err = decode_header(encoded[:])
	testing.expect_value(t, err, ProtocolError.InvalidOpcode)
	encoded[1] = 99
	_, err = decode_header(encoded[:])
	testing.expect_value(t, err, ProtocolError.InvalidOpcode)
}

@(test)
test_decode_header_rejects_nonzero_flags :: proc(t: ^testing.T) {
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Ping,
		stream_id = CONNECTION_STREAM_ID,
	}
	encoded, err := encode_header(header)
	testing.expect_value(t, err, ProtocolError.None)
	encoded[3] = 1
	_, err = decode_header(encoded[:])
	testing.expect_value(t, err, ProtocolError.InvalidFlags)
}

@(test)
test_decode_header_rejects_oversized_length :: proc(t: ^testing.T) {
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
	_, err = decode_header(encoded[:])
	testing.expect_value(t, err, ProtocolError.FrameTooLarge)
}

@(test)
test_encode_header_rejects_connection_opcode_with_stream :: proc(t: ^testing.T) {
	_, err := encode_header(FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Ping,
		stream_id = make_stream_id(1),
	})
	testing.expect_value(t, err, ProtocolError.InvalidStreamId)
}

@(test)
test_encode_header_rejects_stream_opcode_without_stream :: proc(t: ^testing.T) {
	_, err := encode_header(FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = .Data,
		stream_id = CONNECTION_STREAM_ID,
	})
	testing.expect_value(t, err, ProtocolError.InvalidStreamId)
}
