package caller

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

caller_init :: proc(c: ^Caller, config: CallerConfig) -> CallerError {
	if c == nil {
		return .InvalidConfig
	}
	if config.broker.port == 0 || len(config.token) == 0 {
		return .InvalidConfig
	}
	if config.insecure && (len(config.tls_ca) > 0 || len(config.tls_server_name) > 0) {
		return .InvalidConfig
	}
	if !tls_ca_readable(config.tls_ca) {
		return .InvalidConfig
	}

	c^ = {}
	impl := config.implementation
	if len(impl) == 0 {
		impl = DEFAULT_IMPLEMENTATION
	}
	token, terr := strings.clone(config.token)
	if terr != .None {
		return .OutOfMemory
	}
	ca, caerr := strings.clone(config.tls_ca)
	if caerr != .None {
		delete(token)
		return .OutOfMemory
	}
	sni, snerr := strings.clone(config.tls_server_name)
	if snerr != .None {
		delete(token)
		delete(ca)
		return .OutOfMemory
	}
	implementation, ierr := strings.clone(impl)
	if ierr != .None {
		delete(token)
		delete(ca)
		delete(sni)
		return .OutOfMemory
	}
	c.config = config
	c.config.token = token
	c.config.tls_ca = ca
	c.config.tls_server_name = sni
	c.config.implementation = implementation
	c.streams = make(map[proto.StreamId]^Conn)

	conn, derr := caller_dial_broker(c)
	if derr != .None {
		caller_free_config(c)
		delete(c.streams)
		return .Transport
	}
	c.conn = conn
	if proto.decoder_init(&c.decoder) != .None {
		trans.connection_destroy(conn)
		c.conn = nil
		caller_free_config(c)
		delete(c.streams)
		return .Internal
	}
	if hs := caller_handshake(c); hs != .None {
		proto.decoder_destroy(&c.decoder)
		trans.connection_destroy(conn)
		c.conn = nil
		caller_free_config(c)
		delete(c.streams)
		return hs
	}
	c.connected = true
	c.reader = thread.create_and_start_with_poly_data(c, caller_reader_proc)
	return .None
}

caller_destroy :: proc(c: ^Caller) {
	if c == nil {
		return
	}
	sync.atomic_store(&c.stop, true)
	sync.mutex_lock(&c.mutex)
	if c.conn != nil {
		trans.connection_close(c.conn)
	}
	if c.pending != nil {
		c.pending_err = .Closed
		c.pending = nil
	}
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
	if c.reader != nil {
		thread.join(c.reader)
		thread.destroy(c.reader)
		c.reader = nil
	}
	sync.mutex_lock(&c.mutex)
	for _, stream in c.streams {
		conn_finish(stream, .Closed)
	}
	clear(&c.streams)
	sync.mutex_unlock(&c.mutex)
	delete(c.streams)
	proto.decoder_destroy(&c.decoder)
	if c.conn != nil {
		trans.connection_destroy(c.conn)
		c.conn = nil
	}
	caller_free_config(c)
}

caller_free_config :: proc(c: ^Caller) {
	delete(c.config.token)
	delete(c.config.tls_ca)
	delete(c.config.tls_server_name)
	delete(c.config.implementation)
	c.config.token = ""
	c.config.tls_ca = ""
	c.config.tls_server_name = ""
	c.config.implementation = ""
}

caller_dial_broker :: proc(c: ^Caller) -> (^trans.Connection, trans.TransportError) {
	if c.config.insecure {
		return trans.connection_dial(c.config.broker)
	}
	name := c.config.tls_server_name
	if len(name) == 0 {
		name = net.address_to_string(c.config.broker.address)
	}
	return trans.connection_dial_tls(
		c.config.broker,
		trans.TlsClientConfig{ca_path = c.config.tls_ca, server_name = name},
	)
}

caller_handshake :: proc(c: ^Caller) -> CallerError {
	hello_payload, herr := proto.encode_hello(
		proto.Hello {
			major           = proto.PROTOCOL_MAJOR,
			minor           = proto.PROTOCOL_MINOR,
			role            = .Caller,
			capability_bits = 0,
			implementation  = c.config.implementation,
		},
	)
	if herr != .None {
		return .Internal
	}
	defer delete(hello_payload)
	if !caller_write(c.conn, .Hello, hello_payload) {
		return .Transport
	}

	ack_frame, ack_ok := caller_read(c.conn, &c.decoder)
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

	tok := ([^]u8)(raw_data(c.config.token))[:len(c.config.token)]
	auth_payload, auerr := proto.encode_authenticate(proto.Authenticate{token = tok})
	if auerr != .None {
		return .Internal
	}
	defer delete(auth_payload)
	if !caller_write(c.conn, .Authenticate, auth_payload) {
		return .Transport
	}

	auth_frame, auth_ok := caller_read(c.conn, &c.decoder)
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
	return .None
}

caller_write :: proc(
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

caller_read :: proc(
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

caller_write_failure :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	code: proto.WireError,
	stream_id: proto.StreamId,
) -> bool {
	payload, err := proto.encode_wire_failure(
		proto.WireFailure{code = proto.wire_error_to_u16(code), diagnostic = ""},
	)
	if err != .None {
		return false
	}
	defer delete(payload)
	return caller_write(conn, opcode, payload, stream_id)
}

caller_reader_proc :: proc(c: ^Caller) {
	attempt := 0
	for !sync.atomic_load(&c.stop) {
		if caller_read_session(c) {
			return
		}
		if sync.atomic_load(&c.stop) {
			return
		}
		caller_log(c, .Info, "disconnected")
		if !caller_reconnect(c, &attempt) {
			return
		}
	}
}

caller_read_session :: proc(c: ^Caller) -> (stopped: bool) {
	for !sync.atomic_load(&c.stop) {
		_ = trans.connection_set_recv_timeout(c.conn, CALLER_POLL_INTERVAL)
		frame, terr, perr := trans.read_frame(c.conn, &c.decoder)
		if terr == .Timeout {
			continue
		}
		if terr != .None || perr != .None {
			caller_fail_all(c, .Transport)
			return false
		}
		switch frame.header.opcode {
		case .ConnectOk:
			caller_handle_connect_ok(c, frame.header.stream_id)
		case .ConnectFailed:
			fail, _ := proto.decode_wire_failure(frame.payload)
			code, _ := proto.wire_error_from_u16(fail.code)
			delete(fail.diagnostic)
			caller_handle_connect_failed(c, wire_to_caller_error(code))
		case .Data:
			caller_handle_data(c, frame)
		case .HalfClose:
			caller_handle_half_close(c, frame.header.stream_id)
		case .Close, .Reset:
			kind: ConnError = frame.header.opcode == .Reset ? .Reset : .Closed
			caller_handle_close(c, frame.header.stream_id, kind)
		case .Ping:
			msg, merr := proto.decode_ping(frame.payload)
			if merr == .None {
				pong, _ := proto.encode_pong(proto.Pong{nonce = msg.nonce})
				_ = caller_write(c.conn, .Pong, pong)
				delete(pong)
			}
		case .Pong:
		case .Error:
			proto.frame_destroy(&frame)
			caller_fail_all(c, .Transport)
			return false
		case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
		     .Register, .RegisterOk, .RegisterFailed, .Unregister, .UnregisterOk,
		     .UnregisterFailed, .Connect, .Open, .OpenOk, .OpenFailed:
			proto.frame_destroy(&frame)
			caller_fail_all(c, .Transport)
			return false
		}
		proto.frame_destroy(&frame)
	}
	return true
}

caller_reconnect :: proc(c: ^Caller, attempt: ^int) -> bool {
	caller_drop_conn(c)
	proto.decoder_destroy(&c.decoder)
	if proto.decoder_init(&c.decoder) != .None {
		return false
	}

	delay := reconnect_delay(0, jitter_u64())
	caller_log(c, .Info, "reconnect_scheduled", log.LogFields{reason = "disconnected"})
	caller_sleep(c, delay)
	attempt^ = 1

	for !sync.atomic_load(&c.stop) {
		conn, derr := caller_dial_broker(c)
		if derr != .None {
			cap_attempt := attempt^
			reason := "network"
			if derr == .Tls {
				reason = "tls"
				cap_attempt = 8
			} else if derr == .InvalidEndpoint {
				reason = "configuration"
				cap_attempt = 8
			}
			caller_log(c, .Info, "reconnect_scheduled", log.LogFields{reason = reason})
			caller_sleep(c, reconnect_delay(cap_attempt, jitter_u64()))
			attempt^ += 1
			continue
		}
		caller_set_conn(c, conn)
		hs := caller_handshake(c)
		if hs == .None {
			sync.mutex_lock(&c.mutex)
			c.connected = true
			sync.cond_broadcast(&c.cond)
			sync.mutex_unlock(&c.mutex)
			attempt^ = 0
			return true
		}
		caller_drop_conn(c)
		cap_attempt := attempt^
		reason := "broker_unavailable"
		if hs == .AuthFailed {
			caller_log(c, .Warn, "auth_failed", log.LogFields{error_code = "AUTHENTICATION_FAILED"})
			reason = "authentication"
			cap_attempt = 8
		} else if hs == .RateLimited {
			caller_log(c, .Warn, "auth_failed", log.LogFields{error_code = "RATE_LIMITED"})
			reason = "rate_limited"
		}
		if sync.atomic_load(&c.stop) {
			return false
		}
		caller_log(c, .Info, "reconnect_scheduled", log.LogFields{reason = reason})
		caller_sleep(c, reconnect_delay(cap_attempt, jitter_u64()))
		attempt^ += 1
	}
	return false
}

caller_set_conn :: proc(c: ^Caller, conn: ^trans.Connection) {
	sync.mutex_lock(&c.mutex)
	prev := c.conn
	c.conn = conn
	sync.mutex_unlock(&c.mutex)
	if prev != nil && prev != conn {
		trans.connection_destroy(prev)
	}
}

caller_drop_conn :: proc(c: ^Caller) {
	caller_set_conn(c, nil)
}

caller_sleep :: proc(c: ^Caller, d: time.Duration) {
	start := time.now()
	for time.since(start) < d {
		if sync.atomic_load(&c.stop) {
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

caller_log :: proc(c: ^Caller, level: log.LogLevel, event: string, fields: log.LogFields = {}) {
	log.log_event(c.config.logger, level, event, fields)
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

caller_handle_connect_ok :: proc(c: ^Caller, stream_id: proto.StreamId) {
	sync.mutex_lock(&c.mutex)
	pending := c.pending
	c.pending = nil
	if pending != nil {
		pending.stream_id = stream_id
		c.streams[stream_id] = pending
		c.pending_err = .None
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mutex)
		return
	}
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
	_ = caller_write_failure(c.conn, .Reset, .Timeout, stream_id)
}

caller_handle_connect_failed :: proc(c: ^Caller, err: CallerError) {
	sync.mutex_lock(&c.mutex)
	c.pending = nil
	c.pending_err = err
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
}

caller_handle_data :: proc(c: ^Caller, frame: proto.Frame) {
	sync.mutex_lock(&c.mutex)
	stream, found := c.streams[frame.header.stream_id]
	sync.mutex_unlock(&c.mutex)
	if !found || stream == nil {
		_ = caller_write_failure(c.conn, .Reset, .StreamNotFound, frame.header.stream_id)
		return
	}
	conn_push_inbound(stream, frame.payload)
}

caller_handle_half_close :: proc(c: ^Caller, stream_id: proto.StreamId) {
	sync.mutex_lock(&c.mutex)
	stream, found := c.streams[stream_id]
	sync.mutex_unlock(&c.mutex)
	if !found || stream == nil {
		_ = caller_write_failure(c.conn, .Reset, .StreamNotFound, stream_id)
		return
	}
	conn_set_eof(stream)
}

caller_handle_close :: proc(c: ^Caller, stream_id: proto.StreamId, kind: ConnError) {
	sync.mutex_lock(&c.mutex)
	stream, found := c.streams[stream_id]
	if found {
		delete_key(&c.streams, stream_id)
	}
	sync.mutex_unlock(&c.mutex)
	if found && stream != nil {
		conn_finish(stream, kind)
	} else {
		_ = caller_write_failure(c.conn, .Reset, .StreamNotFound, stream_id)
	}
}

caller_fail_all :: proc(c: ^Caller, err: CallerError) {
	sync.mutex_lock(&c.mutex)
	c.connected = false
	if c.pending != nil {
		c.pending_err = err
		c.pending = nil
	}
	taken := make([dynamic]^Conn)
	for _, stream in c.streams {
		append(&taken, stream)
	}
	clear(&c.streams)
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
	for stream in taken {
		conn_finish(stream, err == .Transport ? .Transport : .Closed)
	}
	delete(taken)
}

wire_to_caller_error :: proc(code: proto.WireError) -> CallerError {
	switch code {
	case .None:
		return .None
	case .ServiceNotFound:
		return .ServiceNotFound
	case .Unauthorized:
		return .Unauthorized
	case .AgentUnavailable:
		return .AgentUnavailable
	case .QuotaExceeded:
		return .QuotaExceeded
	case .BrokerDraining:
		return .BrokerDraining
	case .AuthenticationFailed:
		return .AuthFailed
	case .InvalidServiceId:
		return .InvalidServiceId
	case .Timeout:
		return .Timeout
	case .RateLimited:
		return .RateLimited
	case .LocalServiceUnavailable:
		return .LocalServiceUnavailable
	case .ProtocolError, .UnsupportedVersion, .ServiceAlreadyRegistered,
	     .StreamNotFound, .StreamAlreadyExists, .FrameTooLarge, .InternalError:
		return .Internal
	}
	return .Internal
}
