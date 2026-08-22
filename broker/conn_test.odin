package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:time"

TOKEN_HOST :: "host-dev-token"
TOKEN_CALLER :: "caller-dev-token"
PRINCIPAL_HOST :: "host-a"
PRINCIPAL_CALLER :: "client-a"
TEST_SERVICE :: "demo/echo"

token_bytes :: proc(s: string) -> []u8 {
	if len(s) == 0 {
		return nil
	}
	return ([^]u8)(raw_data(s))[:len(s)]
}

start_test_server :: proc(
	t: ^testing.T,
	server: ^Server,
	reg: ^Registry,
	store: ^auth.StaticTokenAuth,
	loc := #caller_location,
) {
	must_init_registry(t, reg, loc)
	testing.expect_value(t, auth.auth_init(store), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_HOST, PRINCIPAL_HOST), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_CALLER, PRINCIPAL_CALLER), auth.AuthError.None, loc)
	server_init(server, reg, auth.static_token_authenticator(store))
	server_disable_test_hardening(server)
	server.heartbeat_interval = 50 * time.Millisecond
	server.session_timeout = 2 * time.Second
	testing.expect_value(t, server_listen(server, trans.loopback_endpoint(0)), trans.TransportError.None, loc)
	server_start(server)
}

stop_test_server :: proc(server: ^Server, store: ^auth.StaticTokenAuth, reg: ^Registry) {
	server_stop(server)
	_ = server_wait_idle(server, 2 * time.Second)
	server_destroy(server)
	auth.auth_destroy(store)
	registry_destroy(reg)
}

dial_server :: proc(t: ^testing.T, server: ^Server, loc := #caller_location) -> ^trans.Connection {
	ep, eerr := server_endpoint(server)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	conn, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None, loc)
	testing.expect(t, conn != nil, loc = loc)
	return conn
}

must_write_opcode :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	loc := #caller_location,
) {
	terr, perr := trans.write_frame(conn, opcode, payload)
	testing.expect_value(t, terr, trans.TransportError.None, loc)
	testing.expect_value(t, perr, proto.ProtocolError.None, loc)
}

must_read_frame :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	loc := #caller_location,
) -> proto.Frame {
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
	frame, terr, perr := trans.read_frame(conn, decoder)
	testing.expect_value(t, terr, trans.TransportError.None, loc)
	testing.expect_value(t, perr, proto.ProtocolError.None, loc)
	return frame
}

must_read_opcode :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	opcode: proto.Opcode,
	loc := #caller_location,
) -> proto.Frame {
	frame := must_read_frame(t, conn, decoder, loc)
	testing.expect_value(t, frame.header.opcode, opcode, loc)
	return frame
}

read_wire_failure :: proc(t: ^testing.T, frame: proto.Frame, loc := #caller_location) -> proto.WireError {
	fail, err := proto.decode_wire_failure(frame.payload)
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	defer delete(fail.diagnostic)
	code, ok := proto.wire_error_from_u16(fail.code)
	testing.expect(t, ok, loc = loc)
	return code
}

send_hello :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	role: proto.PeerRole,
	major: u8 = proto.PROTOCOL_MAJOR,
	loc := #caller_location,
) {
	payload, err := proto.encode_hello(
		proto.Hello {
			major            = major,
			minor            = proto.PROTOCOL_MINOR,
			role             = role,
			capability_bits  = 0,
			implementation   = "test-peer",
		},
	)
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	defer delete(payload)
	must_write_opcode(t, conn, .Hello, payload, loc)
}

send_authenticate :: proc(t: ^testing.T, conn: ^trans.Connection, token: string, loc := #caller_location) {
	payload, err := proto.encode_authenticate(proto.Authenticate{token = token_bytes(token)})
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	defer delete(payload)
	must_write_opcode(t, conn, .Authenticate, payload, loc)
}

send_register :: proc(t: ^testing.T, conn: ^trans.Connection, service: string, loc := #caller_location) {
	id, serr := proto.make_service_id(service)
	testing.expect_value(t, serr, proto.ServiceIdError.None, loc)
	payload, err := proto.encode_register(proto.Register{service_id = id})
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	defer delete(payload)
	must_write_opcode(t, conn, .Register, payload, loc)
}

send_unregister :: proc(t: ^testing.T, conn: ^trans.Connection, service: string, loc := #caller_location) {
	id, serr := proto.make_service_id(service)
	testing.expect_value(t, serr, proto.ServiceIdError.None, loc)
	payload, err := proto.encode_unregister(proto.Unregister{service_id = id})
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	defer delete(payload)
	must_write_opcode(t, conn, .Unregister, payload, loc)
}

handshake_agent :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	token := TOKEN_HOST,
	loc := #caller_location,
) {
	testing.expect_value(t, proto.decoder_init(decoder), proto.ProtocolError.None, loc)
	send_hello(t, conn, .Agent, proto.PROTOCOL_MAJOR, loc)
	ack := must_read_opcode(t, conn, decoder, .HelloAck, loc)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None, loc)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	send_authenticate(t, conn, token, loc)
	ok_frame := must_read_opcode(t, conn, decoder, .AuthenticateOk, loc)
	ok_msg, oerr := proto.decode_authenticate_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None, loc)
	testing.expect_value(t, ok_msg.principal_id, PRINCIPAL_HOST, loc)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_frame)
}

handshake_caller :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	token := TOKEN_CALLER,
	loc := #caller_location,
) {
	testing.expect_value(t, proto.decoder_init(decoder), proto.ProtocolError.None, loc)
	send_hello(t, conn, .Caller, proto.PROTOCOL_MAJOR, loc)
	ack := must_read_opcode(t, conn, decoder, .HelloAck, loc)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None, loc)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	send_authenticate(t, conn, token, loc)
	ok_frame := must_read_opcode(t, conn, decoder, .AuthenticateOk, loc)
	ok_msg, oerr := proto.decode_authenticate_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None, loc)
	testing.expect_value(t, ok_msg.principal_id, PRINCIPAL_CALLER, loc)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_frame)
}

send_connect :: proc(t: ^testing.T, conn: ^trans.Connection, service: string, loc := #caller_location) {
	id, serr := proto.make_service_id(service)
	testing.expect_value(t, serr, proto.ServiceIdError.None, loc)
	payload, err := proto.encode_connect(proto.Connect{service_id = id})
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	defer delete(payload)
	must_write_opcode(t, conn, .Connect, payload, loc)
}

init_decoder :: proc(t: ^testing.T, decoder: ^proto.FrameDecoder, loc := #caller_location) {
	testing.expect_value(t, proto.decoder_init(decoder), proto.ProtocolError.None, loc)
}

@(test)
test_conn_hello_auth_register_then_lookup :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	ok_msg, oerr := proto.decode_register_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None)
	testing.expect_value(t, string(ok_msg.service_id), TEST_SERVICE)
	delete(string(ok_msg.service_id))
	proto.frame_destroy(&ok_frame)

	svc := must_service_id(t, TEST_SERVICE)
	rec, found := lookup_service(&reg, svc)
	testing.expect(t, found)
	testing.expect_value(t, string(rec.id), TEST_SERVICE)
	testing.expect_value(t, string(rec.owner), PRINCIPAL_HOST)
}

@(test)
test_conn_duplicate_register_rejected :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	a := dial_server(t, &server)
	defer trans.connection_destroy(a)
	dec_a: proto.FrameDecoder
	handshake_agent(t, a, &dec_a)
	defer proto.decoder_destroy(&dec_a)
	send_register(t, a, TEST_SERVICE)
	ok_frame := must_read_opcode(t, a, &dec_a, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)

	b := dial_server(t, &server)
	defer trans.connection_destroy(b)
	dec_b: proto.FrameDecoder
	handshake_agent(t, b, &dec_b)
	defer proto.decoder_destroy(&dec_b)
	send_register(t, b, TEST_SERVICE)
	fail_frame := must_read_opcode(t, b, &dec_b, .RegisterFailed)
	code := read_wire_failure(t, fail_frame)
	proto.frame_destroy(&fail_frame)
	testing.expect_value(t, code, proto.WireError.ServiceAlreadyRegistered)

	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_conn_disconnect_removes_registration :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
	testing.expect_value(t, service_count(&reg), 1)

	proto.decoder_destroy(&decoder)
	trans.connection_destroy(conn)

	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		if service_count(&reg) == 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_conn_bad_token_authenticate_failed :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	init_decoder(t, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_hello(t, conn, .Agent)
	ack := must_read_opcode(t, conn, &decoder, .HelloAck)
	ack_msg, _ := proto.decode_hello_ack(ack.payload)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	send_authenticate(t, conn, "wrong-token")
	fail := must_read_opcode(t, conn, &decoder, .AuthenticateFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.AuthenticationFailed)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_conn_hello_major_unsupported :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	init_decoder(t, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_hello(t, conn, .Agent, 2)
	fail := must_read_opcode(t, conn, &decoder, .Error)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.UnsupportedVersion)
}

@(test)
test_conn_first_frame_not_hello_protocol_error :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	init_decoder(t, &decoder)
	defer proto.decoder_destroy(&decoder)

	payload, err := proto.encode_ping(proto.Ping{nonce = 1})
	testing.expect_value(t, err, proto.ProtocolError.None)
	defer delete(payload)
	must_write_opcode(t, conn, .Ping, payload)

	fail := must_read_opcode(t, conn, &decoder, .Error)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.ProtocolError)
}

@(test)
test_conn_ping_nonce_echoed :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	payload, err := proto.encode_ping(proto.Ping{nonce = 0xAABBCCDDEEFF0011})
	testing.expect_value(t, err, proto.ProtocolError.None)
	defer delete(payload)
	must_write_opcode(t, conn, .Ping, payload)

	pong_frame := must_read_opcode(t, conn, &decoder, .Pong)
	pong, perr := proto.decode_pong(pong_frame.payload)
	testing.expect_value(t, perr, proto.ProtocolError.None)
	proto.frame_destroy(&pong_frame)
	testing.expect_value(t, pong.nonce, u64(0xAABBCCDDEEFF0011))
}

@(test)
test_conn_caller_register_protocol_error :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	init_decoder(t, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_hello(t, conn, .Caller)
	ack := must_read_opcode(t, conn, &decoder, .HelloAck)
	ack_msg, _ := proto.decode_hello_ack(ack.payload)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	send_authenticate(t, conn, TOKEN_CALLER)
	ok_frame := must_read_opcode(t, conn, &decoder, .AuthenticateOk)
	ok_msg, _ := proto.decode_authenticate_ok(ok_frame.payload)
	testing.expect_value(t, ok_msg.principal_id, PRINCIPAL_CALLER)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_frame)

	send_register(t, conn, TEST_SERVICE)
	fail := must_read_opcode(t, conn, &decoder, .Error)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.ProtocolError)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_conn_caller_unregister_protocol_error :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_caller(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_unregister(t, conn, TEST_SERVICE)
	fail := must_read_opcode(t, conn, &decoder, .Error)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.ProtocolError)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_conn_may_register_false_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.may_register = may_register_deny_all

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	fail := must_read_opcode(t, conn, &decoder, .RegisterFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.Unauthorized)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_conn_idle_timeout_removes_registration :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.heartbeat_interval = 20 * time.Millisecond
	server.session_timeout = 80 * time.Millisecond

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
	testing.expect_value(t, service_count(&reg), 1)

	deadline := time.now()
	for time.since(deadline) < 1 * time.Second {
		if service_count(&reg) == 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_conn_unregister_drops_lookup :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)

	send_unregister(t, conn, TEST_SERVICE)
	ok_unreg := must_read_opcode(t, conn, &decoder, .UnregisterOk)
	delete(string((proto.decode_unregister_ok(ok_unreg.payload) or_else proto.UnregisterOk{}).service_id))
	proto.frame_destroy(&ok_unreg)
	svc := must_service_id(t, TEST_SERVICE)
	_, found := lookup_service(&reg, svc)
	testing.expect(t, !found)
	testing.expect_value(t, service_count(&reg), 0)
	testing.expect_value(t, server.metrics.unregistrations_total, u64(1))
}

@(test)
test_conn_unregister_absent_is_idempotent_ok :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_unregister(t, conn, TEST_SERVICE)
	ok_unreg := must_read_opcode(t, conn, &decoder, .UnregisterOk)
	delete(string((proto.decode_unregister_ok(ok_unreg.payload) or_else proto.UnregisterOk{}).service_id))
	proto.frame_destroy(&ok_unreg)
	testing.expect_value(t, service_count(&reg), 0)
	testing.expect_value(t, server.metrics.unregistrations_total, u64(1))
}

@(test)
test_conn_unregister_other_session_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	testing.expect_value(t, auth.auth_add_token(&store, "host-b-token", "host-b"), auth.AuthError.None)

	owner := dial_server(t, &server)
	defer trans.connection_destroy(owner)
	owner_dec: proto.FrameDecoder
	handshake_agent(t, owner, &owner_dec)
	defer proto.decoder_destroy(&owner_dec)
	send_register(t, owner, TEST_SERVICE)
	ok_frame := must_read_opcode(t, owner, &owner_dec, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)

	other := dial_server(t, &server)
	defer trans.connection_destroy(other)
	other_dec: proto.FrameDecoder
	handshake_as(t, other, &other_dec, .Agent, "host-b-token", "host-b")
	defer proto.decoder_destroy(&other_dec)
	send_unregister(t, other, TEST_SERVICE)
	fail := must_read_opcode(t, other, &other_dec, .UnregisterFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.Unauthorized)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_conn_unregister_invalid_service_id_failed :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	buf: [dynamic]u8
	testing.expect_value(t, proto.append_lp_string(&buf, "bad id"), proto.ProtocolError.None)
	defer delete(buf)
	must_write_opcode(t, conn, .Unregister, buf[:])
	fail := must_read_opcode(t, conn, &decoder, .UnregisterFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.InvalidServiceId)

	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_conn_register_quota_exceeded :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	reg.max_registrations_per_session = 1

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, "game/one")
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)

	send_register(t, conn, "game/two")
	fail := must_read_opcode(t, conn, &decoder, .RegisterFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.QuotaExceeded)
	testing.expect_value(t, service_count(&reg), 1)
}

EphemeralAuth :: struct {
	token: string,
	id:    string,
	org:   string,
}

authenticate_ephemeral :: proc(ctx: rawptr, token: []u8) -> (auth.AuthResult, auth.AuthError) {
	c := (^EphemeralAuth)(ctx)
	if c == nil || string(token) != c.token {
		return {}, .InvalidToken
	}
	return auth.AuthResult {
			id              = c.id,
			organization    = c.org,
			credential_id   = "cred-1",
			environment_id  = "env-1",
			principal_kind  = "agent",
			policy_version  = 7,
		},
		.None
}

@(test)
test_conn_nil_authenticator_fails_closed :: proc(t: ^testing.T) {
	reg: Registry
	server: Server
	must_init_registry(t, &reg)
	server_init(&server, &reg, {})
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
	send_authenticate(t, conn, TOKEN_HOST)
	fail := must_read_opcode(t, conn, &decoder, .AuthenticateFailed)
	testing.expect_value(t, read_wire_failure(t, fail), proto.WireError.AuthenticationFailed)
	proto.frame_destroy(&fail)
}

@(test)
test_conn_custom_authenticator_clones_principal :: proc(t: ^testing.T) {
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
	ok_frame := must_read_opcode(t, conn, &decoder, .AuthenticateOk)
	ok_msg, oerr := proto.decode_authenticate_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None)
	testing.expect_value(t, ok_msg.principal_id, ephemeral.id)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_frame)

	send_register(t, conn, TEST_SERVICE)
	reg_ok := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(reg_ok.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&reg_ok)
}
