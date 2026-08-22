package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:time"

TOKEN_HOST_B :: "host-b-token"
PRINCIPAL_HOST_B :: "host-b"
TOKEN_HOST_C :: "host-c-token"
PRINCIPAL_HOST_C :: "host-c"
TOKEN_CALLER_B :: "caller-b-token"
PRINCIPAL_CALLER_B :: "client-b"
TOKEN_CALLER_C :: "caller-c-token"
PRINCIPAL_CALLER_C :: "client-c"
TOKEN_CALLER_D :: "caller-d-token"
PRINCIPAL_CALLER_D :: "client-d"

SITE_SERVICE :: "acme/site-17/reporting-api"
SITE_SIBLING :: "acme/site-17/other"
OTHER_SERVICE :: "acme/other"

start_production_server :: proc(
	t: ^testing.T,
	server: ^Server,
	reg: ^Registry,
	store: ^auth.StaticTokenAuth,
	loc := #caller_location,
) {
	start_test_server(t, server, reg, store, loc)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_HOST_B, PRINCIPAL_HOST_B), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_HOST_C, PRINCIPAL_HOST_C), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_CALLER_B, PRINCIPAL_CALLER_B), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_CALLER_C, PRINCIPAL_CALLER_C), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_CALLER_D, PRINCIPAL_CALLER_D), auth.AuthError.None, loc)

	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_HOST, {.RegisterService}), PolicyError.None, loc)
	testing.expect_value(t, policy_add_namespace_grant(&server.policy, PRINCIPAL_HOST, "acme/site-17/*"), PolicyError.None, loc)
	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_HOST_B, {.RegisterService}), PolicyError.None, loc)
	testing.expect_value(t, policy_add_namespace_grant(&server.policy, PRINCIPAL_HOST_C, "acme/site-17/*"), PolicyError.None, loc)
	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_CALLER, {.ConnectService}), PolicyError.None, loc)
	testing.expect_value(t, policy_add_connect_grant(&server.policy, PRINCIPAL_CALLER, SITE_SERVICE), PolicyError.None, loc)
	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_CALLER_B, {.ConnectService}), PolicyError.None, loc)
	testing.expect_value(t, policy_add_connect_grant(&server.policy, PRINCIPAL_CALLER_B, "acme/site-17/*"), PolicyError.None, loc)
	testing.expect_value(t, policy_add_connect_grant(&server.policy, PRINCIPAL_CALLER_C, SITE_SERVICE), PolicyError.None, loc)
	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_CALLER_D, {.ConnectService}), PolicyError.None, loc)

	server.policy_mode = .Production
}

handshake_as :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	role: proto.PeerRole,
	token: string,
	principal_id: string,
	loc := #caller_location,
) {
	testing.expect_value(t, proto.decoder_init(decoder), proto.ProtocolError.None, loc)
	send_hello(t, conn, role, proto.PROTOCOL_MAJOR, loc)
	ack := must_read_opcode(t, conn, decoder, .HelloAck, loc)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None, loc)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	send_authenticate(t, conn, token, loc)
	ok_frame := must_read_opcode(t, conn, decoder, .AuthenticateOk, loc)
	ok_msg, oerr := proto.decode_authenticate_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None, loc)
	testing.expect_value(t, ok_msg.principal_id, principal_id, loc)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_frame)
}

expect_wire :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	opcode: proto.Opcode,
	code: proto.WireError,
	loc := #caller_location,
) {
	fail := must_read_opcode(t, conn, decoder, opcode, loc)
	got := read_wire_failure(t, fail, loc)
	proto.frame_destroy(&fail)
	testing.expect_value(t, got, code, loc)
}

register_site_agent :: proc(
	t: ^testing.T,
	server: ^Server,
	service := SITE_SERVICE,
	loc := #caller_location,
) -> (
	^trans.Connection,
	proto.FrameDecoder,
) {
	conn := dial_server(t, server, loc)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST, loc)
	send_register(t, conn, service, loc)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk, loc)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
	return conn, decoder
}

@(test)
test_authz_agent_register_granted_ok :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

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
}

@(test)
test_authz_agent_register_cap_without_grant_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST_B, PRINCIPAL_HOST_B)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, SITE_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_authz_agent_register_grant_without_cap_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST_C, PRINCIPAL_HOST_C)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, SITE_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_authz_agent_register_outside_namespace_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, OTHER_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_authz_agent_unregister_without_cap_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

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

	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_HOST, {}), PolicyError.None)
	send_unregister(t, conn, SITE_SERVICE)
	expect_wire(t, conn, &decoder, .UnregisterFailed, .Unauthorized)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_authz_agent_connect_protocol_error_with_both_caps :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_HOST, {.RegisterService, .ConnectService}), PolicyError.None)
	testing.expect_value(t, policy_add_connect_grant(&server.policy, PRINCIPAL_HOST, SITE_SERVICE), PolicyError.None)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_connect(t, conn, SITE_SERVICE)
	expect_wire(t, conn, &decoder, .Error, .ProtocolError)
}

@(test)
test_authz_caller_connect_granted_reaches_open :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_site_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_as(t, caller, &caller_dec, .Caller, TOKEN_CALLER, PRINCIPAL_CALLER)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, SITE_SERVICE)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	testing.expect(t, open_frame.header.stream_id != proto.CONNECTION_STREAM_ID)
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)
}

@(test)
test_authz_caller_connect_cap_without_grant_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_site_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_as(t, caller, &caller_dec, .Caller, TOKEN_CALLER_D, PRINCIPAL_CALLER_D)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, SITE_SERVICE)
	expect_wire(t, caller, &caller_dec, .ConnectFailed, .Unauthorized)
}

@(test)
test_authz_caller_connect_grant_without_cap_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_site_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_as(t, caller, &caller_dec, .Caller, TOKEN_CALLER_C, PRINCIPAL_CALLER_C)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, SITE_SERVICE)
	expect_wire(t, caller, &caller_dec, .ConnectFailed, .Unauthorized)
}

@(test)
test_authz_caller_prefix_grant_allows_sibling_exact_does_not :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_site_agent(t, &server, SITE_SIBLING)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	denied := dial_server(t, &server)
	defer trans.connection_destroy(denied)
	denied_dec: proto.FrameDecoder
	handshake_as(t, denied, &denied_dec, .Caller, TOKEN_CALLER, PRINCIPAL_CALLER)
	defer proto.decoder_destroy(&denied_dec)
	send_connect(t, denied, SITE_SIBLING)
	expect_wire(t, denied, &denied_dec, .ConnectFailed, .Unauthorized)

	allowed := dial_server(t, &server)
	defer trans.connection_destroy(allowed)
	allowed_dec: proto.FrameDecoder
	handshake_as(t, allowed, &allowed_dec, .Caller, TOKEN_CALLER_B, PRINCIPAL_CALLER_B)
	defer proto.decoder_destroy(&allowed_dec)
	send_connect(t, allowed, SITE_SIBLING)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)
}

@(test)
test_authz_caller_register_and_unregister_protocol_error_despite_grants :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	testing.expect_value(t, policy_set_capabilities(&server.policy, PRINCIPAL_CALLER, {.RegisterService, .ConnectService}), PolicyError.None)
	testing.expect_value(t, policy_add_namespace_grant(&server.policy, PRINCIPAL_CALLER, "acme/site-17/*"), PolicyError.None)

	reg_conn := dial_server(t, &server)
	defer trans.connection_destroy(reg_conn)
	reg_dec: proto.FrameDecoder
	handshake_as(t, reg_conn, &reg_dec, .Caller, TOKEN_CALLER, PRINCIPAL_CALLER)
	defer proto.decoder_destroy(&reg_dec)
	send_register(t, reg_conn, SITE_SERVICE)
	expect_wire(t, reg_conn, &reg_dec, .Error, .ProtocolError)
	testing.expect_value(t, service_count(&reg), 0)

	unreg_conn := dial_server(t, &server)
	defer trans.connection_destroy(unreg_conn)
	unreg_dec: proto.FrameDecoder
	handshake_as(t, unreg_conn, &unreg_dec, .Caller, TOKEN_CALLER, PRINCIPAL_CALLER)
	defer proto.decoder_destroy(&unreg_dec)
	send_unregister(t, unreg_conn, SITE_SERVICE)
	expect_wire(t, unreg_conn, &unreg_dec, .Error, .ProtocolError)
}

@(test)
test_authz_unauthenticated_register_connect_unregister_protocol_error :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	opcodes := []proto.Opcode{.Register, .Connect, .Unregister}
	for opcode in opcodes {
		conn := dial_server(t, &server)
		decoder: proto.FrameDecoder
		init_decoder(t, &decoder)
		send_hello(t, conn, .Agent)
		ack := must_read_opcode(t, conn, &decoder, .HelloAck)
		delete((proto.decode_hello_ack(ack.payload) or_else proto.HelloAck{}).implementation)
		proto.frame_destroy(&ack)
		switch opcode {
		case .Register:
			send_register(t, conn, SITE_SERVICE)
		case .Connect:
			send_connect(t, conn, SITE_SERVICE)
		case .Unregister:
			send_unregister(t, conn, SITE_SERVICE)
		case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
		     .RegisterOk, .RegisterFailed, .UnregisterOk, .UnregisterFailed,
		     .ConnectOk, .ConnectFailed, .Open, .OpenOk, .OpenFailed, .Data, .HalfClose,
		     .Close, .Reset, .Ping, .Pong, .Error:
			testing.expect(t, false)
		}
		expect_wire(t, conn, &decoder, .Error, .ProtocolError)
		proto.decoder_destroy(&decoder)
		trans.connection_destroy(conn)
	}
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_authz_service_name_is_not_a_credential :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	missing := dial_server(t, &server)
	defer trans.connection_destroy(missing)
	missing_dec: proto.FrameDecoder
	handshake_as(t, missing, &missing_dec, .Caller, TOKEN_CALLER, PRINCIPAL_CALLER)
	defer proto.decoder_destroy(&missing_dec)
	send_connect(t, missing, SITE_SERVICE)
	expect_wire(t, missing, &missing_dec, .ConnectFailed, .ServiceNotFound)

	agent, agent_dec := register_site_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	ungranted := dial_server(t, &server)
	defer trans.connection_destroy(ungranted)
	ungranted_dec: proto.FrameDecoder
	handshake_as(t, ungranted, &ungranted_dec, .Caller, TOKEN_CALLER_C, PRINCIPAL_CALLER_C)
	defer proto.decoder_destroy(&ungranted_dec)
	send_connect(t, ungranted, SITE_SERVICE)
	expect_wire(t, ungranted, &ungranted_dec, .ConnectFailed, .Unauthorized)
}
