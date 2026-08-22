package protocol

import "core:testing"

@(test)
test_make_service_id_accepts_game_join_code :: proc(t: ^testing.T) {
	id, err := make_service_id("game/7QF3P9")
	testing.expect_value(t, err, ServiceIdError.None)
	testing.expect_value(t, string(id), "game/7QF3P9")
}

@(test)
test_make_service_id_accepts_enterprise_path :: proc(t: ^testing.T) {
	id, err := make_service_id("acme/atlanta/reporting-api")
	testing.expect_value(t, err, ServiceIdError.None)
	testing.expect_value(t, string(id), "acme/atlanta/reporting-api")
}

@(test)
test_make_service_id_accepts_allowed_punctuation :: proc(t: ^testing.T) {
	id, err := make_service_id("buildfarm/linux/x86-17")
	testing.expect_value(t, err, ServiceIdError.None)
	testing.expect_value(t, string(id), "buildfarm/linux/x86-17")
	id, err = make_service_id("a_b.c")
	testing.expect_value(t, err, ServiceIdError.None)
	testing.expect_value(t, string(id), "a_b.c")
}

@(test)
test_make_service_id_is_case_sensitive :: proc(t: ^testing.T) {
	lower, lerr := make_service_id("Game/Abc")
	upper, uerr := make_service_id("game/abc")
	testing.expect_value(t, lerr, ServiceIdError.None)
	testing.expect_value(t, uerr, ServiceIdError.None)
	testing.expect(t, lower != upper)
}

@(test)
test_check_service_id_rejects_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, check_service_id(""), ServiceIdError.Empty)
	_, err := make_service_id("")
	testing.expect_value(t, err, ServiceIdError.Empty)
}

@(test)
test_check_service_id_rejects_too_long :: proc(t: ^testing.T) {
	buf: [MAX_SERVICE_ID_LEN + 1]u8
	for i in 0 ..< len(buf) {
		buf[i] = 'a'
	}
	testing.expect_value(t, check_service_id(string(buf[:])), ServiceIdError.TooLong)
	_, err := make_service_id(string(buf[:MAX_SERVICE_ID_LEN]))
	testing.expect_value(t, err, ServiceIdError.None)
}

@(test)
test_check_service_id_rejects_illegal_characters :: proc(t: ^testing.T) {
	testing.expect_value(t, check_service_id("game 7"), ServiceIdError.InvalidCharacter)
	testing.expect_value(t, check_service_id("game@host"), ServiceIdError.InvalidCharacter)
	testing.expect_value(t, check_service_id("game:7"), ServiceIdError.InvalidCharacter)
	testing.expect_value(t, check_service_id("game\n7"), ServiceIdError.InvalidCharacter)
}

@(test)
test_opcode_from_u8_accepts_defined_range :: proc(t: ^testing.T) {
	first, fok := opcode_from_u8(u8(Opcode.Hello))
	testing.expect(t, fok)
	testing.expect_value(t, first, Opcode.Hello)
	last, lok := opcode_from_u8(u8(Opcode.UnregisterFailed))
	testing.expect(t, lok)
	testing.expect_value(t, last, Opcode.UnregisterFailed)
	ok23, ok23b := opcode_from_u8(23)
	testing.expect(t, ok23b)
	testing.expect_value(t, ok23, Opcode.UnregisterOk)
	ok24, ok24b := opcode_from_u8(24)
	testing.expect(t, ok24b)
	testing.expect_value(t, ok24, Opcode.UnregisterFailed)
	err_op, err_ok := opcode_from_u8(u8(Opcode.Error))
	testing.expect(t, err_ok)
	testing.expect_value(t, err_op, Opcode.Error)
}

@(test)
test_unregister_opcodes_require_zero_stream :: proc(t: ^testing.T) {
	testing.expect(t, opcode_requires_zero_stream(.UnregisterOk))
	testing.expect(t, opcode_requires_zero_stream(.UnregisterFailed))
	testing.expect(t, !opcode_requires_nonzero_stream(.UnregisterOk))
	testing.expect(t, !opcode_requires_nonzero_stream(.UnregisterFailed))
}

@(test)
test_opcode_from_u8_rejects_unknown :: proc(t: ^testing.T) {
	_, ok := opcode_from_u8(0)
	testing.expect(t, !ok)
	_, ok = opcode_from_u8(99)
	testing.expect(t, !ok)
}

@(test)
test_wire_error_numeric_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, wire_error_to_u16(.None), u16(0))
	testing.expect_value(t, wire_error_to_u16(.ProtocolError), u16(1))
	testing.expect_value(t, wire_error_to_u16(.InternalError), u16(17))
	err, ok := wire_error_from_u16(9)
	testing.expect(t, ok)
	testing.expect_value(t, err, WireError.LocalServiceUnavailable)
	_, ok = wire_error_from_u16(99)
	testing.expect(t, !ok)
}

@(test)
test_make_stream_id_wraps_u64 :: proc(t: ^testing.T) {
	testing.expect_value(t, make_stream_id(0), CONNECTION_STREAM_ID)
	testing.expect_value(t, u64(make_stream_id(0x0102030405060708)), u64(0x0102030405060708))
}
