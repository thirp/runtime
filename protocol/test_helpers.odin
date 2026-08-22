package protocol

import "core:testing"

must_service_id :: proc(t: ^testing.T, value: string, loc := #caller_location) -> ServiceId {
	id, err := make_service_id(value)
	testing.expect_value(t, err, ServiceIdError.None, loc)
	return id
}

expect_header_round_trip :: proc(t: ^testing.T, header: FrameHeader, loc := #caller_location) {
	encoded, err := encode_header(header)
	if !testing.expect_value(t, err, ProtocolError.None, loc) {
		return
	}
	decoded, derr := decode_header(encoded[:])
	if !testing.expect_value(t, derr, ProtocolError.None, loc) {
		return
	}
	testing.expect_value(t, decoded.version, header.version, loc)
	testing.expect_value(t, decoded.opcode, header.opcode, loc)
	testing.expect_value(t, decoded.flags, header.flags, loc)
	testing.expect_value(t, decoded.length, header.length, loc)
	testing.expect_value(t, decoded.stream_id, header.stream_id, loc)
}

encode_test_frame :: proc(
	t: ^testing.T,
	opcode: Opcode,
	stream_id: StreamId,
	payload: []u8,
	loc := #caller_location,
) -> []u8 {
	header := FrameHeader {
		version   = PROTOCOL_MAJOR,
		opcode    = opcode,
		flags     = 0,
		stream_id = stream_id,
	}
	bytes, err := encode_frame(header, payload)
	testing.expect_value(t, err, ProtocolError.None, loc)
	return bytes
}

push_all :: proc(t: ^testing.T, decoder: ^FrameDecoder, src: []u8, loc := #caller_location) {
	err := decoder_push(decoder, src)
	testing.expect_value(t, err, ProtocolError.None, loc)
}
