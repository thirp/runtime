package transport

import proto "../protocol"
import "core:testing"

@(test)
test_write_frame_read_frame_ping_round_trip :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	defer connection_destroy(client)

	server, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(server)

	payload, perr := proto.encode_ping(proto.Ping{nonce = 0x1122334455667788})
	testing.expect_value(t, perr, proto.ProtocolError.None)
	defer delete(payload)

	terr, werr := write_frame(client, .Ping, payload)
	testing.expect_value(t, terr, TransportError.None)
	testing.expect_value(t, werr, proto.ProtocolError.None)

	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&decoder)

	frame, rterr, rperr := read_frame(server, &decoder)
	testing.expect_value(t, rterr, TransportError.None)
	testing.expect_value(t, rperr, proto.ProtocolError.None)
	defer proto.frame_destroy(&frame)

	testing.expect_value(t, frame.header.opcode, proto.Opcode.Ping)
	testing.expect_value(t, frame.header.stream_id, proto.CONNECTION_STREAM_ID)
	got, gerr := proto.decode_ping(frame.payload)
	testing.expect_value(t, gerr, proto.ProtocolError.None)
	testing.expect_value(t, got.nonce, u64(0x1122334455667788))
}
