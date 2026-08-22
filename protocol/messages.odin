package protocol

encode_hello :: proc(msg: Hello, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	buf := make([dynamic]u8, 0, 32 + len(msg.implementation), allocator)
	defer if err != .None {
		delete(buf)
	}
	append_u8(&buf, msg.major) or_return
	append_u8(&buf, msg.minor) or_return
	append_u8(&buf, u8(msg.role)) or_return
	append_u64be(&buf, msg.capability_bits) or_return
	append_lp_string(&buf, msg.implementation) or_return
	return finish_payload(&buf)
}

decode_hello :: proc(payload: []u8, allocator := context.allocator) -> (msg: Hello, err: ProtocolError) {
	r := PayloadReader{data = payload}
	msg.major = read_u8(&r) or_return
	msg.minor = read_u8(&r) or_return
	role_u8 := read_u8(&r) or_return
	role, rok := peer_role_from_u8(role_u8)
	if !rok {
		return {}, .InvalidPayload
	}
	msg.role = role
	msg.capability_bits = read_u64be(&r) or_return
	msg.implementation = read_lp_string(&r, allocator) or_return
	err = require_consumed(&r)
	if err != .None {
		delete(msg.implementation, allocator)
		return {}, err
	}
	return
}

encode_hello_ack :: proc(msg: HelloAck, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	buf := make([dynamic]u8, 0, 32 + len(msg.implementation), allocator)
	defer if err != .None {
		delete(buf)
	}
	append_u8(&buf, msg.major) or_return
	append_u8(&buf, msg.minor) or_return
	append_u64be(&buf, msg.capability_bits) or_return
	append_lp_string(&buf, msg.implementation) or_return
	return finish_payload(&buf)
}

decode_hello_ack :: proc(payload: []u8, allocator := context.allocator) -> (msg: HelloAck, err: ProtocolError) {
	r := PayloadReader{data = payload}
	msg.major = read_u8(&r) or_return
	msg.minor = read_u8(&r) or_return
	msg.capability_bits = read_u64be(&r) or_return
	msg.implementation = read_lp_string(&r, allocator) or_return
	err = require_consumed(&r)
	if err != .None {
		delete(msg.implementation, allocator)
		return {}, err
	}
	return
}

encode_authenticate :: proc(msg: Authenticate, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	buf := make([dynamic]u8, 0, 2 + len(msg.token), allocator)
	defer if err != .None {
		delete(buf)
	}
	append_lp_bytes(&buf, msg.token) or_return
	return finish_payload(&buf)
}

decode_authenticate :: proc(payload: []u8, allocator := context.allocator) -> (msg: Authenticate, err: ProtocolError) {
	r := PayloadReader{data = payload}
	token := read_lp_bytes(&r, allocator) or_return
	err = require_consumed(&r)
	if err != .None {
		delete(token, allocator)
		return {}, err
	}
	return Authenticate{token = token}, .None
}

encode_authenticate_ok :: proc(msg: AuthenticateOk, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	buf := make([dynamic]u8, 0, 2 + len(msg.principal_id), allocator)
	defer if err != .None {
		delete(buf)
	}
	append_lp_string(&buf, msg.principal_id) or_return
	return finish_payload(&buf)
}

decode_authenticate_ok :: proc(payload: []u8, allocator := context.allocator) -> (msg: AuthenticateOk, err: ProtocolError) {
	r := PayloadReader{data = payload}
	principal_id := read_lp_string(&r, allocator) or_return
	err = require_consumed(&r)
	if err != .None {
		delete(principal_id, allocator)
		return {}, err
	}
	return AuthenticateOk{principal_id = principal_id}, .None
}

encode_wire_failure :: proc(msg: WireFailure, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	buf := make([dynamic]u8, 0, 4 + len(msg.diagnostic), allocator)
	defer if err != .None {
		delete(buf)
	}
	append_u16be(&buf, msg.code) or_return
	append_lp_string(&buf, msg.diagnostic) or_return
	return finish_payload(&buf)
}

decode_wire_failure :: proc(payload: []u8, allocator := context.allocator) -> (msg: WireFailure, err: ProtocolError) {
	r := PayloadReader{data = payload}
	code := read_u16be(&r) or_return
	diagnostic := read_lp_string(&r, allocator) or_return
	err = require_consumed(&r)
	if err != .None {
		delete(diagnostic, allocator)
		return {}, err
	}
	return WireFailure{code = code, diagnostic = diagnostic}, .None
}

encode_service_id_payload :: proc(service_id: ServiceId, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	s := string(service_id)
	if check_service_id(s) != .None {
		return nil, .InvalidServiceId
	}
	buf := make([dynamic]u8, 0, 2 + len(s), allocator)
	defer if err != .None {
		delete(buf)
	}
	append_lp_string(&buf, s) or_return
	return finish_payload(&buf)
}

decode_service_id_payload :: proc(payload: []u8, allocator := context.allocator) -> (id: ServiceId, err: ProtocolError) {
	r := PayloadReader{data = payload}
	s := read_lp_string(&r, allocator) or_return
	err = require_consumed(&r)
	if err != .None {
		delete(s, allocator)
		return {}, err
	}
	constructed, serr := make_service_id(s)
	if serr != .None {
		delete(s, allocator)
		return {}, .InvalidServiceId
	}
	return constructed, .None
}

encode_register :: proc(msg: Register, allocator := context.allocator) -> ([]u8, ProtocolError) {
	return encode_service_id_payload(msg.service_id, allocator)
}

decode_register :: proc(payload: []u8, allocator := context.allocator) -> (msg: Register, err: ProtocolError) {
	id := decode_service_id_payload(payload, allocator) or_return
	return Register{service_id = id}, .None
}

encode_register_ok :: proc(msg: RegisterOk, allocator := context.allocator) -> ([]u8, ProtocolError) {
	return encode_service_id_payload(msg.service_id, allocator)
}

decode_register_ok :: proc(payload: []u8, allocator := context.allocator) -> (msg: RegisterOk, err: ProtocolError) {
	id := decode_service_id_payload(payload, allocator) or_return
	return RegisterOk{service_id = id}, .None
}

encode_unregister :: proc(msg: Unregister, allocator := context.allocator) -> ([]u8, ProtocolError) {
	return encode_service_id_payload(msg.service_id, allocator)
}

decode_unregister :: proc(payload: []u8, allocator := context.allocator) -> (msg: Unregister, err: ProtocolError) {
	id := decode_service_id_payload(payload, allocator) or_return
	return Unregister{service_id = id}, .None
}

encode_unregister_ok :: proc(msg: UnregisterOk, allocator := context.allocator) -> ([]u8, ProtocolError) {
	return encode_service_id_payload(msg.service_id, allocator)
}

decode_unregister_ok :: proc(payload: []u8, allocator := context.allocator) -> (msg: UnregisterOk, err: ProtocolError) {
	id := decode_service_id_payload(payload, allocator) or_return
	return UnregisterOk{service_id = id}, .None
}

encode_connect :: proc(msg: Connect, allocator := context.allocator) -> ([]u8, ProtocolError) {
	return encode_service_id_payload(msg.service_id, allocator)
}

decode_connect :: proc(payload: []u8, allocator := context.allocator) -> (msg: Connect, err: ProtocolError) {
	id := decode_service_id_payload(payload, allocator) or_return
	return Connect{service_id = id}, .None
}

encode_open :: proc(msg: Open, allocator := context.allocator) -> ([]u8, ProtocolError) {
	return encode_service_id_payload(msg.service_id, allocator)
}

decode_open :: proc(payload: []u8, allocator := context.allocator) -> (msg: Open, err: ProtocolError) {
	id := decode_service_id_payload(payload, allocator) or_return
	return Open{service_id = id}, .None
}

encode_ping :: proc(msg: Ping, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	buf := make([dynamic]u8, 0, 8, allocator)
	defer if err != .None {
		delete(buf)
	}
	append_u64be(&buf, msg.nonce) or_return
	return finish_payload(&buf)
}

decode_ping :: proc(payload: []u8) -> (msg: Ping, err: ProtocolError) {
	r := PayloadReader{data = payload}
	nonce := read_u64be(&r) or_return
	require_consumed(&r) or_return
	return Ping{nonce = nonce}, .None
}

encode_pong :: proc(msg: Pong, allocator := context.allocator) -> (out: []u8, err: ProtocolError) {
	buf := make([dynamic]u8, 0, 8, allocator)
	defer if err != .None {
		delete(buf)
	}
	append_u64be(&buf, msg.nonce) or_return
	return finish_payload(&buf)
}

decode_pong :: proc(payload: []u8) -> (msg: Pong, err: ProtocolError) {
	r := PayloadReader{data = payload}
	nonce := read_u64be(&r) or_return
	require_consumed(&r) or_return
	return Pong{nonce = nonce}, .None
}

encode_empty :: proc(allocator := context.allocator) -> ([]u8, ProtocolError) {
	_ = allocator
	return nil, .None
}

decode_empty :: proc(payload: []u8) -> ProtocolError {
	return require_empty_payload(payload)
}
