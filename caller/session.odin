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
		c.streams = nil
		return .Transport
	}
	c.conn = conn
	if proto.decoder_init(&c.decoder) != .None {
		trans.connection_destroy(conn)
		c.conn = nil
		caller_free_config(c)
		delete(c.streams)
		c.streams = nil
		return .Internal
	}
	// Handshake writes Hello and Authenticate through the session queue.
	caller_bind_session(c, conn)
	if hs := caller_handshake(c); hs != .None {
		caller_unbind_session(conn)
		caller_delete_queues(c)
		proto.decoder_destroy(&c.decoder)
		trans.connection_destroy(conn)
		c.conn = nil
		caller_free_config(c)
		delete(c.streams)
		c.streams = nil
		return hs
	}
	if !caller_start_stall(c) {
		caller_unbind_session(conn)
		caller_delete_queues(c)
		proto.decoder_destroy(&c.decoder)
		trans.connection_destroy(conn)
		c.conn = nil
		caller_free_config(c)
		delete(c.streams)
		c.streams = nil
		return .Internal
	}
	c.last_recv = time.now()
	c.connected = true
	c.reader = thread.create_and_start_with_poly_data(c, caller_reader_proc)
	if c.reader == nil {
		caller_stop_stall(c)
		caller_unbind_session(conn)
		caller_delete_queues(c)
		proto.decoder_destroy(&c.decoder)
		trans.connection_destroy(conn)
		c.conn = nil
		caller_free_config(c)
		delete(c.streams)
		c.streams = nil
		return .Internal
	}
	return .None
}

caller_destroy :: proc(c: ^Caller) {
	if c == nil {
		return
	}
	sync.atomic_store(&c.stop, true)
	sync.mutex_lock(&c.mutex)
	if c.conn != nil {
		// Wake the reader without freeing TLS under it. connection_close
		// here freed conn.tls while the reader sat in SSL_read, and the
		// reader's mutex_unlock(&conn.tls.mutex) then hit a nil session
		// (thirp-connect SIGSEGV on exit, e.g. listen port in use). The
		// reader is joined below; connection_destroy runs after that.
		trans.connection_shutdown_both(c.conn)
	}
	caller_signal_drains(c)
	if c.pending != nil {
		c.pending_err = .Closed
		c.pending = nil
	}
	c.pending_tombstone = false
	c.tombstone_capped = false
	// End every stream before the join so owners wake at once. Take them
	// out of the table first (with a reference), as caller_fail_all does:
	// a finished stream left in the table is freed by its owner's
	// conn_destroy (conn_close returns early once closed, so it never
	// removes the entry) and the reader then double-freed it.
	caller_take_and_finish_all(c)
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
	if c.reader != nil {
		thread.join(c.reader)
		thread.destroy(c.reader)
		c.reader = nil
	}
	sync.mutex_lock(&c.mutex)
	for sync.atomic_load(&c.drain_live) != 0 {
		sync.cond_wait(&c.cond, &c.mutex)
	}
	delete(c.drains)
	c.drains = nil
	sync.mutex_unlock(&c.mutex)
	caller_stop_stall(c)
	// Reconnect may have installed a socket after the shutdown above.
	sync.mutex_lock(&c.mutex)
	if c.conn != nil {
		trans.connection_shutdown_both(c.conn)
	}
	caller_take_and_finish_all(c)
	sync.mutex_unlock(&c.mutex)
	caller_close_writes(c)
	sync.mutex_lock(&c.mutex)
	prev := c.conn
	c.conn = nil
	sync.mutex_unlock(&c.mutex)
	if prev != nil {
		caller_unbind_session(prev)
		trans.connection_destroy(prev)
	}
	caller_delete_queues(c)
	delete(c.streams)
	c.streams = nil
	proto.decoder_destroy(&c.decoder)
	caller_free_config(c)
}

// Caller holds c.mutex. Empties the stream table and finishes each stream
// it held. A finished stream is never left in the table.
caller_take_and_finish_all :: proc(c: ^Caller) {
	if len(c.streams) == 0 {
		return
	}
	taken := make([dynamic]^Conn, 0, len(c.streams))
	defer delete(taken)
	for _, stream in c.streams {
		if stream != nil {
			conn_acquire(stream)
			append(&taken, stream)
		}
	}
	clear(&c.streams)
	for stream in taken {
		// conn.mutex nests inside c.mutex here, the same order as
		// conn_close (which never holds both).
		conn_finish(stream, .Closed)
		conn_release(stream)
	}
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
	conn: ^trans.Connection
	derr: trans.TransportError
	if c.config.insecure {
		conn, derr = trans.connection_dial(c.config.broker)
	} else {
		name := c.config.tls_server_name
		if len(name) == 0 {
			name = net.address_to_string(c.config.broker.address)
		}
		conn, derr = trans.connection_dial_tls(
			c.config.broker,
			trans.TlsClientConfig{ca_path = c.config.tls_ca, server_name = name},
		)
	}
	if derr == .None {
		caller_set_user_timeout(conn)
	}
	return conn, derr
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
		end := caller_read_session(c)
		if end == .Stopped || sync.atomic_load(&c.stop) {
			return
		}
		// Retire the socket before the log consumes disconnect_reason.
		// A dial failing in between must see conn_gen move. It does not
		// hold a reference on the old connection, so it cannot look at it.
		// A retire has already parked that socket; this only bumps gen.
		caller_drop_conn(c)
		if end == .Dropped {
			reason := caller_take_disconnect_reason(c)
			when ODIN_TEST {
				sync.mutex_lock(&c.mutex)
				c.last_disconnect_reason = reason
				sync.mutex_unlock(&c.mutex)
			}
			caller_log(
				c,
				.Info,
				LOG_EVENT_DISCONNECTED,
				log.LogFields {
					streams     = c.dropped_streams,
					streams_set = true,
					reason      = reason,
				},
			)
		}
		if !caller_reconnect(c, &attempt) {
			return
		}
	}
}

caller_read_session :: proc(c: ^Caller) -> SessionRead {
	for !sync.atomic_load(&c.stop) {
		if caller_read_idle(c) {
			return .Dropped
		}
		switch caller_expire_tombstone(c) {
		case .Dropped:
			return .Dropped
		case .Retired:
			return .Retired
		case .Continue, .Stopped:
		}
		caller_maybe_ping(c, c.conn, c.last_recv, &c.last_ping)
		_ = trans.connection_set_recv_timeout(c.conn, CALLER_POLL_INTERVAL)
		frame, terr, perr := trans.read_frame(c.conn, &c.decoder)
		if terr == .Timeout {
			continue
		}
		if terr != .None || perr != .None {
			// TCP_USER_TIMEOUT aborts an unacked Ping before the idle
			// watchdog. A clean FIN leaves the flag clear (recv 0 does
			// not update errno), so that stays peer_close.
			if trans.connection_user_timed_out(c.conn) {
				caller_note_disconnect(c, LOG_REASON_DEAD_PEER)
			}
			caller_finish_disconnect_reason(c, terr, perr)
			caller_fail_all(c, .Transport)
			return .Dropped
		}
		caller_note_recv(c)
		end := caller_handle_frame(c, &c.streams, c.conn, c.conn_gen, nil, frame)
		proto.frame_destroy(&frame)
		if end != .Continue {
			return end
		}
	}
	return .Stopped
}

caller_reconnect :: proc(c: ^Caller, attempt: ^int) -> bool {
	// The reader already dropped the dead socket, before it cleared
	// disconnect_reason. Dropping again would only bump conn_gen.
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
			c.last_recv = time.now()
			c.last_ping = {}
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
	c.conn_gen += 1
	sync.mutex_unlock(&c.mutex)
	if prev != nil && prev != conn {
		// A DATA send may still be inside write_frame on this socket.
		// Unbind so new frames miss it, shut it down so that send returns,
		// then wait until the drainer has left before freeing it.
		caller_unbind_session(prev)
		trans.connection_shutdown_both(prev)
		caller_wait_writes(c)
		trans.connection_destroy(prev)
	}
	if conn != nil {
		caller_bind_session(c, conn)
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

// One warning. Ingress and thirp-connect call this at startup. A dial
// timeout under DIAL_TIMEOUT_WARN_BELOW still waits out TOMBSTONE_CAP_FLOOR
// before a retire. The floor does not stop the agent's serial local dial
// (default 5s) from holding the head of the line: at 2s or below, a
// healthy service stays blocked until that local dial fails. Do not set
// --broker-dial-timeout below 6s. The default is 10s.
caller_warn_short_dial_timeout :: proc(logger: ^log.Logger, dial_timeout: time.Duration) {
	if dial_timeout <= 0 || dial_timeout >= DIAL_TIMEOUT_WARN_BELOW {
		return
	}
	log.log_event(
		logger,
		.Warn,
		LOG_EVENT_DIAL_TIMEOUT_SHORT,
		log.LogFields {
			reason          = LOG_REASON_DIAL_TIMEOUT,
			dial_timeout_ms = int(dial_timeout / time.Millisecond),
			cap_floor_ms    = int(TOMBSTONE_CAP_FLOOR / time.Millisecond),
		},
	)
}

caller_read_idle_limit :: proc(c: ^Caller) -> time.Duration {
	when ODIN_TEST {
		if c != nil && c.config.read_idle_timeout > 0 {
			return c.config.read_idle_timeout
		}
	}
	return READ_IDLE_TIMEOUT
}

caller_ping_interval :: proc(c: ^Caller) -> time.Duration {
	when ODIN_TEST {
		if c != nil && c.config.ping_interval > 0 {
			return c.config.ping_interval
		}
	}
	return CALLER_PING_INTERVAL
}

// Send Ping when the broker has been quiet for a ping interval. Does not
// move last_recv: only the Pong, or any other frame, does. A failed write
// leaves last_ping alone so the next poll tries again.
caller_maybe_ping :: proc(c: ^Caller, conn: ^trans.Connection, last_recv: time.Time, last_ping: ^time.Time) {
	if c == nil || conn == nil || last_ping == nil {
		return
	}
	interval := caller_ping_interval(c)
	if interval <= 0 {
		return
	}
	if time.since(last_recv) < interval || time.since(last_ping^) < interval {
		return
	}
	payload, err := proto.encode_ping(proto.Ping{nonce = jitter_u64()})
	if err != .None {
		return
	}
	defer delete(payload)
	if caller_write(conn, .Ping, payload) {
		last_ping^ = time.now()
	}
}

// One dispatcher for the live session and a retired drain. drain == nil is
// the live session. The caller destroys the frame.
caller_handle_frame :: proc(
	c: ^Caller,
	streams: ^map[proto.StreamId]^Conn,
	conn: ^trans.Connection,
	gen: int,
	drain: ^CallerDrain,
	frame: proto.Frame,
) -> SessionRead {
	switch frame.header.opcode {
	case .ConnectOk:
		if drain != nil {
			sync.mutex_lock(&c.mutex)
			held := false
			dconn := drain.conn
			if drain.tombstone && dconn != nil && !drain.closed && drain.gen == gen {
				drain.tombstone = false
				held = trans.connection_acquire(dconn)
			}
			sync.mutex_unlock(&c.mutex)
			if held {
				caller_reset_enqueue(c, dconn, gen, frame.header.stream_id)
			}
			return .Continue
		}
		caller_handle_connect_ok(c, frame.header.stream_id)
	case .ConnectFailed:
		if drain != nil {
			sync.mutex_lock(&c.mutex)
			drain.tombstone = false
			sync.mutex_unlock(&c.mutex)
			return .Continue
		}
		fail, _ := proto.decode_wire_failure(frame.payload)
		code, _ := proto.wire_error_from_u16(fail.code)
		delete(fail.diagnostic)
		caller_handle_connect_failed(c, wire_to_caller_error(code))
	case .Data:
		caller_handle_data(c, streams, conn, frame)
	case .HalfClose:
		caller_handle_half_close(c, streams, frame.header.stream_id)
	case .Close, .Reset:
		kind: ConnError = frame.header.opcode == .Reset ? .Reset : .Closed
		caller_handle_close(c, streams, frame.header.stream_id, kind, frame.payload)
	case .Ping:
		msg, merr := proto.decode_ping(frame.payload)
		if merr == .None {
			pong, _ := proto.encode_pong(proto.Pong{nonce = msg.nonce})
			_ = caller_write(conn, .Pong, pong)
			delete(pong)
		}
	case .Pong:
	case .Error, .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
	     .Register, .RegisterOk, .RegisterFailed, .Unregister, .UnregisterOk,
	     .UnregisterFailed, .Connect, .Open, .OpenOk, .OpenFailed:
		if drain != nil {
			sync.mutex_lock(&c.mutex)
			drain.stop = true
			sync.mutex_unlock(&c.mutex)
			return .Continue
		}
		caller_note_disconnect(c, LOG_REASON_ERROR)
		caller_fail_all(c, .Transport)
		return .Dropped
	}
	return .Continue
}

// First cause wins. The stall timer sets this before it shuts the socket;
// a later read error must not relabel that as a peer close.
caller_note_disconnect :: proc(c: ^Caller, reason: string) {
	if c == nil || len(reason) == 0 {
		return
	}
	sync.mutex_lock(&c.mutex)
	if len(c.disconnect_reason) == 0 {
		c.disconnect_reason = reason
	}
	sync.mutex_unlock(&c.mutex)
}

// Fill the reason from the read that ended the session, if nothing earlier
// (the stall timer) already named the cause.
caller_finish_disconnect_reason :: proc(c: ^Caller, terr: trans.TransportError, perr: proto.ProtocolError) {
	sync.mutex_lock(&c.mutex)
	if len(c.disconnect_reason) == 0 {
		if terr == .Closed && perr == .None {
			c.disconnect_reason = LOG_REASON_PEER_CLOSE
		} else {
			c.disconnect_reason = LOG_REASON_ERROR
		}
	}
	sync.mutex_unlock(&c.mutex)
}

when ODIN_TEST {
	caller_last_disconnect_reason :: proc(c: ^Caller) -> string {
		if c == nil {
			return ""
		}
		sync.mutex_lock(&c.mutex)
		defer sync.mutex_unlock(&c.mutex)
		return c.last_disconnect_reason
	}
}

caller_take_disconnect_reason :: proc(c: ^Caller) -> string {
	sync.mutex_lock(&c.mutex)
	reason := c.disconnect_reason
	c.disconnect_reason = ""
	sync.mutex_unlock(&c.mutex)
	if len(reason) == 0 {
		return LOG_REASON_ERROR
	}
	return reason
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
	conn := c.conn
	gen := c.conn_gen
	held := conn != nil && trans.connection_acquire(conn)
	// The dial that sent this CONNECT already gave up. RESET the stream.
	// Do not bind it to whoever is waiting for the slot next.
	if c.pending_tombstone {
		c.pending_tombstone = false
		c.tombstone_capped = false
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mutex)
		if held {
			caller_reset_enqueue(c, conn, gen, stream_id)
		}
		return
	}
	pending := c.pending
	c.pending = nil
	if pending != nil {
		pending.stream_id = stream_id
		pending.accepted = true
		c.streams[stream_id] = pending
		c.pending_err = .None
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mutex)
		if held {
			trans.connection_release(conn)
		}
		return
	}
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
	if held {
		caller_reset_enqueue(c, conn, gen, stream_id)
	}
}

caller_handle_connect_failed :: proc(c: ^Caller, err: CallerError) {
	sync.mutex_lock(&c.mutex)
	if c.pending_tombstone {
		c.pending_tombstone = false
		c.tombstone_capped = false
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mutex)
		return
	}
	c.pending = nil
	c.pending_err = err
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
}

// Takes ownership of the reference on conn. Posts a control RESET on the
// session writer and returns. The writer sends it only if this socket is
// still that generation (the live session or the drain parked from it),
// then releases the reference. The reader does not wait.
caller_reset_enqueue :: proc(c: ^Caller, conn: ^trans.Connection, gen: int, stream_id: proto.StreamId) {
	if c == nil || conn == nil {
		if conn != nil {
			trans.connection_release(conn)
		}
		return
	}
	payload, err := proto.encode_wire_failure(
		proto.WireFailure{code = proto.wire_error_to_u16(.Timeout), diagnostic = ""},
	)
	if err != .None {
		trans.connection_release(conn)
		return
	}
	defer delete(payload)
	job := caller_enqueue(c, conn, .Reset, payload, stream_id, gen, false, true)
	if job == nil {
		trans.connection_release(conn)
	}
}

// Holds c.mutex. The socket the CONNECT_OK arrived on, not whichever
// session is current after a retire or a reconnect.
caller_reset_targets :: proc(c: ^Caller, conn: ^trans.Connection, gen: int) -> bool {
	if conn == nil {
		return false
	}
	if c.conn == conn && c.conn_gen == gen {
		return true
	}
	for d in c.drains {
		if d != nil && !d.closed && d.conn == conn && d.gen == gen {
			return true
		}
	}
	return false
}

// The tombstone has waited TOMBSTONE_DIAL_TIMEOUTS past the dial timeout.
// With no live streams, drop the session. With live streams, park this
// socket and let the reader open another for new dials. A second caller
// session from the same identity is accepted by the broker, so the parked
// one is not kicked.
caller_expire_tombstone :: proc(c: ^Caller) -> SessionRead {
	sync.mutex_lock(&c.mutex)
	if !c.pending_tombstone || !c.tombstone_capped || time.diff(time.now(), c.tombstone_deadline) > 0 {
		sync.mutex_unlock(&c.mutex)
		return .Continue
	}
	if len(c.streams) > 0 && c.conn != nil {
		nstreams := len(c.streams)
		d := caller_park_drain(c)
		sync.mutex_unlock(&c.mutex)
		if d == nil {
			caller_fail_all(c, .Transport)
			return .Dropped
		}
		caller_log(
			c,
			.Info,
			LOG_EVENT_SESSION_RETIRED,
			log.LogFields {
				streams     = nstreams,
				streams_set = true,
				reason      = LOG_REASON_TOMBSTONE,
			},
		)
		sync.atomic_add(&c.drain_live, 1)
		thread.run_with_poly_data(d, caller_drain_proc)
		return .Retired
	}
	if len(c.disconnect_reason) == 0 {
		c.disconnect_reason = LOG_REASON_TOMBSTONE
	}
	conn := c.conn
	held := conn != nil && trans.connection_acquire(conn)
	sync.mutex_unlock(&c.mutex)
	if held {
		trans.connection_shutdown_both(conn)
		trans.connection_release(conn)
	}
	caller_fail_all(c, .Transport)
	return .Dropped
}

caller_note_recv :: proc(c: ^Caller) {
	sync.mutex_lock(&c.mutex)
	c.last_recv = time.now()
	c.recv_gen += 1
	sync.mutex_unlock(&c.mutex)
}

// No frame from the broker for the read-idle limit. Shut the socket down
// so the reader reconnects. Poll timeouts and our own Ping do not count.
caller_read_idle :: proc(c: ^Caller) -> bool {
	sync.mutex_lock(&c.mutex)
	if c.conn == nil || time.since(c.last_recv) < caller_read_idle_limit(c) {
		sync.mutex_unlock(&c.mutex)
		return false
	}
	if len(c.disconnect_reason) == 0 {
		c.disconnect_reason = LOG_REASON_IDLE
	}
	conn := c.conn
	held := trans.connection_acquire(conn)
	sync.mutex_unlock(&c.mutex)
	if held {
		trans.connection_shutdown_both(conn)
		trans.connection_release(conn)
	}
	caller_fail_all(c, .Transport)
	return true
}

// Looks a stream up for the session reader and takes a reference, so the
// owner's conn_destroy cannot free it while the reader is using it.
caller_acquire_stream :: proc(c: ^Caller, streams: ^map[proto.StreamId]^Conn, stream_id: proto.StreamId) -> ^Conn {
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	if streams == nil {
		return nil
	}
	stream, found := streams[stream_id]
	if !found || stream == nil {
		return nil
	}
	conn_acquire(stream)
	return stream
}

// Streams still in the table. Tests use this to see a leak; the session
// reader and the owners are the only other users, and they take c.mutex.
caller_stream_load :: proc(c: ^Caller) -> int {
	if c == nil {
		return -1
	}
	sync.mutex_lock(&c.mutex)
	defer sync.mutex_unlock(&c.mutex)
	return len(c.streams)
}

caller_stream_buffer_cap :: proc(c: ^Caller) -> int {
	if c.config.max_stream_buffer > 0 {
		return c.config.max_stream_buffer
	}
	return CONN_INBOUND_CAP
}

caller_handle_data :: proc(
	c: ^Caller,
	streams: ^map[proto.StreamId]^Conn,
	sock: ^trans.Connection,
	frame: proto.Frame,
) {
	stream := caller_acquire_stream(c, streams, frame.header.stream_id)
	if stream == nil {
		// Finished or never bound. Do not RESET StreamNotFound —
		// the broker answers the same code and the pair hot-loops
		// for the rest of the caller session (field: ~383k/s idle).
		return
	}
	defer conn_release(stream)
	if conn_push_inbound(stream, frame.payload, caller_stream_buffer_cap(c)) {
		return
	}
	// The consumer is a full buffer behind. Waiting would hold the one
	// session reader (no other stream gets DATA, no dial sees CONNECT_OK) and,
	// through the broker's full queue for this stream, the Agent session that
	// serves every other caller. Reset only this stream.
	sync.mutex_lock(&c.mutex)
	owned := streams != nil && streams[frame.header.stream_id] == stream
	if owned {
		delete_key(streams, frame.header.stream_id)
	}
	sync.mutex_unlock(&c.mutex)
	if !owned {
		return
	}
	conn_finish(stream, .Reset)
	caller_log(
		c,
		.Warn,
		LOG_EVENT_STREAM_RESET,
		log.LogFields{stream_id = u64(frame.header.stream_id), reason = LOG_REASON_STREAM_BUFFER_FULL},
	)
	if sock != nil {
		_ = caller_write_failure(sock, .Reset, .InternalError, frame.header.stream_id)
	}
}

caller_handle_half_close :: proc(c: ^Caller, streams: ^map[proto.StreamId]^Conn, stream_id: proto.StreamId) {
	stream := caller_acquire_stream(c, streams, stream_id)
	if stream == nil {
		return
	}
	conn_set_eof(stream)
	conn_release(stream)
}

caller_handle_close :: proc(
	c: ^Caller,
	streams: ^map[proto.StreamId]^Conn,
	stream_id: proto.StreamId,
	kind: ConnError,
	payload: []u8 = nil,
) {
	sync.mutex_lock(&c.mutex)
	stream: ^Conn
	found := false
	if streams != nil {
		stream, found = streams[stream_id]
		if found {
			delete_key(streams, stream_id)
			if stream != nil {
				conn_acquire(stream)
			}
		}
	}
	sync.mutex_unlock(&c.mutex)
	if found && stream != nil {
		// Only a stream this session still owned. A RESET for one we
		// already dropped must not be logged or echoed: that pair is
		// the stream_not_found hot loop.
		if kind == .Reset {
			caller_log_peer_reset(c, stream_id, payload)
		}
		conn_finish(stream, kind)
		conn_release(stream)
	}
}

// Peer RESET for a live stream. error_code is the wire name; the
// diagnostic text is dropped so a payload or token cannot land in the log.
caller_log_peer_reset :: proc(c: ^Caller, stream_id: proto.StreamId, payload: []u8) {
	error_code := ""
	fail, derr := proto.decode_wire_failure(payload)
	if derr == .None {
		if wire, ok := proto.wire_error_from_u16(fail.code); ok {
			error_code = proto.wire_error_name(wire)
		}
		delete(fail.diagnostic)
	}
	caller_log(
		c,
		.Warn,
		LOG_EVENT_STREAM_RESET,
		log.LogFields {
			stream_id  = u64(stream_id),
			error_code = error_code,
			reason     = LOG_REASON_PEER,
		},
	)
}

caller_fail_all :: proc(c: ^Caller, err: CallerError) {
	sync.mutex_lock(&c.mutex)
	c.connected = false
	c.dropped_streams = len(c.streams)
	if c.pending != nil {
		c.pending_err = err
		c.pending = nil
	}
	c.pending_tombstone = false
	c.tombstone_capped = false
	taken := make([dynamic]^Conn)
	for _, stream in c.streams {
		conn_acquire(stream)
		append(&taken, stream)
	}
	clear(&c.streams)
	sync.cond_broadcast(&c.cond)
	sync.mutex_unlock(&c.mutex)
	for stream in taken {
		conn_finish(stream, err == .Transport ? .Transport : .Closed)
		conn_release(stream)
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
