package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:time"

CRED_TOKEN_HOST :: "cred-host-token"
CRED_TOKEN_HOST_B :: "cred-host-token-b"
CRED_PRINCIPAL_HOST :: "cred-host-a"
CRED_SERVICE :: "acme/site-17/reporting-api"

start_empty_production_server :: proc(
	t: ^testing.T,
	server: ^Server,
	reg: ^Registry,
	store: ^auth.StaticTokenAuth,
	loc := #caller_location,
) {
	must_init_registry(t, reg, loc)
	testing.expect_value(t, auth.auth_init(store), auth.AuthError.None, loc)
	server_init(server, reg, auth.static_token_authenticator(store))
	server_disable_test_hardening(server)
	server.policy_mode = .Production
	server.may_register = nil
	server.may_connect = nil
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
	testing.expect_value(t, server_listen(server, trans.loopback_endpoint(0)), trans.TransportError.None, loc)
	server_start(server)
}

@(test)
test_conn_credential_register_cap_without_policy_cap :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_empty_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(
		t,
		auth.auth_add_credential(
			&store,
			auth.CredentialSpec {
				token        = CRED_TOKEN_HOST,
				principal_id = CRED_PRINCIPAL_HOST,
				capabilities = {.RegisterService},
			},
		),
		auth.AuthError.None,
	)
	testing.expect_value(
		t,
		policy_add_namespace_grant(&server.policy, CRED_PRINCIPAL_HOST, "acme/site-17/*"),
		PolicyError.None,
	)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, CRED_TOKEN_HOST, CRED_PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, CRED_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_conn_credential_without_register_cap_unauthorized :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_empty_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, auth.auth_add_token(&store, CRED_TOKEN_HOST, CRED_PRINCIPAL_HOST), auth.AuthError.None)
	testing.expect_value(
		t,
		policy_add_namespace_grant(&server.policy, CRED_PRINCIPAL_HOST, "acme/site-17/*"),
		PolicyError.None,
	)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, CRED_TOKEN_HOST, CRED_PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, CRED_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_conn_expired_token_authenticate_failed :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_empty_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(
		t,
		auth.auth_add_credential(
			&store,
			auth.CredentialSpec {
				token        = CRED_TOKEN_HOST,
				principal_id = CRED_PRINCIPAL_HOST,
				expires_at   = time.time_add(time.now(), -time.Hour),
			},
		),
		auth.AuthError.None,
	)

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&decoder)
	send_hello(t, conn, .Agent)
	ack := must_read_opcode(t, conn, &decoder, .HelloAck)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	send_authenticate(t, conn, CRED_TOKEN_HOST)
	expect_wire(t, conn, &decoder, .AuthenticateFailed, .AuthenticationFailed)
}

@(test)
test_conn_overlapping_tokens_same_principal :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_empty_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	testing.expect_value(t, auth.auth_add_token(&store, CRED_TOKEN_HOST, CRED_PRINCIPAL_HOST), auth.AuthError.None)
	testing.expect_value(t, auth.auth_add_token(&store, CRED_TOKEN_HOST_B, CRED_PRINCIPAL_HOST), auth.AuthError.None)

	conn_a := dial_server(t, &server)
	defer trans.connection_destroy(conn_a)
	decoder_a: proto.FrameDecoder
	handshake_as(t, conn_a, &decoder_a, .Agent, CRED_TOKEN_HOST, CRED_PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder_a)

	conn_b := dial_server(t, &server)
	defer trans.connection_destroy(conn_b)
	decoder_b: proto.FrameDecoder
	handshake_as(t, conn_b, &decoder_b, .Caller, CRED_TOKEN_HOST_B, CRED_PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder_b)
}
