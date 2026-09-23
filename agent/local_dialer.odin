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
	agent_destroy_local(stream.local)
}

// RESET only if this session still owns the stream. A write failure after
// finish_stream / CLOSE must not emit RESET for an id the broker already
// dropped — that is the StreamNotFound ping-pong.
agent_reset_owned_stream :: proc(
	relay: ^AgentRelay,
	stream_id: proto.StreamId,
	code: proto.WireError,
) {
	stream, found := agent_take_stream(relay, stream_id)
	if !found {
		return
	}
	_ = agent_write_failure(relay.broker, .Reset, code, stream_id)
	agent_destroy_local(stream.local)
}

agent_destroy_local :: proc(local: ^trans.Connection) {
	if local == nil {
		return
	}
	// Shutdown first so the pump leaves recv; close() alone can RST and
	// race fd reuse (docs/RACES.md).
	trans.connection_shutdown_both(local)
	trans.connection_destroy(local)
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
		agent_destroy_local(stream.local)
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
		sync.mutex_lock(&arg.relay.mutex)
		stream, found = arg.relay.streams[arg.stream_id]
		closed = !found || stream.closed
		broker = arg.relay.broker
		half := found && stream.broker_half_closed
		sync.mutex_unlock(&arg.relay.mutex)
		if closed {
			return
		}
		if err != .None {
			if !agent_write(broker, .HalfClose, nil, arg.stream_id) {
				agent_finish_stream(arg.relay, arg.stream_id)
				return
			}
			if half {
				_ = agent_write(broker, .Close, nil, arg.stream_id)
				agent_finish_stream(arg.relay, arg.stream_id)
			}
			return
		}
		if !agent_write(broker, .Data, buf[:n], arg.stream_id) {
			agent_reset_owned_stream(arg.relay, arg.stream_id, .InternalError)
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

	arg, aerr := new(AgentOpenArg)
	if aerr != .None {
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
	arg.target = target
	// Count the open worker as a live pump so clear/shutdown waits for dial.
	sync.atomic_add(&relay.live_pumps, 1)
	thread.run_with_poly_data(arg, agent_open_worker)
}

agent_open_worker :: proc(arg: ^AgentOpenArg) {
	relay := arg.relay
	stream_id := arg.stream_id
	target := arg.target
	defer {
		free(arg)
	}

	if sync.atomic_load(&relay.agent.stop) {
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.AgentUnavailable,
			stream_id,
		)
		sync.atomic_sub(&relay.live_pumps, 1)
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
		sync.atomic_sub(&relay.live_pumps, 1)
		return
	}
	// Bound local send so broker→local DATA cannot HOL-block forever if the
	// target stops reading. Zero send_timeout on the broker TLS conn is set
	// separately so pump DATA uses true TCP/TLS backpressure.
	_ = trans.connection_set_send_timeout(local, 5 * time.Second)

	pump, perr := new(AgentPumpArg)
	if perr != .None {
		trans.connection_destroy(local)
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.InternalError,
			stream_id,
		)
		sync.atomic_sub(&relay.live_pumps, 1)
		return
	}
	pump.relay = relay
	pump.stream_id = stream_id
	pump.local = local
	if !trans.connection_acquire(local) {
		free(pump)
		trans.connection_destroy(local)
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.InternalError,
			stream_id,
		)
		sync.atomic_sub(&relay.live_pumps, 1)
		return
	}

	sync.mutex_lock(&relay.mutex)
	_, exists := relay.streams[stream_id]
	if exists {
		sync.mutex_unlock(&relay.mutex)
		trans.connection_release(local)
		free(pump)
		trans.connection_destroy(local)
		_ = agent_write_failure(
			relay.broker,
			.OpenFailed,
			.StreamAlreadyExists,
			stream_id,
		)
		sync.atomic_sub(&relay.live_pumps, 1)
		return
	}
	relay.streams[stream_id] = AgentLocalStream {
		local              = local,
		broker_half_closed = false,
		closed             = false,
	}
	// live_pumps already counted for this open worker; transfer ownership to
	// the pump thread (pump defer still atomic_sub).
	sync.mutex_unlock(&relay.mutex)
	thread.run_with_poly_data(pump, agent_pump_local)

	if !agent_write(relay.broker, .OpenOk, nil, stream_id) {
		agent_finish_stream(relay, stream_id)
	}
}

agent_handle_data :: proc(relay: ^AgentRelay, frame: proto.Frame) {
	local, found := agent_lookup_local(relay, frame.header.stream_id)
	if !found {
		// Finished or never inserted. Do not RESET StreamNotFound —
		// the broker answers the same code and the pair hot-loops
		// for the rest of the agent session.
		return
	}
	if local != nil {
		werr := trans.connection_write(local, frame.payload)
		trans.connection_release(local)
		if werr != .None {
			agent_reset_owned_stream(relay, frame.header.stream_id, .InternalError)
		}
	}
}

agent_handle_half_close :: proc(relay: ^AgentRelay, frame: proto.Frame) {
	sync.mutex_lock(&relay.mutex)
	stream, found := relay.streams[frame.header.stream_id]
	if !found || stream.closed {
		sync.mutex_unlock(&relay.mutex)
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
		// Force DATA writes to block on peer window instead of inheriting the
		// 50ms read-poll timeout (which turned backpressure into RESET storms).
		_ = trans.connection_set_send_timeout(relay.broker, 0)
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
			// Terminal. Do not echo StreamNotFound — that ping-pongs
			// with the broker until the session dies.
			agent_finish_stream(relay, frame.header.stream_id)
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
		agent_destroy_local(taken[i].local)
	}
	for sync.atomic_load(&relay.live_pumps) != 0 {
		time.sleep(1 * time.Millisecond)
	}
}
