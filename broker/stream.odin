package broker

check_stream_event :: proc(state: StreamState, event: StreamEvent, from: StreamPeer) -> StreamError {
	#partial switch state {
	case .Opening:
		switch event {
		case .OpenOk, .OpenFailed:
			if from != .Agent {
				return .IllegalEvent
			}
			return .None
		case .Close, .Reset, .Disconnected:
			return .None
		case .Data, .HalfClose:
			return .IllegalEvent
		}
	case .Open:
		switch event {
		case .Data, .HalfClose, .Close, .Reset, .Disconnected:
			return .None
		case .OpenOk, .OpenFailed:
			return .IllegalEvent
		}
	case .CallerHalfClosed:
		switch event {
		case .Data:
			if from == .Caller {
				return .IllegalEvent
			}
			return .None
		case .HalfClose:
			if from == .Caller {
				return .IllegalEvent
			}
			return .None
		case .Close, .Reset, .Disconnected:
			return .None
		case .OpenOk, .OpenFailed:
			return .IllegalEvent
		}
	case .AgentHalfClosed:
		switch event {
		case .Data:
			if from == .Agent {
				return .IllegalEvent
			}
			return .None
		case .HalfClose:
			if from == .Agent {
				return .IllegalEvent
			}
			return .None
		case .Close, .Reset, .Disconnected:
			return .None
		case .OpenOk, .OpenFailed:
			return .IllegalEvent
		}
	case .Closed, .Reset:
		return .IllegalEvent
	}
	return .IllegalEvent
}

apply_stream_event :: proc(state: StreamState, event: StreamEvent, from: StreamPeer) -> (StreamState, StreamError) {
	if err := check_stream_event(state, event, from); err != .None {
		return state, err
	}
	switch event {
	case .OpenOk:
		return .Open, .None
	case .OpenFailed:
		return .Closed, .None
	case .Data:
		return state, .None
	case .HalfClose:
		if state == .Open {
			if from == .Caller {
				return .CallerHalfClosed, .None
			}
			return .AgentHalfClosed, .None
		}
		return .Closed, .None
	case .Close:
		return .Closed, .None
	case .Reset, .Disconnected:
		return .Reset, .None
	}
	return state, .IllegalEvent
}

stream_state_is_terminal :: proc(state: StreamState) -> bool {
	return state == .Closed || state == .Reset
}

stream_peer_opposite :: proc(from: StreamPeer) -> StreamPeer {
	if from == .Caller {
		return .Agent
	}
	return .Caller
}
