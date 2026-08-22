package broker

import proto "../protocol"

check_opcode_role :: proc(role: proto.PeerRole, opcode: proto.Opcode) -> RoleError {
	switch opcode {
	case .Register, .Unregister, .OpenOk, .OpenFailed:
		if role != .Agent {
			return .RoleViolation
		}
		return .None
	case .Connect:
		if role != .Caller {
			return .RoleViolation
		}
		return .None
	case .Open:
		return .RoleViolation
	case .Data, .HalfClose, .Close, .Reset, .Ping, .Pong:
		return .None
	case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
	     .RegisterOk, .RegisterFailed, .UnregisterOk, .UnregisterFailed,
	     .ConnectOk, .ConnectFailed, .Error:
		return .None
	}
	return .None
}
