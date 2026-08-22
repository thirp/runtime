package transport

import proto "../protocol"

write_frame :: proc(
	conn: ^Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId = proto.CONNECTION_STREAM_ID,
	allocator := context.allocator,
) -> (terr: TransportError, perr: proto.ProtocolError) {
	header := proto.FrameHeader {
		version   = proto.PROTOCOL_MAJOR,
		opcode    = opcode,
		flags     = 0,
		stream_id = stream_id,
	}
	bytes, encode_err := proto.encode_frame(header, payload, allocator)
	if encode_err != .None {
		return .None, encode_err
	}
	defer delete(bytes, allocator)
	return connection_write(conn, bytes), .None
}

// read_frame returns a complete frame. The caller must proto.frame_destroy the
// result. Timeout and Closed are transport errors; decoder failures are protocol errors.
read_frame :: proc(
	conn: ^Connection,
	decoder: ^proto.FrameDecoder,
	allocator := context.allocator,
) -> (frame: proto.Frame, terr: TransportError, perr: proto.ProtocolError) {
	buf: [READ_BUF_SIZE]u8
	for {
		next, ok, derr := proto.decoder_next(decoder, allocator)
		if derr != .None {
			return {}, .None, derr
		}
		if ok {
			return next, .None, .None
		}
		n, rerr := connection_read(conn, buf[:])
		if rerr != .None {
			return {}, rerr, .None
		}
		push_err := proto.decoder_push(decoder, buf[:n])
		if push_err != .None {
			return {}, .None, push_err
		}
	}
}
