package c_abi

import proto "../protocol"
import "core:c"
import "core:testing"

@(test)
test_agent_error_to_c_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, agent_error_to_c(.None), ERR_OK)
	testing.expect_value(t, agent_error_to_c(.InvalidConfig), ERR_INVALID_ARGUMENT)
	testing.expect_value(t, agent_error_to_c(.InvalidServiceId), ERR_INVALID_SERVICE_ID)
	testing.expect_value(t, agent_error_to_c(.Transport), ERR_TRANSPORT)
	testing.expect_value(t, agent_error_to_c(.AuthFailed), ERR_AUTHENTICATION_FAILED)
	testing.expect_value(t, agent_error_to_c(.RegisterFailed), ERR_INTERNAL_ERROR)
	testing.expect_value(t, agent_error_to_c(.ServiceAlreadyRegistered), ERR_SERVICE_ALREADY_REGISTERED)
	testing.expect_value(t, agent_error_to_c(.QuotaExceeded), ERR_QUOTA_EXCEEDED)
	testing.expect_value(t, agent_error_to_c(.BrokerDraining), ERR_BROKER_DRAINING)
	testing.expect_value(t, agent_error_to_c(.Stopped), ERR_STOPPED)
	testing.expect_value(t, agent_error_to_c(.Internal), ERR_INTERNAL_ERROR)
	testing.expect_value(t, agent_error_to_c(.OutOfMemory), ERR_OUT_OF_MEMORY)
}

@(test)
test_caller_error_to_c_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, caller_error_to_c(.None), ERR_OK)
	testing.expect_value(t, caller_error_to_c(.InvalidConfig), ERR_INVALID_ARGUMENT)
	testing.expect_value(t, caller_error_to_c(.InvalidServiceId), ERR_INVALID_SERVICE_ID)
	testing.expect_value(t, caller_error_to_c(.Transport), ERR_TRANSPORT)
	testing.expect_value(t, caller_error_to_c(.AuthFailed), ERR_AUTHENTICATION_FAILED)
	testing.expect_value(t, caller_error_to_c(.ServiceNotFound), ERR_SERVICE_NOT_FOUND)
	testing.expect_value(t, caller_error_to_c(.Unauthorized), ERR_UNAUTHORIZED)
	testing.expect_value(t, caller_error_to_c(.AgentUnavailable), ERR_AGENT_UNAVAILABLE)
	testing.expect_value(t, caller_error_to_c(.QuotaExceeded), ERR_QUOTA_EXCEEDED)
	testing.expect_value(t, caller_error_to_c(.BrokerDraining), ERR_BROKER_DRAINING)
	testing.expect_value(t, caller_error_to_c(.Closed), ERR_CLOSED)
	testing.expect_value(t, caller_error_to_c(.Timeout), ERR_TIMEOUT)
	testing.expect_value(t, caller_error_to_c(.Internal), ERR_INTERNAL_ERROR)
	testing.expect_value(t, caller_error_to_c(.OutOfMemory), ERR_OUT_OF_MEMORY)
	testing.expect_value(t, caller_error_to_c(.RateLimited), ERR_RATE_LIMITED)
	testing.expect_value(t, caller_error_to_c(.LocalServiceUnavailable), ERR_LOCAL_SERVICE_UNAVAILABLE)
}

@(test)
test_conn_error_to_c_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, conn_error_to_c(.None), ERR_OK)
	testing.expect_value(t, conn_error_to_c(.Closed), ERR_CLOSED)
	testing.expect_value(t, conn_error_to_c(.Reset), ERR_RESET)
	testing.expect_value(t, conn_error_to_c(.Transport), ERR_TRANSPORT)
	testing.expect_value(t, conn_error_to_c(.Timeout), ERR_TIMEOUT)
}

@(test)
test_overlay_codes_do_not_collide_with_wire :: proc(t: ^testing.T) {
	testing.expect(t, ERR_INVALID_ARGUMENT > c.int(proto.WireError.InternalError))
	testing.expect_value(t, ERR_INVALID_ARGUMENT, c.int(100))
	testing.expect_value(t, ERR_OUT_OF_MEMORY, c.int(101))
	testing.expect_value(t, ERR_NOT_CONNECTED, c.int(102))
	testing.expect_value(t, ERR_STOPPED, c.int(103))
	testing.expect_value(t, ERR_CLOSED, c.int(104))
	testing.expect_value(t, ERR_RESET, c.int(105))
	testing.expect_value(t, ERR_TRANSPORT, c.int(106))
	testing.expect_value(t, ERR_AUTHENTICATION_FAILED, c.int(3))
	testing.expect_value(t, ERR_SERVICE_NOT_FOUND, c.int(6))
}
