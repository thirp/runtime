package protocol

import "core:encoding/endian"
import "core:unicode/utf8"

encode_frame :: proc(
	header: FrameHeader,
	payload: []u8,
	allocator := context.allocator,
) -> ([]u8, ProtocolError) {
	if len(payload) > int(MAX_FRAME_PAYLOAD) {
		return nil, .FrameTooLarge
	}

	header := header
	header.version = PROTOCOL_MAJOR
	header.length = u32(len(payload))

	header_bytes, herr := encode_header(header)
	if herr != .None {
		return nil, herr
	}

	out, aerr := make([]u8, HEADER_SIZE + len(payload), allocator)
	if aerr != .None {
		return nil, .OutOfMemory
	}
	copy(out[:HEADER_SIZE], header_bytes[:])
	copy(out[HEADER_SIZE:], payload)
	return out, .None
}

append_bytes :: proc(buf: ^[dynamic]u8, src: []u8) -> ProtocolError {
	_, aerr := append(buf, ..src)
	if aerr != .None {
		return .OutOfMemory
	}
	return .None
}

append_u8 :: proc(buf: ^[dynamic]u8, v: u8) -> ProtocolError {
	b := [1]u8{v}
	return append_bytes(buf, b[:])
}

append_u16be :: proc(buf: ^[dynamic]u8, v: u16) -> ProtocolError {
	b: [2]u8
	endian.unchecked_put_u16be(b[:], v)
	return append_bytes(buf, b[:])
}

append_u64be :: proc(buf: ^[dynamic]u8, v: u64) -> ProtocolError {
	b: [8]u8
	endian.unchecked_put_u64be(b[:], v)
	return append_bytes(buf, b[:])
}

append_lp_bytes :: proc(buf: ^[dynamic]u8, src: []u8) -> ProtocolError {
	if len(src) > int(max(u16)) {
		return .InvalidPayload
	}
	append_u16be(buf, u16(len(src))) or_return
	return append_bytes(buf, src)
}

append_lp_string :: proc(buf: ^[dynamic]u8, s: string) -> ProtocolError {
	if !utf8.valid_string(s) {
		return .InvalidUtf8
	}
	if len(s) == 0 {
		return append_lp_bytes(buf, nil)
	}
	return append_lp_bytes(buf, ([^]u8)(raw_data(s))[:len(s)])
}

finish_payload :: proc(buf: ^[dynamic]u8) -> ([]u8, ProtocolError) {
	if len(buf) > int(MAX_FRAME_PAYLOAD) {
		return nil, .FrameTooLarge
	}
	return buf[:], .None
}
