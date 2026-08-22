package broker

import "core:testing"

@(test)
test_stream_open_ok_opens :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Opening, .OpenOk, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Open)
}

@(test)
test_stream_open_failed_closes :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Opening, .OpenFailed, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Closed)
}

@(test)
test_stream_open_ok_from_caller_illegal :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Opening, .OpenOk, .Caller)
	testing.expect_value(t, err, StreamError.IllegalEvent)
	testing.expect_value(t, next, StreamState.Opening)
}

@(test)
test_stream_data_in_opening_illegal :: proc(t: ^testing.T) {
	testing.expect_value(t, check_stream_event(.Opening, .Data, .Caller), StreamError.IllegalEvent)
	testing.expect_value(t, check_stream_event(.Opening, .Data, .Agent), StreamError.IllegalEvent)
	next, err := apply_stream_event(.Opening, .Data, .Caller)
	testing.expect_value(t, err, StreamError.IllegalEvent)
	testing.expect_value(t, next, StreamState.Opening)
}

@(test)
test_stream_data_in_open_stays_open :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Open, .Data, .Caller)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Open)
	next, err = apply_stream_event(.Open, .Data, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Open)
}

@(test)
test_stream_close_from_open :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Open, .Close, .Caller)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Closed)
	testing.expect(t, stream_state_is_terminal(next))
}

@(test)
test_stream_half_close_caller_then_agent :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Open, .HalfClose, .Caller)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.CallerHalfClosed)

	next, err = apply_stream_event(next, .Data, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.CallerHalfClosed)

	testing.expect_value(t, check_stream_event(next, .Data, .Caller), StreamError.IllegalEvent)

	next, err = apply_stream_event(next, .HalfClose, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Closed)
}

@(test)
test_stream_half_close_agent_then_caller :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Open, .HalfClose, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.AgentHalfClosed)

	next, err = apply_stream_event(next, .Data, .Caller)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.AgentHalfClosed)

	next, err = apply_stream_event(next, .HalfClose, .Caller)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Closed)
}

@(test)
test_stream_reset_from_open :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Open, .Reset, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Reset)
	testing.expect_value(t, check_stream_event(next, .Data, .Caller), StreamError.IllegalEvent)
}

@(test)
test_stream_disconnect_resets :: proc(t: ^testing.T) {
	next, err := apply_stream_event(.Open, .Disconnected, .Caller)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Reset)

	next, err = apply_stream_event(.Opening, .Disconnected, .Agent)
	testing.expect_value(t, err, StreamError.None)
	testing.expect_value(t, next, StreamState.Reset)
}

@(test)
test_stream_terminal_rejects_further_events :: proc(t: ^testing.T) {
	testing.expect_value(t, check_stream_event(.Closed, .Data, .Caller), StreamError.IllegalEvent)
	testing.expect_value(t, check_stream_event(.Reset, .Close, .Agent), StreamError.IllegalEvent)
}
