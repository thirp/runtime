package protocol

import "core:encoding/endian"

check_header :: proc(header: FrameHeader) -> ProtocolError {
	if header.version != PROTOCOL_MAJOR {
		return .InvalidVersion
	}
	if header.flags != 0 {
		return .InvalidFlags
	}
	if header.length > MAX_FRAME_PAYLOAD {
		return .FrameTooLarge
	}
	if opcode_requires_zero_stream(header.opcode) {
		if header.stream_id != CONNECTION_STREAM_ID {
			return .InvalidStreamId
		}
	} else if opcode_requires_nonzero_stream(header.opcode) {
		if header.stream_id == CONNECTION_STREAM_ID {
			return .InvalidStreamId
		}
	}
	return .None
}

encode_header :: proc(header: FrameHeader) -> (out: [HEADER_SIZE]u8, err: ProtocolError) {
	err = check_header(header)
	if err != .None {
		return
	}
	out[0] = header.version
	out[1] = u8(header.opcode)
	endian.unchecked_put_u16be(out[2:], header.flags)
	endian.unchecked_put_u32be(out[4:], header.length)
	endian.unchecked_put_u64be(out[8:], u64(header.stream_id))
	return out, .None
}

decode_header :: proc(src: []u8) -> (header: FrameHeader, err: ProtocolError) {
	if len(src) < HEADER_SIZE {
		return {}, .Truncated
	}
	header.version = src[0]
	opcode, ok := opcode_from_u8(src[1])
	if !ok {
		return {}, .InvalidOpcode
	}
	header.opcode = opcode
	header.flags = endian.unchecked_get_u16be(src[2:])
	header.length = endian.unchecked_get_u32be(src[4:])
	header.stream_id = StreamId(endian.unchecked_get_u64be(src[8:]))
	return header, check_header(header)
}

frame_destroy :: proc(frame: ^Frame, allocator := context.allocator) {
	if frame == nil {
		return
	}
	delete(frame.payload, allocator)
	frame.payload = nil
}
