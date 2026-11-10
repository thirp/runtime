package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:bytes"
import "core:strings"
import "core:testing"
import "core:time"

// Fixture names, not wire fields. The frames under test carry service_id only.
ENV_A :: "env-a"
ENV_B :: "env-b"
ENV_SERVICE :: "api"
ENV_ORG :: "org/dev"

EnvCred :: struct {
	token:        string,
	id:           string,
	environment:  string,
	organization: string,
}

EnvTable :: struct {
	creds: []EnvCred,
}

authenticate_env_table :: proc(ctx: rawptr, token: []u8) -> (auth.AuthResult, auth.AuthError) {
	table := (^EnvTable)(ctx)
	if table == nil {
		return {}, .InvalidToken
	}
	for cred in table.creds {
		if string(token) == cred.token {
			organization := cred.organization
			if len(organization) == 0 {
				organization = ENV_ORG
			}
			return auth.AuthResult {
					id             = cred.id,
					organization   = organization,
					environment_id = cred.environment,
				},
				.None
		}
	}
	return {}, .InvalidToken
}

start_env_broker :: proc(t: ^testing.T, server: ^Server, reg: ^Registry, table: ^EnvTable) {
	must_init_registry(t, reg)
	server_init(server, reg, auth.Authenticator{ctx = table, authenticate = authenticate_env_table})
	server_disable_test_hardening(server)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
	testing.expect_value(t, server_listen(server, trans.loopback_endpoint(0)), trans.TransportError.None)
	server_start(server)
}

stop_env_broker :: proc(server: ^Server, reg: ^Registry) {
	server_stop(server)
	_ = server_wait_idle(server, 2 * time.Second)
	server_destroy(server)
	registry_destroy(reg)
}

login_env :: proc(
	t: ^testing.T,
	server: ^Server,
	token, principal: string,
	role: proto.PeerRole,
) -> (
	^trans.Connection,
	proto.FrameDecoder,
) {
	conn := dial_server(t, server)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None)
	send_hello(t, conn, role, proto.PROTOCOL_MAJOR)
	ack := must_read_opcode(t, conn, &decoder, .HelloAck)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	send_authenticate(t, conn, token)
	ok_frame := must_read_opcode(t, conn, &decoder, .AuthenticateOk)
	ok_msg, oerr := proto.decode_authenticate_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None)
	testing.expect_value(t, ok_msg.principal_id, principal)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_frame)
	return conn, decoder
}

// REGISTER bytes are the service id alone. An environment string in the
// credential must not appear in the frame an old broker would parse.
register_env_service :: proc(t: ^testing.T, conn: ^trans.Connection, decoder: ^proto.FrameDecoder, environment: string) {
	id := must_service_id(t, ENV_SERVICE)
	payload, err := proto.encode_register(proto.Register{service_id = id})
	testing.expect_value(t, err, proto.ProtocolError.None)
	defer delete(payload)
	if len(environment) > 0 {
		testing.expect(t, !strings.contains(string(payload), environment))
	}
	again, aerr := proto.encode_register(proto.Register{service_id = id})
	testing.expect_value(t, aerr, proto.ProtocolError.None)
	defer delete(again)
	testing.expect(t, bytes.equal(payload, again))
	must_write_opcode(t, conn, .Register, payload)
	ok_frame := must_read_opcode(t, conn, decoder, .RegisterOk)
	ok_msg, oerr := proto.decode_register_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None)
	testing.expect_value(t, string(ok_msg.service_id), ENV_SERVICE)
	delete(string(ok_msg.service_id))
	proto.frame_destroy(&ok_frame)
}

finish_open :: proc(
	t: ^testing.T,
	agent: ^trans.Connection,
	agent_dec: ^proto.FrameDecoder,
	caller: ^trans.Connection,
	caller_dec: ^proto.FrameDecoder,
) {
	open_frame := must_read_opcode(t, agent, agent_dec, .Open)
	open_msg, oerr := proto.decode_open(open_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None)
	testing.expect_value(t, string(open_msg.service_id), ENV_SERVICE)
	delete(string(open_msg.service_id))
	stream_id := open_frame.header.stream_id
	proto.frame_destroy(&open_frame)
	must_write_stream(t, agent, .OpenOk, nil, stream_id)
	ok_frame := must_read_opcode(t, caller, caller_dec, .ConnectOk)
	testing.expect_value(t, ok_frame.header.stream_id, stream_id)
	proto.frame_destroy(&ok_frame)
}

expect_no_frame :: proc(t: ^testing.T, conn: ^trans.Connection, decoder: ^proto.FrameDecoder) {
	_ = trans.connection_set_recv_timeout(conn, 200 * time.Millisecond)
	frame, terr, _ := trans.read_frame(conn, decoder)
	testing.expect_value(t, terr, trans.TransportError.Timeout)
	if terr == .None {
		proto.frame_destroy(&frame)
	}
}

@(test)
test_two_environments_same_service_id_route :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-agent-b", id = "host-b", environment = ENV_B},
		{token = "token-caller-a", id = "client-a", environment = ENV_A},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
	}
	table := EnvTable {
		creds = creds[:],
	}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&dec_a)
	agent_b, dec_b := login_env(t, &server, "token-agent-b", "host-b", .Agent)
	defer trans.connection_destroy(agent_b)
	defer proto.decoder_destroy(&dec_b)
	register_env_service(t, agent_a, &dec_a, ENV_A)
	register_env_service(t, agent_b, &dec_b, ENV_B)

	caller_a, cdec_a := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&cdec_a)
	caller_b, cdec_b := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&cdec_b)

	send_connect(t, caller_a, ENV_SERVICE)
	finish_open(t, agent_a, &dec_a, caller_a, &cdec_a)
	expect_no_frame(t, agent_b, &dec_b)

	send_connect(t, caller_b, ENV_SERVICE)
	finish_open(t, agent_b, &dec_b, caller_b, &cdec_b)
	expect_no_frame(t, agent_a, &dec_a)
}

@(test)
test_account_and_scoped_agents_and_callers :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-legacy", id = "host-legacy", environment = ""},
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-caller-legacy", id = "client-legacy", environment = ""},
		{token = "token-caller-a", id = "client-a", environment = ENV_A},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
	}
	table := EnvTable {
		creds = creds[:],
	}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	legacy, ldec := login_env(t, &server, "token-agent-legacy", "host-legacy", .Agent)
	defer trans.connection_destroy(legacy)
	defer proto.decoder_destroy(&ldec)
	agent_a, adec := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&adec)

	// Scoped-only name: an old caller must not see it.
	register_env_service(t, agent_a, &adec, ENV_A)
	old, old_dec := login_env(t, &server, "token-caller-legacy", "client-legacy", .Caller)
	defer trans.connection_destroy(old)
	defer proto.decoder_destroy(&old_dec)
	send_connect(t, old, ENV_SERVICE)
	fail := must_read_opcode(t, old, &old_dec, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, fail), proto.WireError.ServiceNotFound)
	proto.frame_destroy(&fail)
	expect_no_frame(t, agent_a, &adec)

	// Empty-environment registration resolves only for its account caller.
	register_env_service(t, legacy, &ldec, "")
	send_connect(t, old, ENV_SERVICE)
	finish_open(t, legacy, &ldec, old, &old_dec)
	expect_no_frame(t, agent_a, &adec)

	other, other_dec := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(other)
	defer proto.decoder_destroy(&other_dec)
	expect_connect_not_found(t, other, &other_dec)
	expect_no_frame(t, legacy, &ldec)
	expect_no_frame(t, agent_a, &adec)

	// The environment caller still resolves its scoped name.
	caller_a, adec_c := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&adec_c)
	send_connect(t, caller_a, ENV_SERVICE)
	finish_open(t, agent_a, &adec, caller_a, &adec_c)
	expect_no_frame(t, legacy, &ldec)
}

@(test)
test_same_environment_collision_is_service_already_registered :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-agent-a2", id = "host-a2", environment = ENV_A},
		{token = "token-agent-b", id = "host-b", environment = ENV_B},
	}
	table := EnvTable {
		creds = creds[:],
	}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&dec_a)
	agent_a2, dec_a2 := login_env(t, &server, "token-agent-a2", "host-a2", .Agent)
	defer trans.connection_destroy(agent_a2)
	defer proto.decoder_destroy(&dec_a2)
	agent_b, dec_b := login_env(t, &server, "token-agent-b", "host-b", .Agent)
	defer trans.connection_destroy(agent_b)
	defer proto.decoder_destroy(&dec_b)

	register_env_service(t, agent_a, &dec_a, ENV_A)
	send_register(t, agent_a2, ENV_SERVICE)
	fail := must_read_opcode(t, agent_a2, &dec_a2, .RegisterFailed)
	wire, err := proto.decode_wire_failure(fail.payload)
	testing.expect_value(t, err, proto.ProtocolError.None)
	code, ok := proto.wire_error_from_u16(wire.code)
	testing.expect(t, ok)
	testing.expect_value(t, code, proto.WireError.ServiceAlreadyRegistered)
	testing.expect_value(t, wire.diagnostic, wire_error_diagnostic(.ServiceAlreadyRegistered))
	delete(wire.diagnostic)
	proto.frame_destroy(&fail)

	// The other environment is a different namespace.
	register_env_service(t, agent_b, &dec_b, ENV_B)
}

expect_connect_not_found :: proc(t: ^testing.T, caller: ^trans.Connection, decoder: ^proto.FrameDecoder) {
	send_connect(t, caller, ENV_SERVICE)
	fail := must_read_opcode(t, caller, decoder, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, fail), proto.WireError.ServiceNotFound)
	proto.frame_destroy(&fail)
}

@(test)
test_empty_environment_accounts_route_only_their_own_service :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", organization = "org/a"},
		{token = "token-agent-b", id = "host-b", organization = "org/b"},
		{token = "token-caller-a", id = "client-a", organization = "org/a"},
		{token = "token-caller-b", id = "client-b", organization = "org/b"},
		{token = "token-scoped-b", id = "scoped-b", organization = "org/b", environment = ENV_B},
	}
	table := EnvTable{creds = creds[:]}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&dec_a)
	agent_b, dec_b := login_env(t, &server, "token-agent-b", "host-b", .Agent)
	defer trans.connection_destroy(agent_b)
	defer proto.decoder_destroy(&dec_b)
	caller_a, cdec_a := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&cdec_a)
	caller_b, cdec_b := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&cdec_b)
	scoped_b, sdec_b := login_env(t, &server, "token-scoped-b", "scoped-b", .Caller)
	defer trans.connection_destroy(scoped_b)
	defer proto.decoder_destroy(&sdec_b)

	register_env_service(t, agent_a, &dec_a, "")
	route_service_and_close(t, caller_a, &cdec_a, agent_a, &dec_a)
	// Neither B caller can reach A, and no OPEN or data reaches A.
	expect_connect_not_found(t, caller_b, &cdec_b)
	expect_connect_not_found(t, scoped_b, &sdec_b)
	expect_no_frame(t, agent_a, &dec_a)

	register_env_service(t, agent_b, &dec_b, "")
	route_service_and_close(t, caller_b, &cdec_b, agent_b, &dec_b)
	expect_no_frame(t, agent_a, &dec_a)
	route_service_and_close(t, caller_a, &cdec_a, agent_a, &dec_a)
	expect_no_frame(t, agent_b, &dec_b)
	// Even its own account's empty-environment name is not a scoped fallback.
	expect_connect_not_found(t, scoped_b, &sdec_b)
	expect_no_frame(t, agent_a, &dec_a)
	expect_no_frame(t, agent_b, &dec_b)

	unregister_ok(t, agent_a, &dec_a)
	expect_connect_not_found(t, caller_a, &cdec_a)
	route_service_and_close(t, caller_b, &cdec_b, agent_b, &dec_b)
	expect_no_frame(t, agent_a, &dec_a)
}

// Environment B must reach neither A's scoped name nor an account name.
@(test)
test_other_environment_cannot_reach_account_or_scoped :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-agent-global", id = "host-global", environment = ""},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
	}
	table := EnvTable{creds = creds[:]}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&dec_a)
	global, gdec := login_env(t, &server, "token-agent-global", "host-global", .Agent)
	defer trans.connection_destroy(global)
	defer proto.decoder_destroy(&gdec)
	register_env_service(t, agent_a, &dec_a, ENV_A)
	register_env_service(t, global, &gdec, "")

	caller_b, cdec := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&cdec)
	expect_connect_not_found(t, caller_b, &cdec)
	expect_no_frame(t, global, &gdec)
	expect_no_frame(t, agent_a, &dec_a)
}

// No global name. B cannot dial A's scoped registration.
@(test)
test_other_environment_cannot_reach_scoped_service :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-caller-a", id = "client-a", environment = ENV_A},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
	}
	table := EnvTable{creds = creds[:]}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&dec_a)
	register_env_service(t, agent_a, &dec_a, ENV_A)

	caller_b, bdec := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&bdec)
	expect_connect_not_found(t, caller_b, &bdec)
	expect_no_frame(t, agent_a, &dec_a)

	caller_a, adec := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&adec)
	send_connect(t, caller_a, ENV_SERVICE)
	finish_open(t, agent_a, &dec_a, caller_a, &adec)
}

@(test)
test_other_environment_misses_scoped_service_across_reconnect :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-caller-a", id = "client-a", environment = ENV_A},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
	}
	table := EnvTable{creds = creds[:]}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	register_env_service(t, agent_a, &dec_a, ENV_A)

	caller_b, bdec := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&bdec)
	expect_connect_not_found(t, caller_b, &bdec)
	expect_no_frame(t, agent_a, &dec_a)

	proto.decoder_destroy(&dec_a)
	trans.connection_destroy(agent_a)

	svc := must_service_id(t, ENV_SERVICE)
	deadline := time.now()
	gone := false
	for time.since(deadline) < 2 * time.Second {
		_, found := lookup_service_for_environment(&reg, ENV_A, svc)
		if !found {
			gone = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, gone, "scoped registration survived the agent disconnect")
	expect_connect_not_found(t, caller_b, &bdec)

	agent_a2, dec_a2 := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a2)
	defer proto.decoder_destroy(&dec_a2)
	register_env_service(t, agent_a2, &dec_a2, ENV_A)
	expect_connect_not_found(t, caller_b, &bdec)
	expect_no_frame(t, agent_a2, &dec_a2)

	caller_a, adec := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&adec)
	send_connect(t, caller_a, ENV_SERVICE)
	finish_open(t, agent_a2, &dec_a2, caller_a, &adec)
}

@(test)
test_unregister_does_not_publish_scoped_service_elsewhere :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-agent-b", id = "host-b", environment = ENV_B},
		{token = "token-caller-a", id = "client-a", environment = ENV_A},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
		{token = "token-caller-legacy", id = "client-legacy", environment = ""},
	}
	table := EnvTable{creds = creds[:]}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&dec_a)
	agent_b, dec_b := login_env(t, &server, "token-agent-b", "host-b", .Agent)
	defer trans.connection_destroy(agent_b)
	defer proto.decoder_destroy(&dec_b)
	register_env_service(t, agent_a, &dec_a, ENV_A)
	register_env_service(t, agent_b, &dec_b, ENV_B)

	caller_b, bdec := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&bdec)
	send_connect(t, caller_b, ENV_SERVICE)
	finish_open(t, agent_b, &dec_b, caller_b, &bdec)
	expect_no_frame(t, agent_a, &dec_a)

	send_unregister(t, agent_a, ENV_SERVICE)
	unreg := must_read_opcode(t, agent_a, &dec_a, .UnregisterOk)
	ok_msg, oerr := proto.decode_unregister_ok(unreg.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None)
	testing.expect_value(t, string(ok_msg.service_id), ENV_SERVICE)
	delete(string(ok_msg.service_id))
	proto.frame_destroy(&unreg)

	svc := must_service_id(t, ENV_SERVICE)
	_, global := lookup_service(&reg, svc)
	testing.expect(t, !global)
	_, still_a := lookup_service_for_environment(&reg, ENV_A, svc)
	testing.expect(t, !still_a)
	rec_b, ok_b := lookup_service_for_environment(&reg, ENV_B, svc)
	testing.expect(t, ok_b)
	testing.expect_value(t, string(rec_b.owner), "host-b")

	caller_a, adec := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&adec)
	expect_connect_not_found(t, caller_a, &adec)
	expect_no_frame(t, agent_b, &dec_b)

	legacy, ldec := login_env(t, &server, "token-caller-legacy", "client-legacy", .Caller)
	defer trans.connection_destroy(legacy)
	defer proto.decoder_destroy(&ldec)
	expect_connect_not_found(t, legacy, &ldec)
	expect_no_frame(t, agent_a, &dec_a)
	expect_no_frame(t, agent_b, &dec_b)
}

unregister_ok :: proc(t: ^testing.T, conn: ^trans.Connection, dec: ^proto.FrameDecoder) {
	send_unregister(t, conn, ENV_SERVICE)
	f := must_read_opcode(t, conn, dec, .UnregisterOk)
	msg, err := proto.decode_unregister_ok(f.payload)
	testing.expect_value(t, err, proto.ProtocolError.None)
	delete(string(msg.service_id))
	proto.frame_destroy(&f)
}

// Open on agent, then CLOSE so the next step does not see a leftover frame.
route_service_and_close :: proc(
	t: ^testing.T,
	caller: ^trans.Connection,
	cdec: ^proto.FrameDecoder,
	agent: ^trans.Connection,
	adec: ^proto.FrameDecoder,
) {
	_ = trans.connection_set_recv_timeout(agent, 2 * time.Second)
	_ = trans.connection_set_recv_timeout(caller, 2 * time.Second)
	send_connect(t, caller, ENV_SERVICE)
	open_frame := must_read_opcode(t, agent, adec, .Open)
	sid := open_frame.header.stream_id
	proto.frame_destroy(&open_frame)
	must_write_stream(t, agent, .OpenOk, nil, sid)
	ok_frame := must_read_opcode(t, caller, cdec, .ConnectOk)
	testing.expect_value(t, ok_frame.header.stream_id, sid)
	proto.frame_destroy(&ok_frame)
	must_write_stream(t, caller, .Close, nil, sid)
	cl := must_read_opcode(t, agent, adec, .Close)
	proto.frame_destroy(&cl)
}

// B and an empty-environment account agent UNREGISTER "api" they never registered.
// A's scoped registration stays, and only A's caller reaches it.
@(test)
test_foreign_unregister_cannot_remove_scoped :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-agent-b", id = "host-b", environment = ENV_B},
		{token = "token-agent-global", id = "host-global", environment = ""},
		{token = "token-caller-a", id = "client-a", environment = ENV_A},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
	}
	table := EnvTable{creds = creds[:]}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a)
	defer proto.decoder_destroy(&dec_a)
	agent_b, dec_b := login_env(t, &server, "token-agent-b", "host-b", .Agent)
	defer trans.connection_destroy(agent_b)
	defer proto.decoder_destroy(&dec_b)
	global, gdec := login_env(t, &server, "token-agent-global", "host-global", .Agent)
	defer trans.connection_destroy(global)
	defer proto.decoder_destroy(&gdec)
	register_env_service(t, agent_a, &dec_a, ENV_A)

	unregister_ok(t, agent_b, &dec_b)
	unregister_ok(t, global, &gdec)
	svc := must_service_id(t, ENV_SERVICE)
	rec, ok := lookup_service_for_environment(&reg, ENV_A, svc)
	testing.expect(t, ok, "A's scoped name removed by a foreign UNREGISTER")
	testing.expect_value(t, string(rec.owner), "host-a")

	caller_b, bdec := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&bdec)
	expect_connect_not_found(t, caller_b, &bdec)
	expect_no_frame(t, agent_a, &dec_a)

	caller_a, cadec := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&cadec)
	send_connect(t, caller_a, ENV_SERVICE)
	finish_open(t, agent_a, &dec_a, caller_a, &cadec)
}

// An account name must not become an environment fallback when a scoped
// registration disappears, or when it reconnects.
@(test)
test_scoped_disconnect_does_not_fall_back_to_account :: proc(t: ^testing.T) {
	creds := [?]EnvCred {
		{token = "token-agent-a", id = "host-a", environment = ENV_A},
		{token = "token-agent-global", id = "host-global", environment = ""},
		{token = "token-caller-a", id = "client-a", environment = ENV_A},
		{token = "token-caller-b", id = "client-b", environment = ENV_B},
	}
	table := EnvTable{creds = creds[:]}
	reg: Registry
	server: Server
	start_env_broker(t, &server, &reg, &table)
	defer stop_env_broker(&server, &reg)

	global, gdec := login_env(t, &server, "token-agent-global", "host-global", .Agent)
	defer trans.connection_destroy(global)
	defer proto.decoder_destroy(&gdec)
	register_env_service(t, global, &gdec, "")
	agent_a, dec_a := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	register_env_service(t, agent_a, &dec_a, ENV_A)

	caller_a, cadec := login_env(t, &server, "token-caller-a", "client-a", .Caller)
	defer trans.connection_destroy(caller_a)
	defer proto.decoder_destroy(&cadec)
	caller_b, bdec := login_env(t, &server, "token-caller-b", "client-b", .Caller)
	defer trans.connection_destroy(caller_b)
	defer proto.decoder_destroy(&bdec)

	route_service_and_close(t, caller_a, &cadec, agent_a, &dec_a)
	expect_no_frame(t, global, &gdec)
	expect_connect_not_found(t, caller_b, &bdec)
	expect_no_frame(t, agent_a, &dec_a)

	proto.decoder_destroy(&dec_a)
	trans.connection_destroy(agent_a)
	svc := must_service_id(t, ENV_SERVICE)
	start := time.now()
	removed := false
	for time.since(start) < 2 * time.Second {
		_, ok := lookup_service_for_environment(&reg, ENV_A, svc, ENV_ORG)
		if !ok {
			removed = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, removed, "scoped registration survived disconnect")
	expect_connect_not_found(t, caller_a, &cadec)
	expect_no_frame(t, global, &gdec)

	agent_a2, dec_a2 := login_env(t, &server, "token-agent-a", "host-a", .Agent)
	defer trans.connection_destroy(agent_a2)
	defer proto.decoder_destroy(&dec_a2)
	register_env_service(t, agent_a2, &dec_a2, ENV_A)
	expect_connect_not_found(t, caller_b, &bdec)
	expect_no_frame(t, agent_a2, &dec_a2)
	route_service_and_close(t, caller_a, &cadec, agent_a2, &dec_a2)
	expect_no_frame(t, global, &gdec)
}
