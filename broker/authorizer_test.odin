package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

FixtureAuthz :: struct {
	allow_service: string,
}

fixture_authorize_register :: proc(ctx: rawptr, req: RegisterAuthzRequest) -> (AuthzDecision, AuthzError) {
	f := (^FixtureAuthz)(ctx)
	d: AuthzDecision
	d.organization_id = string(req.principal.organization)
	d.environment_id = req.environment_id
	if f != nil && string(req.service_id) == f.allow_service {
		d.allowed = true
		return d, .None
	}
	d.reason = .Namespace
	return d, .None
}

fixture_authorize_connect_deny :: proc(ctx: rawptr, req: ConnectAuthzRequest) -> (AuthzDecision, AuthzError) {
	_ = ctx
	_ = req
	return AuthzDecision{reason = .Unauthorized}, .None
}

unavailable_authorize_register :: proc(ctx: rawptr, req: RegisterAuthzRequest) -> (AuthzDecision, AuthzError) {
	_ = ctx
	_ = req
	return {}, .Unavailable
}

ObserverLog :: struct {
	mutex:     sync.Mutex,
	allocator: mem.Allocator,
	kinds:     [dynamic]RegistrationEventKind,
	services:  [dynamic]string,
}

observer_log_init :: proc(log: ^ObserverLog, allocator := context.allocator) {
	log^ = {}
	log.allocator = allocator
	log.kinds = make([dynamic]RegistrationEventKind, allocator)
	log.services = make([dynamic]string, allocator)
}

observer_log_destroy :: proc(log: ^ObserverLog) {
	for s in log.services {
		delete(s, log.allocator)
	}
	delete(log.kinds)
	delete(log.services)
}

observe_registration :: proc(ctx: rawptr, ev: RegistrationEvent) {
	log := (^ObserverLog)(ctx)
	if log == nil {
		return
	}
	sync.mutex_lock(&log.mutex)
	defer sync.mutex_unlock(&log.mutex)
	append(&log.kinds, ev.kind)
	cloned, err := strings.clone(string(ev.service_id), log.allocator)
	if err == .None {
		append(&log.services, cloned)
	}
}

@(test)
test_authorizer_register_allow_and_deny :: proc(t: ^testing.T) {
	fx := FixtureAuthz {
		allow_service = SITE_SERVICE,
	}
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.authorizer = Authorizer {
		ctx                = &fx,
		authorize_register = fixture_authorize_register,
		authorize_connect  = fixture_authorize_connect_deny,
	}

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, SITE_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
	testing.expect_value(t, service_count(&reg), 1)

	send_register(t, conn, OTHER_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_static_policy_authorizer_matches_file_grants :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.authorizer = static_policy_authorizer(&server.policy)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, SITE_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)

	send_register(t, conn, OTHER_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)
}

@(test)
test_authorizer_unavailable_fails_closed :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.may_register = may_register_allow_all
	server.authorizer = Authorizer {
		authorize_register = unavailable_authorize_register,
	}

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_registration_observer_register_and_unregister :: proc(t: ^testing.T) {
	log: ObserverLog
	observer_log_init(&log)
	defer observer_log_destroy(&log)
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.registration_observer_ctx = &log
	server.registration_observer = observe_registration

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)

	send_unregister(t, conn, TEST_SERVICE)
	unreg := must_read_opcode(t, conn, &decoder, .UnregisterOk)
	delete(string((proto.decode_unregister_ok(unreg.payload) or_else proto.UnregisterOk{}).service_id))
	proto.frame_destroy(&unreg)

	testing.expect_value(t, len(log.kinds), 2)
	testing.expect_value(t, log.kinds[0], RegistrationEventKind.Registered)
	testing.expect_value(t, log.kinds[1], RegistrationEventKind.Unregistered)
	testing.expect_value(t, log.services[0], TEST_SERVICE)
	testing.expect_value(t, log.services[1], TEST_SERVICE)
}

@(test)
test_server_disconnect_credential_closes_agent_session :: proc(t: ^testing.T) {
	ephemeral := EphemeralAuth {
		token = "managed-token",
		id    = "managed-host",
		org   = "org/dev",
	}
	reg: Registry
	server: Server
	must_init_registry(t, &reg)
	server_init(
		&server,
		&reg,
		auth.Authenticator{ctx = &ephemeral, authenticate = authenticate_ephemeral},
	)
	server_disable_test_hardening(&server)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
	testing.expect_value(t, server_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_start(&server)
	defer {
		server_stop(&server)
		_ = server_wait_idle(&server, 2 * time.Second)
		server_destroy(&server)
		registry_destroy(&reg)
	}

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&decoder)
	send_hello(t, conn, .Agent, proto.PROTOCOL_MAJOR)
	ack := must_read_opcode(t, conn, &decoder, .HelloAck)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)
	send_authenticate(t, conn, ephemeral.token)
	ok_auth := must_read_opcode(t, conn, &decoder, .AuthenticateOk)
	ok_msg, oerr := proto.decode_authenticate_ok(ok_auth.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_auth)

	send_register(t, conn, TEST_SERVICE)
	ok_reg := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_reg.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_reg)
	testing.expect_value(t, service_count(&reg), 1)

	server_disconnect_credential(&server, "cred-1")
	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		if service_count(&reg) == 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, service_count(&reg), 0)
}

GRANT_A :: "grant-a"
GRANT_B :: "grant-b"

FixtureConnectAuthz :: struct {
	grant_a: string,
	grant_b: string,
	lease_a: time.Duration,
	lease_b: time.Duration,
	valid_a: time.Duration,
	valid_b: time.Duration,
}

fixture_authorize_connect_grants :: proc(ctx: rawptr, req: ConnectAuthzRequest) -> (AuthzDecision, AuthzError) {
	f := (^FixtureConnectAuthz)(ctx)
	d: AuthzDecision
	d.organization_id = string(req.principal.organization)
	now := time.now()
	grant := ""
	lease := time.Duration(0)
	valid := time.Duration(0)
	switch string(req.principal.id) {
	case PRINCIPAL_CALLER:
		if f != nil {
			grant = f.grant_a
			lease = f.lease_a
			valid = f.valid_a
		}
	case PRINCIPAL_CALLER_B:
		if f != nil {
			grant = f.grant_b
			lease = f.lease_b
			valid = f.valid_b
		}
	}
	if len(grant) == 0 {
		d.reason = .Unauthorized
		return d, .None
	}
	d.allowed = true
	d.access_grant_id = grant
	if valid > 0 {
		d.valid_until = time.Time{_nsec = now._nsec + i64(valid)}
	}
	if lease > 0 {
		d.authorization_lease_until = time.Time{_nsec = now._nsec + i64(lease)}
	}
	return d, .None
}

add_caller_b :: proc(t: ^testing.T, store: ^auth.StaticTokenAuth, loc := #caller_location) {
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_CALLER_B, PRINCIPAL_CALLER_B), auth.AuthError.None, loc)
}

@(test)
test_authorizer_connect_allow_and_deny :: proc(t: ^testing.T) {
	fx := FixtureConnectAuthz {
		grant_a = GRANT_A,
		lease_a = time.Hour,
		valid_a = time.Hour,
	}
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.authorizer = Authorizer {
		ctx               = &fx,
		authorize_connect = fixture_authorize_connect_grants,
	}

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	sid := open_test_stream(t, agent, &agent_dec, caller, &decoder)
	testing.expect(t, sid != proto.CONNECTION_STREAM_ID)

	denied := dial_server(t, &server)
	defer trans.connection_destroy(denied)
	denied_dec: proto.FrameDecoder
	add_caller_b(t, &store)
	handshake_as(t, denied, &denied_dec, .Caller, TOKEN_CALLER_B, PRINCIPAL_CALLER_B)
	defer proto.decoder_destroy(&denied_dec)
	send_connect(t, denied, TEST_SERVICE)
	expect_wire(t, denied, &denied_dec, .ConnectFailed, .Unauthorized)
}

@(test)
test_server_reset_grant_resets_only_matching_streams :: proc(t: ^testing.T) {
	fx := FixtureConnectAuthz {
		grant_a = GRANT_A,
		grant_b = GRANT_B,
		lease_a = time.Hour,
		lease_b = time.Hour,
		valid_a = time.Hour,
		valid_b = time.Hour,
	}
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	add_caller_b(t, &store)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
	server.authorizer = Authorizer {
		ctx               = &fx,
		authorize_connect = fixture_authorize_connect_grants,
	}

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	c1 := dial_server(t, &server)
	defer trans.connection_destroy(c1)
	d1: proto.FrameDecoder
	handshake_caller(t, c1, &d1)
	defer proto.decoder_destroy(&d1)
	sid1 := open_test_stream(t, agent, &agent_dec, c1, &d1)

	c2 := dial_server(t, &server)
	defer trans.connection_destroy(c2)
	d2: proto.FrameDecoder
	handshake_as(t, c2, &d2, .Caller, TOKEN_CALLER_B, PRINCIPAL_CALLER_B)
	defer proto.decoder_destroy(&d2)
	sid2 := open_test_stream(t, agent, &agent_dec, c2, &d2)

	server_reset_grant(&server, GRANT_A)

	reset_frame := must_read_opcode(t, c1, &d1, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, sid1)
	testing.expect_value(t, read_wire_failure(t, reset_frame), proto.WireError.Unauthorized)
	proto.frame_destroy(&reset_frame)

	must_write_stream(t, c2, .Data, []u8{'k'}, sid2)
	data := read_agent_data_skipping_reset(t, agent, &agent_dec, sid2, sid1)
	testing.expect_value(t, string(data.payload), "k")
	proto.frame_destroy(&data)
}

@(test)
test_authorization_lease_expiry_resets_matching_stream :: proc(t: ^testing.T) {
	fx := FixtureConnectAuthz {
		grant_a = GRANT_A,
		grant_b = GRANT_B,
		lease_a = 80 * time.Millisecond,
		lease_b = time.Hour,
		valid_a = time.Hour,
		valid_b = time.Hour,
	}
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	add_caller_b(t, &store)
	server.authorizer = Authorizer {
		ctx               = &fx,
		authorize_connect = fixture_authorize_connect_grants,
	}

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	c1 := dial_server(t, &server)
	defer trans.connection_destroy(c1)
	d1: proto.FrameDecoder
	handshake_caller(t, c1, &d1)
	defer proto.decoder_destroy(&d1)
	sid1 := open_test_stream(t, agent, &agent_dec, c1, &d1)

	c2 := dial_server(t, &server)
	defer trans.connection_destroy(c2)
	d2: proto.FrameDecoder
	handshake_as(t, c2, &d2, .Caller, TOKEN_CALLER_B, PRINCIPAL_CALLER_B)
	defer proto.decoder_destroy(&d2)
	sid2 := open_test_stream(t, agent, &agent_dec, c2, &d2)

	for _ in 0 ..< 6 {
		must_write_stream(t, c2, .Data, []u8{'k'}, sid2)
		data := read_agent_data_skipping_reset(t, agent, &agent_dec, sid2, sid1)
		testing.expect_value(t, string(data.payload), "k")
		proto.frame_destroy(&data)
		time.sleep(25 * time.Millisecond)
	}

	reset_frame := must_read_opcode(t, c1, &d1, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, sid1)
	testing.expect_value(t, read_wire_failure(t, reset_frame), proto.WireError.Timeout)
	proto.frame_destroy(&reset_frame)

	must_write_stream(t, c2, .Data, []u8{'z'}, sid2)
	live := read_agent_data_skipping_reset(t, agent, &agent_dec, sid2, sid1)
	testing.expect_value(t, string(live.payload), "z")
	proto.frame_destroy(&live)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.resets[.LeaseExpired] >= 1)
}

@(test)
test_connection_observer_authorized_and_opened :: proc(t: ^testing.T) {
	fx := FixtureConnectAuthz {
		grant_a = GRANT_A,
		lease_a = time.Hour,
		valid_a = time.Hour,
	}
	clog: ConnectionLog
	connection_log_init(&clog)
	defer connection_log_destroy(&clog)
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.authorizer = Authorizer {
		ctx               = &fx,
		authorize_connect = fixture_authorize_connect_grants,
	}
	server.connection_observer_ctx = &clog
	server.connection_observer = observe_connection

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	_ = open_test_stream(t, agent, &agent_dec, caller, &decoder)

	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		sync.mutex_lock(&clog.mutex)
		n := len(clog.kinds)
		sync.mutex_unlock(&clog.mutex)
		if n >= 2 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	sync.mutex_lock(&clog.mutex)
	defer sync.mutex_unlock(&clog.mutex)
	testing.expect(t, len(clog.kinds) >= 2)
	testing.expect_value(t, clog.kinds[0], ConnectionEventKind.Authorized)
	testing.expect_value(t, clog.kinds[1], ConnectionEventKind.Opened)
	testing.expect_value(t, clog.grants[0], GRANT_A)
	testing.expect_value(t, clog.bytes_c2a[0], u64(0))
	testing.expect_value(t, clog.bytes_a2c[0], u64(0))
}

@(test)
test_connection_observer_bytes_on_close :: proc(t: ^testing.T) {
	fx := FixtureConnectAuthz {
		grant_a = GRANT_A,
		lease_a = time.Hour,
		valid_a = time.Hour,
	}
	clog: ConnectionLog
	connection_log_init(&clog)
	defer connection_log_destroy(&clog)
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.authorizer = Authorizer {
		ctx               = &fx,
		authorize_connect = fixture_authorize_connect_grants,
	}
	server.connection_observer_ctx = &clog
	server.connection_observer = observe_connection

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	sid := open_test_stream(t, agent, &agent_dec, caller, &decoder)

	payload := []u8{'h', 'e', 'l', 'l', 'o'}
	must_write_stream(t, caller, .Data, payload, sid)
	data_frame := must_read_opcode(t, agent, &agent_dec, .Data)
	testing.expect_value(t, string(data_frame.payload), "hello")
	proto.frame_destroy(&data_frame)

	reply := []u8{'x', 'y'}
	must_write_stream(t, agent, .Data, reply, sid)
	echoed := must_read_opcode(t, caller, &decoder, .Data)
	testing.expect_value(t, string(echoed.payload), "xy")
	proto.frame_destroy(&echoed)

	must_write_stream(t, caller, .Close, nil, sid)
	close_frame := must_read_opcode(t, agent, &agent_dec, .Close)
	proto.frame_destroy(&close_frame)

	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		sync.mutex_lock(&clog.mutex)
		n := len(clog.kinds)
		sync.mutex_unlock(&clog.mutex)
		if n >= 3 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	sync.mutex_lock(&clog.mutex)
	defer sync.mutex_unlock(&clog.mutex)
	closed_i := -1
	for kind, i in clog.kinds {
		if kind == .Closed {
			closed_i = i
			break
		}
	}
	testing.expect(t, closed_i >= 0)
	if closed_i >= 0 {
		testing.expect_value(t, clog.bytes_c2a[closed_i], u64(len(payload)))
		testing.expect_value(t, clog.bytes_a2c[closed_i], u64(len(reply)))
	}
}

@(test)
test_authorize_connect_quota_returns_quota_exceeded :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.authorizer = Authorizer {
		authorize_connect = fixture_authorize_connect_quota,
	}

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	send_connect(t, caller, TEST_SERVICE)
	expect_wire(t, caller, &decoder, .ConnectFailed, .QuotaExceeded)
}

fixture_authorize_connect_quota :: proc(ctx: rawptr, req: ConnectAuthzRequest) -> (AuthzDecision, AuthzError) {
	_ = ctx
	_ = req
	return AuthzDecision{reason = .Quota}, .None
}

@(test)
test_authz_quota_maps_to_policy_quota_exceeded :: proc(t: ^testing.T) {
	d := AuthzDecision {
		reason = .Quota,
	}
	testing.expect_value(t, authz_to_policy_error(d, .None), PolicyError.QuotaExceeded)
	testing.expect_value(t, policy_error_to_authz(.QuotaExceeded), AuthzReason.Quota)
	testing.expect_value(t, authz_reason_label(.Quota), LABEL_QUOTA)
}

ConnectionLog :: struct {
	mutex:      sync.Mutex,
	allocator:  mem.Allocator,
	kinds:      [dynamic]ConnectionEventKind,
	grants:     [dynamic]string,
	bytes_c2a:  [dynamic]u64,
	bytes_a2c:  [dynamic]u64,
}

connection_log_init :: proc(log: ^ConnectionLog, allocator := context.allocator) {
	log^ = {}
	log.allocator = allocator
	log.kinds = make([dynamic]ConnectionEventKind, allocator)
	log.grants = make([dynamic]string, allocator)
	log.bytes_c2a = make([dynamic]u64, allocator)
	log.bytes_a2c = make([dynamic]u64, allocator)
}

connection_log_destroy :: proc(log: ^ConnectionLog) {
	for s in log.grants {
		delete(s, log.allocator)
	}
	delete(log.kinds)
	delete(log.grants)
	delete(log.bytes_c2a)
	delete(log.bytes_a2c)
}

observe_connection :: proc(ctx: rawptr, ev: ConnectionEvent) {
	log := (^ConnectionLog)(ctx)
	if log == nil {
		return
	}
	sync.mutex_lock(&log.mutex)
	defer sync.mutex_unlock(&log.mutex)
	append(&log.kinds, ev.kind)
	cloned, err := strings.clone(ev.grant_id, log.allocator)
	if err == .None {
		append(&log.grants, cloned)
	}
	append(&log.bytes_c2a, ev.bytes_caller_to_agent)
	append(&log.bytes_a2c, ev.bytes_agent_to_caller)
}
