package protocol

import "core:slice"
import "core:testing"

@(test)
test_hello_payload_round_trip :: proc(t: ^testing.T) {
	src := Hello {
		major           = PROTOCOL_MAJOR,
		minor           = PROTOCOL_MINOR,
		role            = .Agent,
		capability_bits = 0,
		implementation  = "thirp/0.1.0",
	}
	bytes, err := encode_hello(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_hello(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(got.implementation)
	testing.expect_value(t, got.major, src.major)
	testing.expect_value(t, got.minor, src.minor)
	testing.expect_value(t, got.role, src.role)
	testing.expect_value(t, got.capability_bits, src.capability_bits)
	testing.expect_value(t, got.implementation, src.implementation)
}

@(test)
test_hello_ack_payload_round_trip :: proc(t: ^testing.T) {
	src := HelloAck {
		major           = PROTOCOL_MAJOR,
		minor           = PROTOCOL_MINOR,
		capability_bits = 0,
		implementation  = "thirp-broker/0.1.0",
	}
	bytes, err := encode_hello_ack(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_hello_ack(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(got.implementation)
	testing.expect_value(t, got.implementation, src.implementation)
}

@(test)
test_authenticate_payload_round_trip :: proc(t: ^testing.T) {
	src := Authenticate{token = []u8{0x00, 0xff, 0x7f}}
	bytes, err := encode_authenticate(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_authenticate(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(got.token)
	testing.expect(t, slice.equal(got.token, src.token))
}

@(test)
test_authenticate_ok_payload_round_trip :: proc(t: ^testing.T) {
	src := AuthenticateOk{principal_id = "host-a"}
	bytes, err := encode_authenticate_ok(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_authenticate_ok(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(got.principal_id)
	testing.expect_value(t, got.principal_id, src.principal_id)
}

@(test)
test_wire_failure_payload_round_trip :: proc(t: ^testing.T) {
	src := WireFailure {
		code        = wire_error_to_u16(.Unauthorized),
		diagnostic  = "denied",
	}
	bytes, err := encode_wire_failure(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_wire_failure(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(got.diagnostic)
	testing.expect_value(t, got.code, src.code)
	testing.expect_value(t, got.diagnostic, src.diagnostic)
}

@(test)
test_register_payload_round_trip :: proc(t: ^testing.T) {
	src := Register{service_id = must_service_id(t, "demo/echo")}
	bytes, err := encode_register(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_register(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(string(got.service_id))
	testing.expect_value(t, string(got.service_id), "demo/echo")
}

@(test)
test_decode_register_rejects_invalid_service_id :: proc(t: ^testing.T) {
	buf := make([dynamic]u8)
	defer delete(buf)
	testing.expect_value(t, append_lp_string(&buf, "bad service"), ProtocolError.None)
	_, err := decode_register(buf[:])
	testing.expect_value(t, err, ProtocolError.InvalidServiceId)
}

@(test)
test_decode_register_rejects_empty_service_id :: proc(t: ^testing.T) {
	buf := make([dynamic]u8)
	defer delete(buf)
	testing.expect_value(t, append_lp_string(&buf, ""), ProtocolError.None)
	_, err := decode_register(buf[:])
	testing.expect_value(t, err, ProtocolError.InvalidServiceId)
}

@(test)
test_decode_register_accepts_max_length_service_id :: proc(t: ^testing.T) {
	name_buf: [MAX_SERVICE_ID_LEN]u8
	for i in 0 ..< len(name_buf) {
		name_buf[i] = 'a'
	}
	name := string(name_buf[:])
	src := Register{service_id = must_service_id(t, name)}
	bytes, err := encode_register(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_register(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(string(got.service_id))
	testing.expect_value(t, len(string(got.service_id)), MAX_SERVICE_ID_LEN)
}

@(test)
test_unregister_ok_payload_round_trip :: proc(t: ^testing.T) {
	src := UnregisterOk{service_id = must_service_id(t, "demo/echo")}
	bytes, err := encode_unregister_ok(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_unregister_ok(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(string(got.service_id))
	testing.expect_value(t, string(got.service_id), "demo/echo")
}

@(test)
test_unregister_failed_uses_wire_failure_payload :: proc(t: ^testing.T) {
	src := WireFailure {
		code       = wire_error_to_u16(.Unauthorized),
		diagnostic = "denied",
	}
	bytes, err := encode_wire_failure(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	got, derr := decode_wire_failure(bytes)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(got.diagnostic)
	testing.expect_value(t, got.code, src.code)
	testing.expect_value(t, got.diagnostic, src.diagnostic)
}

@(test)
test_connect_and_open_payload_round_trip :: proc(t: ^testing.T) {
	id := must_service_id(t, "game/7QF3P9")
	cbytes, cerr := encode_connect(Connect{service_id = id})
	testing.expect_value(t, cerr, ProtocolError.None)
	defer delete(cbytes)
	cgot, cderr := decode_connect(cbytes)
	testing.expect_value(t, cderr, ProtocolError.None)
	defer delete(string(cgot.service_id))
	testing.expect_value(t, string(cgot.service_id), "game/7QF3P9")

	obytes, oerr := encode_open(Open{service_id = id})
	testing.expect_value(t, oerr, ProtocolError.None)
	defer delete(obytes)
	ogot, oderr := decode_open(obytes)
	testing.expect_value(t, oderr, ProtocolError.None)
	defer delete(string(ogot.service_id))
	testing.expect_value(t, string(ogot.service_id), "game/7QF3P9")
}

@(test)
test_ping_pong_payload_round_trip :: proc(t: ^testing.T) {
	pbytes, perr := encode_ping(Ping{nonce = 99})
	testing.expect_value(t, perr, ProtocolError.None)
	defer delete(pbytes)
	ping, pderr := decode_ping(pbytes)
	testing.expect_value(t, pderr, ProtocolError.None)
	testing.expect_value(t, ping.nonce, u64(99))

	gbytes, gerr := encode_pong(Pong{nonce = 99})
	testing.expect_value(t, gerr, ProtocolError.None)
	defer delete(gbytes)
	pong, gderr := decode_pong(gbytes)
	testing.expect_value(t, gderr, ProtocolError.None)
	testing.expect_value(t, pong.nonce, u64(99))
}

@(test)
test_empty_payload_round_trip :: proc(t: ^testing.T) {
	bytes, err := encode_empty()
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	testing.expect_value(t, decode_empty(bytes), ProtocolError.None)
	testing.expect_value(t, decode_empty([]u8{1}), ProtocolError.InvalidPayload)
}

@(test)
test_hello_rejects_unknown_role :: proc(t: ^testing.T) {
	src := Hello {
		major          = PROTOCOL_MAJOR,
		minor          = PROTOCOL_MINOR,
		role           = .Agent,
		implementation = "x",
	}
	bytes, err := encode_hello(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	bytes[2] = 9
	_, derr := decode_hello(bytes)
	testing.expect_value(t, derr, ProtocolError.InvalidPayload)
}

@(test)
test_hello_rejects_trailing_bytes :: proc(t: ^testing.T) {
	src := Hello {
		major          = PROTOCOL_MAJOR,
		minor          = PROTOCOL_MINOR,
		role           = .Caller,
		implementation = "x",
	}
	bytes, err := encode_hello(src)
	testing.expect_value(t, err, ProtocolError.None)
	defer delete(bytes)
	padded := make([]u8, len(bytes) + 1)
	defer delete(padded)
	copy(padded, bytes)
	_, derr := decode_hello(padded)
	testing.expect_value(t, derr, ProtocolError.InvalidPayload)
}

@(test)
test_frame_wrapped_register_round_trip :: proc(t: ^testing.T) {
	payload, perr := encode_register(Register{service_id = must_service_id(t, "demo/echo")})
	testing.expect_value(t, perr, ProtocolError.None)
	defer delete(payload)
	bytes := encode_test_frame(t, .Register, CONNECTION_STREAM_ID, payload)
	defer delete(bytes)

	decoder: FrameDecoder
	testing.expect_value(t, decoder_init(&decoder), ProtocolError.None)
	defer decoder_destroy(&decoder)
	push_all(t, &decoder, bytes)
	frame, ok, err := decoder_next(&decoder)
	testing.expect_value(t, err, ProtocolError.None)
	testing.expect(t, ok)
	defer frame_destroy(&frame)
	got, derr := decode_register(frame.payload)
	testing.expect_value(t, derr, ProtocolError.None)
	defer delete(string(got.service_id))
	testing.expect_value(t, string(got.service_id), "demo/echo")
}
