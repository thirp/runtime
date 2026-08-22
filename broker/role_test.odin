package broker

import proto "../protocol"
import "core:testing"

@(test)
test_check_opcode_role_agent_allowed :: proc(t: ^testing.T) {
	allowed := []proto.Opcode{.Register, .Unregister, .OpenOk, .OpenFailed, .Data, .HalfClose, .Close, .Reset, .Ping, .Pong}
	for opcode in allowed {
		testing.expect_value(t, check_opcode_role(.Agent, opcode), RoleError.None)
	}
}

@(test)
test_check_opcode_role_caller_allowed :: proc(t: ^testing.T) {
	allowed := []proto.Opcode{.Connect, .Data, .HalfClose, .Close, .Reset, .Ping, .Pong}
	for opcode in allowed {
		testing.expect_value(t, check_opcode_role(.Caller, opcode), RoleError.None)
	}
}

@(test)
test_check_opcode_role_caller_register_unregister_open_replies :: proc(t: ^testing.T) {
	denied := []proto.Opcode{.Register, .Unregister, .OpenOk, .OpenFailed}
	for opcode in denied {
		testing.expect_value(t, check_opcode_role(.Caller, opcode), RoleError.RoleViolation)
	}
}

@(test)
test_check_opcode_role_agent_connect_rejected :: proc(t: ^testing.T) {
	testing.expect_value(t, check_opcode_role(.Agent, .Connect), RoleError.RoleViolation)
}

@(test)
test_check_opcode_role_unregister_replies_are_broker_originated :: proc(t: ^testing.T) {
	testing.expect_value(t, check_opcode_role(.Agent, .UnregisterOk), RoleError.None)
	testing.expect_value(t, check_opcode_role(.Agent, .UnregisterFailed), RoleError.None)
	testing.expect_value(t, check_opcode_role(.Caller, .UnregisterOk), RoleError.None)
	testing.expect_value(t, check_opcode_role(.Caller, .UnregisterFailed), RoleError.None)
}

@(test)
test_check_opcode_role_open_rejected_for_both_roles :: proc(t: ^testing.T) {
	testing.expect_value(t, check_opcode_role(.Agent, .Open), RoleError.RoleViolation)
	testing.expect_value(t, check_opcode_role(.Caller, .Open), RoleError.RoleViolation)
}
