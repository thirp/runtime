package agent

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:crypto"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

agent_init :: proc(agent: ^Agent, config: AgentConfig) -> AgentError {
	if agent == nil {
		return .InvalidConfig
	}
	if config.broker.port == 0 {
		return .InvalidConfig
	}
	if len(config.token) == 0 {
		return .InvalidConfig
	}
	if config.insecure && (len(config.tls_ca) > 0 || len(config.tls_server_name) > 0) {
		return .InvalidConfig
	}
	if !tls_ca_readable(config.tls_ca) {
		return .InvalidConfig
	}

	agent^ = {}
	services := make(map[proto.ServiceId]AgentService)
	impl := config.implementation
	if len(impl) == 0 {
		impl = DEFAULT_IMPLEMENTATION
	}

	token, terr := strings.clone(config.token)
	if terr != .None {
		delete(services)
		return .OutOfMemory
	}
	ca, caerr := strings.clone(config.tls_ca)
	if caerr != .None {
		delete(token)
		delete(services)
		return .OutOfMemory
	}
	sni, snerr := strings.clone(config.tls_server_name)
	if snerr != .None {
		delete(token)
		delete(ca)
		delete(services)
		return .OutOfMemory
	}
	implementation, ierr := strings.clone(impl)
	if ierr != .None {
		delete(token)
		delete(ca)
		delete(sni)
		delete(services)
		return .OutOfMemory
	}
	agent.services = services

	agent.config = config
	agent.config.token = token
	agent.config.tls_ca = ca
	agent.config.tls_server_name = sni
	agent.config.implementation = implementation
	return .None
}

agent_destroy :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	agent_stop(agent)
	sync.mutex_lock(&agent.mutex)
	conn := agent.live_conn
	agent.live_conn = nil
	for id in agent.services {
		delete(string(id))
	}
	delete(agent.services)
	agent.services = {}
	sync.mutex_unlock(&agent.mutex)
	if conn != nil {
		trans.connection_destroy(conn)
	}
	delete(agent.config.token)
	delete(agent.config.tls_ca)
	delete(agent.config.tls_server_name)
	delete(agent.config.implementation)
	agent.config.token = ""
	agent.config.tls_ca = ""
	agent.config.tls_server_name = ""
	agent.config.implementation = ""
}

agent_stop :: proc(agent: ^Agent) {
	if agent == nil {
		return
	}
	sync.atomic_store(&agent.stop, true)
	sync.mutex_lock(&agent.mutex)
	conn := agent.live_conn
	connected := agent.connected
	// The session thread clears live_conn under this mutex before it destroys
	// the connection, so take a reference while we still hold it.
	if conn != nil && !trans.connection_acquire(conn) {
		conn = nil
	}
	if agent.pending != .None {
		agent_finish_pending(agent, .Stopped)
	}
	sync.cond_broadcast(&agent.cond)
	sync.mutex_unlock(&agent.mutex)
	if conn != nil {
		if !connected {
			trans.connection_close(conn)
		}
		trans.connection_release(conn)
	}
}

agent_set_live_relay :: proc(agent: ^Agent, relay: ^AgentRelay) {
	if agent == nil {
		return
	}
	sync.mutex_lock(&agent.mutex)
	agent.live_relay = relay
	sync.mutex_unlock(&agent.mutex)
}

// Stream-table length and pump threads for the connected session.
// (-1, -1) when no session relay is published.
agent_stream_load :: proc(agent: ^Agent) -> (streams: int, pumps: int) {
	if agent == nil {
		return -1, -1
	}
	sync.mutex_lock(&agent.mutex)
	relay := agent.live_relay
	sync.mutex_unlock(&agent.mutex)
	if relay == nil {
		return -1, -1
	}
	sync.mutex_lock(&relay.mutex)
	streams = len(relay.streams)
	sync.mutex_unlock(&relay.mutex)
	pumps = sync.atomic_load(&relay.live_pumps)
	return
}

agent_is_connected :: proc(agent: ^Agent) -> bool {
	if agent == nil {
		return false
	}
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	return agent.connected
}

agent_run :: proc(agent: ^Agent) -> AgentError {
	if agent == nil {
		return .InvalidConfig
	}
	attempt := 0
	for !sync.atomic_load(&agent.stop) {
		conn, derr := agent_dial(agent)
		if derr != .None {
			class := classify_dial_error(derr)
			cap_attempt := attempt
			if reconnect_class_is_permanent(class) {
				cap_attempt = 8
			}
			delay := reconnect_delay(cap_attempt, jitter_u64())
			agent_log(agent, .Info, "reconnect_scheduled", log.LogFields{reason = reconnect_class_reason(class)})
			agent_sleep(agent, delay)
			attempt += 1
			continue
		}
		agent_set_live_conn(agent, conn)

		decoder: proto.FrameDecoder
		if proto.decoder_init(&decoder) != .None {
			agent_set_live_conn(agent, nil)
			trans.connection_destroy(conn)
			return .Internal
		}

		hs := agent_handshake(agent, conn, &decoder)
		if hs != .Ok {
			if hs == .AuthFailed {
				agent_log(agent, .Warn, "auth_failed", log.LogFields{error_code = "AUTHENTICATION_FAILED"})
			} else if hs == .RateLimited {
				agent_log(agent, .Warn, LOG_EVENT_RATE_LIMITED, log.LogFields{error_code = proto.wire_error_name(.RateLimited)})
			}
			proto.decoder_destroy(&decoder)
			agent_set_live_conn(agent, nil)
			trans.connection_destroy(conn)
			if sync.atomic_load(&agent.stop) || hs == .Stopped {
				return .None
			}
			class := classify_handshake(hs)
			cap_attempt := attempt
			if reconnect_class_is_permanent(class) {
				cap_attempt = 8
			}
			delay := reconnect_delay(cap_attempt, jitter_u64())
			agent_log(agent, .Info, "reconnect_scheduled", log.LogFields{reason = reconnect_class_reason(class)})
			agent_sleep(agent, delay)
			attempt += 1
			continue
		}

		attempt = 0
		agent_log_registered(agent)
		agent_set_connected(agent, true)

		relay: AgentRelay
		relay.agent = agent
		relay.broker = conn
		relay.streams = make(map[proto.StreamId]AgentLocalStream)
		agent_set_live_relay(agent, &relay)
		reason := agent_relay_loop(&relay, &decoder)
		agent_clear_all(&relay)
		agent_set_live_relay(agent, nil)
		delete(relay.streams)
		agent_set_connected(agent, false)
		agent_clear_live(agent)
		proto.decoder_destroy(&decoder)
		agent_set_live_conn(agent, nil)
		trans.connection_destroy(conn)
		if sync.atomic_load(&agent.stop) {
			return .None
		}
		if reason != LOG_REASON_IDLE {
			agent_log(agent, .Info, "disconnected")
		}
		delay := reconnect_delay(0, jitter_u64())
		agent_log(agent, .Info, "reconnect_scheduled", log.LogFields{reason = reason})
		agent_sleep(agent, delay)
		attempt = 1
	}
	return .None
}

agent_dial :: proc(agent: ^Agent) -> (^trans.Connection, trans.TransportError) {
	if agent.config.insecure {
		return trans.connection_dial(agent.config.broker)
	}
	name := agent.config.tls_server_name
	if len(name) == 0 {
		name = net.address_to_string(agent.config.broker.address)
	}
	return trans.connection_dial_tls(
		agent.config.broker,
		trans.TlsClientConfig{ca_path = agent.config.tls_ca, server_name = name},
	)
}

agent_handshake :: proc(
	agent: ^Agent,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
) -> HandshakeResult {
	hello_payload, herr := proto.encode_hello(
		proto.Hello {
			major           = proto.PROTOCOL_MAJOR,
			minor           = proto.PROTOCOL_MINOR,
			role            = .Agent,
			capability_bits = 0,
			implementation  = agent.config.implementation,
		},
	)
	if herr != .None {
		return .Transport
	}
	defer delete(hello_payload)
	if !agent_write(conn, .Hello, hello_payload) {
		return .Transport
	}

	ack_frame, ack_ok := agent_read(conn, decoder)
	if !ack_ok || ack_frame.header.opcode != .HelloAck {
		proto.frame_destroy(&ack_frame)
		return .Transport
	}
	ack, aerr := proto.decode_hello_ack(ack_frame.payload)
	proto.frame_destroy(&ack_frame)
	if aerr != .None {
		return .Transport
	}
	delete(ack.implementation)

	tok := ([^]u8)(raw_data(agent.config.token))[:len(agent.config.token)]
	auth_payload, auerr := proto.encode_authenticate(proto.Authenticate{token = tok})
	if auerr != .None {
		return .Transport
	}
	defer delete(auth_payload)
	if !agent_write(conn, .Authenticate, auth_payload) {
		return .Transport
	}

	auth_frame, auth_ok := agent_read(conn, decoder)
	if !auth_ok {
		return .Transport
	}
	defer proto.frame_destroy(&auth_frame)
	if auth_frame.header.opcode == .AuthenticateFailed {
		fail, _ := proto.decode_wire_failure(auth_frame.payload)
		code, ok := proto.wire_error_from_u16(fail.code)
		delete(fail.diagnostic)
		if ok && code == .RateLimited {
			return .RateLimited
		}
		return .AuthFailed
	}
	if auth_frame.header.opcode != .AuthenticateOk {
		return .Transport
	}
	ok_msg, oerr := proto.decode_authenticate_ok(auth_frame.payload)
	if oerr != .None {
		return .Transport
	}
	delete(ok_msg.principal_id)

	// The broker drops this session's services when the connection closes.
	// A handshake that stopped halfway must not keep those live flags.
	agent_clear_live(agent)
	rl_attempt := 0
	for !sync.atomic_load(&agent.stop) {
		items := agent_snapshot_unregistered(agent)
		if len(items) == 0 {
			free_snapshots(items)
			break
		}
		i := 0
		for i < len(items) && !sync.atomic_load(&agent.stop) {
			item := items[i]
			reg := agent_register_one(conn, decoder, item.id)
			if reg == .RateLimited {
				// RegisterFailed RATE_LIMITED leaves the session up. Keep what
				// is already registered and retry this service.
				delay := reconnect_delay(rl_attempt + REGISTER_RATE_BACKOFF_ATTEMPT, jitter_u64())
				agent_log(agent, .Warn, LOG_EVENT_RATE_LIMITED, log.LogFields{service_id = string(item.id)})
				when ODIN_TEST {
					agent_test_note_register_backoff(agent, delay)
				}
				agent_sleep(agent, delay)
				rl_attempt += 1
				continue
			}
			if reg != .Ok {
				free_snapshots(items)
				return reg
			}
			rl_attempt = 0
			i += 1
			if !agent_has_service(agent, item.id) {
				unreg := agent_unregister_one(conn, decoder, item.id)
				if unreg != .Ok {
					free_snapshots(items)
					return unreg
				}
				continue
			}
			agent_mark_live(agent, item.id)
		}
		free_snapshots(items)
		if agent_all_live(agent) {
			break
		}
	}
	if sync.atomic_load(&agent.stop) {
		agent_unregister_owned(conn, decoder, agent)
		return .Stopped
	}
	return .Ok
}

agent_unregister_owned :: proc(
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	agent: ^Agent,
) {
	_ = trans.connection_set_recv_timeout(conn, 500 * time.Millisecond)
	items := agent_snapshot_all(agent)
	defer free_snapshots(items)
	for item in items {
		_ = agent_unregister_one(conn, decoder, item.id)
	}
}

agent_register_one :: proc(
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	service_id: proto.ServiceId,
) -> HandshakeResult {
	reg_payload, rerr := proto.encode_register(proto.Register{service_id = service_id})
	if rerr != .None {
		return .Transport
	}
	defer delete(reg_payload)
	if !agent_write(conn, .Register, reg_payload) {
		return .Transport
	}

	reg_frame, reg_ok := agent_read_control(conn, decoder, .RegisterOk, .RegisterFailed)
	if !reg_ok {
		return .Transport
	}
	defer proto.frame_destroy(&reg_frame)
	if reg_frame.header.opcode == .RegisterFailed {
		return handshake_from_register_failed(reg_frame.payload)
	}
	if reg_frame.header.opcode != .RegisterOk {
		return .Transport
	}
	reg_ok_msg, roerr := proto.decode_register_ok(reg_frame.payload)
	if roerr != .None {
		return .Transport
	}
	delete(string(reg_ok_msg.service_id))
	return .Ok
}

agent_unregister_one :: proc(
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	service_id: proto.ServiceId,
) -> HandshakeResult {
	payload, uerr := proto.encode_unregister(proto.Unregister{service_id = service_id})
	if uerr != .None {
		return .Transport
	}
	defer delete(payload)
	if !agent_write(conn, .Unregister, payload) {
		return .Transport
	}

	frame, ok := agent_read_control(conn, decoder, .UnregisterOk, .UnregisterFailed)
	if !ok {
		return .Transport
	}
	defer proto.frame_destroy(&frame)
	if frame.header.opcode == .UnregisterFailed {
		return handshake_from_register_failed(frame.payload)
	}
	if frame.header.opcode != .UnregisterOk {
		return .Transport
	}
	ok_msg, oerr := proto.decode_unregister_ok(frame.payload)
	if oerr != .None {
		return .Transport
	}
	delete(string(ok_msg.service_id))
	return .Ok
}

agent_set_live_conn :: proc(agent: ^Agent, conn: ^trans.Connection) {
	sync.mutex_lock(&agent.mutex)
	prev := agent.live_conn
	agent.live_conn = conn
	sync.mutex_unlock(&agent.mutex)
	if prev != nil && prev != conn {
		trans.connection_close(prev)
	}
}

agent_set_connected :: proc(agent: ^Agent, connected: bool) {
	sync.mutex_lock(&agent.mutex)
	agent.connected = connected
	if !connected && agent.pending != .None {
		agent_finish_pending(agent, .Transport)
	}
	sync.cond_broadcast(&agent.cond)
	sync.mutex_unlock(&agent.mutex)
}

agent_sleep :: proc(agent: ^Agent, d: time.Duration) {
	start := time.now()
	for time.since(start) < d {
		if sync.atomic_load(&agent.stop) {
			return
		}
		slice := 50 * time.Millisecond
		left := d - time.since(start)
		if left < slice {
			slice = left
		}
		if slice <= 0 {
			return
		}
		time.sleep(slice)
	}
}

agent_write :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId = proto.CONNECTION_STREAM_ID,
) -> bool {
	if conn == nil {
		return false
	}
	terr, perr := trans.write_frame(conn, opcode, payload, stream_id)
	return terr == .None && perr == .None
}

agent_read :: proc(
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
) -> (
	frame: proto.Frame,
	ok: bool,
) {
	got, terr, perr := trans.read_frame(conn, decoder)
	if terr != .None || perr != .None {
		return {}, false
	}
	return got, true
}

// Handshake request/reply read. A RATE_LIMITED wait leaves this session up
// with some services already registered, so the broker can send OPEN and
// stream frames before the next REGISTER reply. Those do not end the handshake.
// reply and failed are the opcodes this call is waiting for.
agent_read_control :: proc(
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	reply, failed: proto.Opcode,
) -> (
	frame: proto.Frame,
	ok: bool,
) {
	for {
		got, got_ok := agent_read(conn, decoder)
		if !got_ok {
			return {}, false
		}
		op := got.header.opcode
		switch op {
		case .Ping:
			msg, merr := proto.decode_ping(got.payload)
			if merr == .None {
				payload, perr := proto.encode_pong(proto.Pong{nonce = msg.nonce})
				if perr == .None {
					_ = agent_write(conn, .Pong, payload)
					delete(payload)
				}
			}
		case .Open:
			// Not in the relay yet. Refuse this stream and keep registering.
			_ = agent_write_failure(conn, .OpenFailed, .LocalServiceUnavailable, got.header.stream_id)
		case .Pong, .Data, .HalfClose, .Close, .Reset:
			// No stream is open on this handshake. Drop and keep reading.
		case .Error:
			// Broker connection-level failure. The read itself failed.
			proto.frame_destroy(&got)
			return {}, false
		case .RegisterOk, .RegisterFailed, .UnregisterOk, .UnregisterFailed:
			if op == reply || op == failed {
				return got, true
			}
		case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
		     .Register, .Unregister, .Connect, .ConnectOk, .ConnectFailed,
		     .OpenOk, .OpenFailed:
			// Not the reply in flight, and not a broken socket.
		}
		proto.frame_destroy(&got)
	}
}

agent_log :: proc(agent: ^Agent, level: log.LogLevel, event: string, fields: log.LogFields = {}) {
	log.log_event(agent.config.logger, level, event, fields)
}

agent_log_registered :: proc(agent: ^Agent) {
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	for id, svc in agent.services {
		if !svc.live {
			continue
		}
		agent_log(agent, .Info, LOG_EVENT_REGISTERED, log.LogFields{service_id = string(id)})
	}
}

jitter_u64 :: proc() -> u64 {
	buf: [8]u8
	crypto.rand_bytes(buf[:])
	v: u64
	for b in buf {
		v = (v << 8) | u64(b)
	}
	return v
}

tls_ca_readable :: proc(path: string) -> bool {
	if len(path) == 0 {
		return true
	}
	fi, err := os.stat(path, context.allocator)
	if err != nil {
		return false
	}
	os.file_info_delete(fi, context.allocator)
	return true
}
