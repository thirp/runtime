package broker

import proto "../protocol"
import trans "../transport"

// The broker sends heartbeats throughout the wait, so the caller's send
// watchdog owns this budget. Leave one heartbeat interval to resume I/O.
CALLER_OVERFLOW_WAIT :: trans.CALLER_SEND_STALL_TIMEOUT - BACKPRESSURE_PING_INTERVAL

// Read-ahead uses the connection's existing decoder. A header and Pong of
// parser storage let us inspect the boundary even when it is mid-frame.
// This is parser state; DATA still enters the destination through its outbox.
CallerInput :: struct {
	tail:          [proto.HEADER_SIZE + size_of(proto.Pong)]u8,
	used:          int,
	deferred_ping: bool,
}

conn_read_frame :: proc(h: ^ConnHandler) -> (proto.Frame, trans.TransportError, proto.ProtocolError) {
	if h.caller_input.used != 0 && !caller_input_merge(h) {
		// A full decoder has either a complete frame or a header error.
		frame, ok, err := proto.decoder_next(&h.decoder, h.server.allocator)
		if !ok && err == .None {
			err = proto.decoder_fail(&h.decoder, .BufferFull)
		}
		return frame, .None, err
	}
	return trans.read_frame(h.conn, &h.decoder, h.server.allocator)
}

caller_input_merge :: proc(h: ^ConnHandler) -> bool {
	input := &h.caller_input
	n := min(cap(h.decoder.buf) - len(h.decoder.buf), input.used)
	if proto.decoder_push(&h.decoder, input.tail[:n]) != .None {
		return false
	}
	copy(input.tail[:], input.tail[n:input.used])
	input.used -= n
	return input.used == 0
}

// The caller reader owns the decoder and is the only reader on the socket.
// Preserve input exactly as received so timeout recovery can replay it in order.
caller_input_probe :: proc(h: ^ConnHandler) -> (can_probe: bool, bytes_read: int) {
	if caller_input_merge(h) {
		space := cap(h.decoder.buf) - len(h.decoder.buf)
		if space > 0 {
			buf: [trans.READ_BUF_SIZE]u8
			n, err := trans.connection_read(h.conn, buf[:min(space, len(buf))])
			if proto.decoder_push(&h.decoder, buf[:n]) != .None {
				return false, n
			}
			if n > 0 {
				caller_input_take_heartbeats(h)
			}
			return err == .None || err == .Timeout, n
		}
	}
	input := &h.caller_input
	if input.used == len(input.tail) {
		return false, 0
	}
	n, err := trans.connection_read(h.conn, input.tail[input.used:])
	input.used += n
	if n > 0 {
		caller_input_take_heartbeats(h)
	}
	return err == .None || err == .Timeout, n
}

caller_input_copy :: proc(h: ^ConnHandler, dst: []u8, start: int) {
	if start < len(h.decoder.buf) {
		n := copy(dst, h.decoder.buf[start:])
		copy(dst[n:], h.caller_input.tail[:h.caller_input.used])
	} else {
		copy(dst, h.caller_input.tail[start - len(h.decoder.buf):h.caller_input.used])
	}
}

caller_input_header :: proc(h: ^ConnHandler, at: int) -> (proto.FrameHeader, bool) {
	encoded: [proto.HEADER_SIZE]u8
	caller_input_copy(h, encoded[:], at)
	header, err := proto.decode_header(encoded[:])
	return header, err == .None && header.length <= h.decoder.max_payload
}

// Heartbeats are independent of stream ordering. Consume them without making
// the caller reader wait on a socket write.
// Keep every other frame in wire order for the ordinary reader.
caller_input_take_heartbeats :: proc(h: ^ConnHandler) {
	h.caller_input.deferred_ping = false
	for at := 0; at + proto.HEADER_SIZE <= len(h.decoder.buf) + h.caller_input.used; {
		header, ok := caller_input_header(h, at)
		next := at + proto.HEADER_SIZE + int(header.length)
		if !ok || next > len(h.decoder.buf) + h.caller_input.used {
			return
		}
		if (header.opcode != .Pong && header.opcode != .Ping) || header.length != size_of(proto.Pong) {
			at = next
			continue
		}
		payload: [size_of(proto.Pong)]u8
		caller_input_copy(h, payload[:], at + proto.HEADER_SIZE)
		if header.opcode == .Ping {
			// The nonce has the same encoding in Ping and Pong. Leave
			// further Pings buffered while the writer has a reply pending.
			if outbox_queued(h.outbox, proto.CONNECTION_STREAM_ID) != 0 {
				h.caller_input.deferred_ping = true
				at = next
				continue
			}
			if outbox_enqueue(h.outbox, .Pong, proto.CONNECTION_STREAM_ID, payload[:]) != .None {
				at = next
				continue
			}
			conn_note_recv(h)
		} else {
			_ = conn_handle_frame(h, {header = header, payload = payload[:]})
		}
		limit := len(h.decoder.buf)
		if next <= limit {
			copy(h.decoder.buf[at:], h.decoder.buf[next:])
			resize(&h.decoder.buf, limit - (next - at))
		} else {
			resize(&h.decoder.buf, min(at, limit))
			start := max(at - limit, 0)
			removed := next - limit - start
			input := &h.caller_input
			copy(input.tail[start:], input.tail[start + removed:input.used])
			input.used -= removed
		}
		_ = caller_input_merge(h)
	}
}

// A decoder with room can still make progress. Once both buffers are full,
// further DATA puts the shared caller writer at risk even if the boundary
// cuts through a sibling's frame. When only the waited stream is uploading,
// a visible HALF_CLOSE tells us the caller has finished sending on it.
caller_input_overflow :: proc(h: ^ConnHandler, stream_id: proto.StreamId) -> bool {
	limit := len(h.decoder.buf)
	if limit != cap(h.decoder.buf) || h.caller_input.used != len(h.caller_input.tail) {
		return false
	}
	available := limit + h.caller_input.used
	waited_data, sibling_data, completed := false, false, false
	at := 0
	for at + proto.HEADER_SIZE <= available {
		header, ok := caller_input_header(h, at)
		if !ok {
			return false
		}
		next := at + proto.HEADER_SIZE + int(header.length)
		if header.stream_id == stream_id {
			if header.opcode == .HalfClose && header.length == 0 {
				completed = true
			}
			if header.opcode == .Data && header.length > 0 {
				waited_data = true
			}
		} else if header.opcode == .Data && header.length > 0 {
			sibling_data = true
		}
		at = next
	}
	if sibling_data || (waited_data && !completed) {
		return true
	}
	if at >= available {
		return false
	}
	// DATA is identifiable before its stream ID is complete. A lone
	// version byte after an upload is ambiguous, so protect the session.
	prefix := available - at
	encoded: [proto.HEADER_SIZE]u8
	encoded[proto.HEADER_SIZE - 1] = 1 // any valid suffix suffices for this check
	caller_input_copy(h, encoded[:prefix], at)
	if prefix == 1 {
		return (waited_data || completed) && encoded[0] == proto.PROTOCOL_MAJOR
	}
	header, err := proto.decode_header(encoded[:])
	return err == .None && header.opcode == .Data && header.length <= h.decoder.max_payload &&
		(prefix < 8 || header.length > 0)
}
