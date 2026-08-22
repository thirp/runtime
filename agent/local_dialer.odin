package agent

import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:thread"
import "core:time"

agent_write_failure :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	code: proto.WireError,
	stream_id: proto.StreamId,
) -> bool {
	payload, err := proto.encode_wire_failure(
		proto.WireFailure {
			code       = proto.wire_error_to_u16(code),
			diagnostic = "",
		},
	)
	if err != .None {
		return false
	}
	defer delete(payload)
	return agent_write(conn, opcode, payload, stream_id)
}

agent_take_stream :: proc(relay: ^AgentRelay, stream_id: proto.StreamId) -> (AgentLocalStream, bool) {
	sync.mutex_lock(&relay.mutex)
	defer sync.mutex_unlock(&relay.mutex)
	stream, found := relay.streams[stream_id]
	if !found {
		return {}, false
	}
	stream.closed = true
	delete_key(&relay.streams, stream_id)
	return stream, true
}

agent_finish_stream :: proc(relay: ^AgentRelay, stream_id: proto.StreamId) {
	stream, found := agent_take_stream(relay, stream_id)
	if !found {
		return
	}
	if stream.local != nil {
		trans.connection_destroy(stream.local)
	}
}

agent_clear_all :: proc(relay: ^AgentRelay) {
	taken := make([dynamic]AgentLocalStream)
	defer delete(taken)
	sync.mutex_lock(&relay.mutex)
	for _, stream in relay.streams {
		append(&taken, stream)
	}
	clear(&relay.streams)
	sync.mutex_unlock(&relay.mutex)
	for stream in taken {
		if stream.local != nil {
			trans.connection_destroy(stream.local)
		}
	}
	for sync.atomic_load(&relay.live_pumps) != 0 {
		time.sleep(1 * time.Millisecond)
	}
}

agent_lookup_local :: proc(relay: ^AgentRelay, stream_id: proto.StreamId) -> (^trans.Connection, bool) {
	sync.mutex_lock(&relay.mutex)
	defer sync.mutex_unlock(&relay.mutex)
	stream, found := relay.streams[stream_id]
	if !found || stream.closed || stream.local == nil {
		return nil, found
	}
	if !trans.connection_acquire(stream.local) {
		return nil, true
	}
	return stream.local, true
}

agent_pump_local :: proc(arg: ^AgentPumpArg) {
	defer {
		trans.connection_release(arg.local)
		sync.atomic_sub(&arg.relay.live_pumps, 1)
		free(arg)
	}
	buf: [LOCAL_READ_BUF]u8
	for {
		sync.mutex_lock(&arg.relay.mutex)
		stream, found := arg.relay.streams[arg.stream_id]
		closed := !found || stream.closed
		broker := arg.relay.broker
		sync.mutex_unlock(&arg.relay.mutex)
		if closed {
			return
		}
		n, err := trans.connection_read(arg.local, buf[:])
		if err != .None {
			sync.mutex_lock(&arg.relay.mutex)
			stream, found = arg.relay.streams[arg.stream_id]
			if !found || stream.closed {
				sync.mutex_unlock(&arg.relay.mutex)
				return
			}
			half := stream.broker_half_closed
			broker = arg.relay.broker
			sync.mutex_unlock(&arg.relay.mutex)
			_ = agent_write(broker, .HalfClose, nil, arg.stream_id)
			if half {
				_ = agent_write(broker, .Close, nil, arg.stream_id)
				agent_finish_stream(arg.relay, arg.stream_id)
			}
			return
		}
		if !agent_write(broker, .Data, buf[:n], arg.stream_id) {
			return
		}
	}
}

agent_handle_open :: proc(relay: ^AgentRelay, frame: proto.Frame) {
	if sync.atomic_load(&relay.agent.stop) {
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.AgentUnavailable,
			frame.header.stream_id,
		)
		return
	}
	msg, err := proto.decode_open(frame.payload)
	if err != .None {
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.ProtocolError,
			frame.header.stream_id,
		)
		return
	}
	target, found_target := agent_lookup_target(relay.agent, msg.service_id)
	delete(string(msg.service_id))
	if !found_target {
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.LocalServiceUnavailable,
			frame.header.stream_id,
		)
		return
	}

	stream_id := frame.header.stream_id
	sync.mutex_lock(&relay.mutex)
	_, exists := relay.streams[stream_id]
	sync.mutex_unlock(&relay.mutex)
	if exists {
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.StreamAlreadyExists,
			stream_id,
		)
		return
	}

	local, derr := trans.connection_dial(target.address)
	if derr != .None {
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.LocalServiceUnavailable,
			stream_id,
		)
		return
	}

	arg, aerr := new(AgentPumpArg)
	if aerr != .None {
		trans.connection_destroy(local)
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.InternalError,
			stream_id,
		)
		return
	}
	arg.relay = relay
	arg.stream_id = stream_id
	arg.local = local
	if !trans.connection_acquire(local) {
		free(arg)
		trans.connection_destroy(local)
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.InternalError,
			stream_id,
		)
		return
	}

	sync.mutex_lock(&relay.mutex)
	_, exists = relay.streams[stream_id]
	if exists {
		sync.mutex_unlock(&relay.mutex)
		trans.connection_release(local)
		free(arg)
		trans.connection_destroy(local)
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.StreamAlreadyExists,
			stream_id,
		)
		return
	}
	relay.streams[stream_id] = AgentLocalStream {
		local              = local,
		broker_half_closed = false,
		closed             = false,
	}
	sync.atomic_add(&relay.live_pumps, 1)
	sync.mutex_unlock(&relay.mutex)
	thread.run_with_poly_data(arg, agent_pump_local)

	if !agent_write(relay.broker, .OpenOk, nil, stream_id) {
		agent_finish_stream(relay, stream_id)
	}
}

agent_handle_data :: proc(relay: ^AgentRelay, frame: proto.Frame) {
	local, found := agent_lookup_local(relay, frame.header.stream_id)
	if !found {
		_ = agent_write_failure(
			relay.broker,
			.Reset,
			.StreamNotFound,
			frame.header.stream_id,
		)
		return
	}
	if local != nil {
		_ = trans.connection_write(local, frame.payload)
		trans.connection_release(local)
	}
}

agent_handle_half_close :: proc(relay: ^AgentRelay, frame: proto.Frame) {
	sync.mutex_lock(&relay.mutex)
	stream, found := relay.streams[frame.header.stream_id]
	if !found || stream.closed {
		sync.mutex_unlock(&relay.mutex)
		if !found {
			_ = agent_write_failure(
				relay.broker,
				.Reset,
				.StreamNotFound,
				frame.header.stream_id,
			)
		}
		return
	}
	stream.broker_half_closed = true
	relay.streams[frame.header.stream_id] = stream
	local := stream.local
	if local != nil {
		_ = trans.connection_acquire(local)
	}
	sync.mutex_unlock(&relay.mutex)
	if local != nil {
		_ = trans.connection_shutdown_write(local)
		trans.connection_release(local)
	}
}

agent_handle_register_reply :: proc(relay: ^AgentRelay, frame: proto.Frame) {
	err: AgentError = .None
	if frame.header.opcode == .RegisterFailed {
		fail, _ := proto.decode_wire_failure(frame.payload)
		code, _ := proto.wire_error_from_u16(fail.code)
		delete(fail.diagnostic)
		err = wire_to_register_error(code)
	} else {
		ok_msg, oerr := proto.decode_register_ok(frame.payload)
		if oerr == .None {
			delete(string(ok_msg.service_id))
		}
	}
	sync.mutex_lock(&relay.agent.mutex)
	if relay.agent.pending == .Register {
		agent_finish_pending(relay.agent, err)
	}
	sync.mutex_unlock(&relay.agent.mutex)
}

agent_handle_unregister_reply :: proc(relay: ^AgentRelay, frame: proto.Frame) {
	err: AgentError = .None
	if frame.header.opcode == .UnregisterFailed {
		fail, _ := proto.decode_wire_failure(frame.payload)
		code, _ := proto.wire_error_from_u16(fail.code)
		delete(fail.diagnostic)
		err = wire_to_register_error(code)
	} else {
		ok_msg, oerr := proto.decode_unregister_ok(frame.payload)
		if oerr == .None {
			delete(string(ok_msg.service_id))
		}
	}
	sync.mutex_lock(&relay.agent.mutex)
	if relay.agent.pending == .Unregister {
		agent_finish_pending(relay.agent, err)
	}
	sync.mutex_unlock(&relay.agent.mutex)
}

agent_relay_loop :: proc(relay: ^AgentRelay, decoder: ^proto.FrameDecoder) {
	nonce: u64
	last_ping := time.now()
	for {
		if sync.atomic_load(&relay.agent.stop) {
			agent_shutdown_session(relay, decoder)
			return
		}
		_ = trans.connection_set_recv_timeout(relay.broker, 50 * time.Millisecond)
		frame, terr, perr := trans.read_frame(relay.broker, decoder)
		if terr == .Timeout {
			if time.since(last_ping) >= HEARTBEAT_INTERVAL {
				nonce += 1
				payload, eerr := proto.encode_ping(proto.Ping{nonce = nonce})
				if eerr != .None {
					return
				}
				ok := agent_write(relay.broker, .Ping, payload)
				delete(payload)
				if !ok {
					return
				}
				last_ping = time.now()
			}
			continue
		}
		if terr != .None || perr != .None {
			return
		}
		switch frame.header.opcode {
		case .Ping:
			msg, merr := proto.decode_ping(frame.payload)
			if merr == .None {
				payload, _ := proto.encode_pong(proto.Pong{nonce = msg.nonce})
				_ = agent_write(relay.broker, .Pong, payload)
				delete(payload)
			}
		case .Pong:
		case .Open:
			agent_handle_open(relay, frame)
		case .Data:
			agent_handle_data(relay, frame)
		case .HalfClose:
			agent_handle_half_close(relay, frame)
		case .Close, .Reset:
			stream, found := agent_take_stream(relay, frame.header.stream_id)
			if !found {
				_ = agent_write_failure(
					relay.broker,
					.Reset,
					.StreamNotFound,
					frame.header.stream_id,
				)
			} else if stream.local != nil {
				trans.connection_destroy(stream.local)
			}
		case .RegisterOk, .RegisterFailed:
			agent_handle_register_reply(relay, frame)
		case .UnregisterOk, .UnregisterFailed:
			agent_handle_unregister_reply(relay, frame)
		case .Error:
			proto.frame_destroy(&frame)
			return
		case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
		     .Register, .Unregister, .Connect, .ConnectOk,
		     .ConnectFailed, .OpenOk, .OpenFailed:
			proto.frame_destroy(&frame)
			return
		}
		proto.frame_destroy(&frame)
	}
}

agent_shutdown_session :: proc(relay: ^AgentRelay, decoder: ^proto.FrameDecoder) {
	agent_unregister_owned(relay.broker, decoder, relay.agent)
	agent_reset_all_streams(relay)
	agent_clear_all(relay)
}

agent_reset_all_streams :: proc(relay: ^AgentRelay) {
	ids: [dynamic]proto.StreamId
	taken: [dynamic]AgentLocalStream
	defer delete(ids)
	defer delete(taken)
	sync.mutex_lock(&relay.mutex)
	for id, stream in relay.streams {
		append(&ids, id)
		append(&taken, stream)
	}
	clear(&relay.streams)
	sync.mutex_unlock(&relay.mutex)
	for i in 0 ..< len(ids) {
		_ = agent_write_failure(relay.broker, .Reset, .InternalError, ids[i])
		if taken[i].local != nil {
			trans.connection_destroy(taken[i].local)
		}
	}
	for sync.atomic_load(&relay.live_pumps) != 0 {
		time.sleep(1 * time.Millisecond)
	}
}
