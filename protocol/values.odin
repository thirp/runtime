package protocol

PROTOCOL_MAJOR :: u8(1)
PROTOCOL_MINOR :: u8(0)

HEADER_SIZE :: 16
MAX_FRAME_PAYLOAD :: u32(64 * 1024)
RECOMMENDED_DATA_PAYLOAD :: 16 * 1024
MAX_SERVICE_ID_LEN :: 128
CONNECTION_STREAM_ID :: StreamId(0)
DECODER_BUFFER_CAP :: HEADER_SIZE + int(MAX_FRAME_PAYLOAD)

make_service_id :: proc(value: string) -> (ServiceId, ServiceIdError) {
	if err := check_service_id(value); err != .None {
		return {}, err
	}
	return ServiceId(value), .None
}

check_service_id :: proc(value: string) -> ServiceIdError {
	if len(value) == 0 {
		return .Empty
	}
	if len(value) > MAX_SERVICE_ID_LEN {
		return .TooLong
	}
	for i in 0 ..< len(value) {
		b := value[i]
		switch b {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '/', '.':
			continue
		case:
			return .InvalidCharacter
		}
	}
	return .None
}

make_stream_id :: proc(value: u64) -> StreamId {
	return StreamId(value)
}

opcode_from_u8 :: proc(value: u8) -> (Opcode, bool) {
	switch value {
	case u8(Opcode.Hello) ..= u8(Opcode.UnregisterFailed):
		return Opcode(value), true
	}
	return {}, false
}

peer_role_from_u8 :: proc(value: u8) -> (PeerRole, bool) {
	switch value {
	case u8(PeerRole.Agent), u8(PeerRole.Caller):
		return PeerRole(value), true
	}
	return {}, false
}

opcode_requires_zero_stream :: proc(opcode: Opcode) -> bool {
	#partial switch opcode {
	case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
	     .Register, .RegisterOk, .RegisterFailed, .Unregister,
	     .UnregisterOk, .UnregisterFailed,
	     .Connect, .ConnectFailed, .Ping, .Pong, .Error:
		return true
	}
	return false
}

opcode_requires_nonzero_stream :: proc(opcode: Opcode) -> bool {
	#partial switch opcode {
	case .ConnectOk, .Open, .OpenOk, .OpenFailed,
	     .Data, .HalfClose, .Close, .Reset:
		return true
	}
	return false
}

service_id_error_to_protocol :: proc(err: ServiceIdError) -> ProtocolError {
	if err == .None {
		return .None
	}
	return .InvalidServiceId
}
