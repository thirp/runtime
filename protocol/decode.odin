package protocol

import "core:bytes"
import "core:encoding/endian"
import "core:strings"
import "core:unicode/utf8"

PayloadReader :: struct {
	data:   []u8,
	offset: int,
}

reader_remaining :: proc(r: ^PayloadReader) -> int {
	if r.offset >= len(r.data) {
		return 0
	}
	return len(r.data) - r.offset
}

read_u8 :: proc(r: ^PayloadReader) -> (u8, ProtocolError) {
	if reader_remaining(r) < 1 {
		return 0, .Truncated
	}
	v := r.data[r.offset]
	r.offset += 1
	return v, .None
}

read_u16be :: proc(r: ^PayloadReader) -> (u16, ProtocolError) {
	if reader_remaining(r) < 2 {
		return 0, .Truncated
	}
	v := endian.unchecked_get_u16be(r.data[r.offset:])
	r.offset += 2
	return v, .None
}

read_u64be :: proc(r: ^PayloadReader) -> (u64, ProtocolError) {
	if reader_remaining(r) < 8 {
		return 0, .Truncated
	}
	v := endian.unchecked_get_u64be(r.data[r.offset:])
	r.offset += 8
	return v, .None
}

read_exact :: proc(r: ^PayloadReader, n: int) -> ([]u8, ProtocolError) {
	if n < 0 || reader_remaining(r) < n {
		return nil, .Truncated
	}
	slice := r.data[r.offset:][:n]
	r.offset += n
	return slice, .None
}

read_lp_bytes :: proc(r: ^PayloadReader, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	n_u16 := read_u16be(r) or_return
	raw := read_exact(r, int(n_u16)) or_return
	return bytes.clone(raw, allocator), .None
}

read_lp_string :: proc(r: ^PayloadReader, allocator := context.allocator) -> (out: string, err: ProtocolError) {
	n_u16 := read_u16be(r) or_return
	raw := read_exact(r, int(n_u16)) or_return
	s := string(raw)
	if !utf8.valid_string(s) {
		return "", .InvalidUtf8
	}
	cloned, aerr := strings.clone(s, allocator)
	if aerr != .None {
		return "", .OutOfMemory
	}
	return cloned, .None
}

require_empty_payload :: proc(payload: []u8) -> ProtocolError {
	if len(payload) != 0 {
		return .InvalidPayload
	}
	return .None
}

require_consumed :: proc(r: ^PayloadReader) -> ProtocolError {
	if reader_remaining(r) != 0 {
		return .InvalidPayload
	}
	return .None
}

decoder_init :: proc(decoder: ^FrameDecoder, allocator := context.allocator) -> ProtocolError {
	buf, aerr := make([dynamic]u8, 0, DECODER_BUFFER_CAP, allocator)
	if aerr != .None {
		return .OutOfMemory
	}
	decoder.buf = buf
	decoder.max_payload = MAX_FRAME_PAYLOAD
	decoder.failed = false
	decoder.fail_err = .None
	return .None
}

decoder_destroy :: proc(decoder: ^FrameDecoder) {
	if decoder == nil {
		return
	}
	delete(decoder.buf)
	decoder^ = {}
}

decoder_reset :: proc(decoder: ^FrameDecoder) {
	clear(&decoder.buf)
	decoder.failed = false
	decoder.fail_err = .None
}

decoder_fail :: proc(decoder: ^FrameDecoder, err: ProtocolError) -> ProtocolError {
	decoder.failed = true
	decoder.fail_err = err
	return err
}

decoder_push :: proc(decoder: ^FrameDecoder, src: []u8) -> ProtocolError {
	if decoder.failed {
		return decoder.fail_err
	}
	if len(src) == 0 {
		return .None
	}
	if len(decoder.buf) + len(src) > cap(decoder.buf) {
		return decoder_fail(decoder, .BufferFull)
	}
	_, aerr := append(&decoder.buf, ..src)
	if aerr != .None {
		return decoder_fail(decoder, .OutOfMemory)
	}
	return .None
}

// decoder_next extracts the next complete frame. The returned Frame.payload is
// owned by the caller (clone of the internal buffer) and must be freed with
// frame_destroy. ok=false with err=.None means more bytes are required.
decoder_next :: proc(
	decoder: ^FrameDecoder,
	allocator := context.allocator,
) -> (frame: Frame, ok: bool, err: ProtocolError) {
	if decoder.failed {
		return {}, false, decoder.fail_err
	}
	if len(decoder.buf) < HEADER_SIZE {
		return {}, false, .None
	}

	header, herr := decode_header(decoder.buf[:])
	if herr != .None {
		return {}, false, decoder_fail(decoder, herr)
	}
	if header.length > decoder.max_payload {
		return {}, false, decoder_fail(decoder, .FrameTooLarge)
	}

	need := HEADER_SIZE + int(header.length)
	if len(decoder.buf) < need {
		return {}, false, .None
	}

	payload_src := decoder.buf[HEADER_SIZE:need]
	payload := bytes.clone(payload_src, allocator)

	remaining := len(decoder.buf) - need
	if remaining > 0 {
		copy(decoder.buf[:], decoder.buf[need:])
	}
	resize(&decoder.buf, remaining)

	return Frame{header = header, payload = payload}, true, .None
}
