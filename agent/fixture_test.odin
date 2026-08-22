package agent

import auth "../auth"
import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

TEST_TOKEN_HOST :: "host-dev-token"
TEST_TOKEN_CALLER :: "caller-dev-token"
TEST_PRINCIPAL_HOST :: "host-a"
TEST_PRINCIPAL_CALLER :: "client-a"
TEST_SERVICE :: "demo/echo"

TestBroker :: struct {
	reg:    brk.Registry,
	store:  auth.StaticTokenAuth,
	server: brk.Server,
}

EchoWorker :: struct {
	ln: ^trans.Listener,
}

EchoFixture :: struct {
	ln:     trans.Listener,
	worker: EchoWorker,
	th:     ^thread.Thread,
}

AgentRunArg :: struct {
	agent: ^Agent,
}

start_test_broker :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) {
	testing.expect_value(t, brk.registry_init(&fx.reg), brk.RegistryError.None, loc)
	testing.expect_value(t, auth.auth_init(&fx.store), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(&fx.store, TEST_TOKEN_HOST, TEST_PRINCIPAL_HOST), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(&fx.store, TEST_TOKEN_CALLER, TEST_PRINCIPAL_CALLER), auth.AuthError.None, loc)
	brk.server_init(&fx.server, &fx.reg, auth.static_token_authenticator(&fx.store))
	brk.server_disable_test_hardening(&fx.server)
	fx.server.heartbeat_interval = 30 * time.Second
	fx.server.session_timeout = 30 * time.Second
	testing.expect_value(t, brk.server_listen(&fx.server, trans.loopback_endpoint(0)), trans.TransportError.None, loc)
	brk.server_start(&fx.server)
}

stop_test_broker :: proc(fx: ^TestBroker) {
	brk.server_stop(&fx.server)
	_ = brk.server_wait_idle(&fx.server, 2 * time.Second)
	brk.server_destroy(&fx.server)
	auth.auth_destroy(&fx.store)
	brk.registry_destroy(&fx.reg)
}

broker_endpoint :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) -> net.Endpoint {
	ep, err := brk.server_endpoint(&fx.server)
	testing.expect_value(t, err, trans.TransportError.None, loc)
	return ep
}

start_echo :: proc(t: ^testing.T, fx: ^EchoFixture, loc := #caller_location) -> net.Endpoint {
	lerr: trans.TransportError
	fx.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	_ = trans.listener_set_recv_timeout(&fx.ln, 50 * time.Millisecond)
	ep, eerr := trans.listener_endpoint(fx.ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	fx.worker.ln = &fx.ln
	fx.th = thread.create_and_start_with_poly_data(&fx.worker, echo_accept_loop)
	return ep
}

stop_echo :: proc(fx: ^EchoFixture) {
	trans.listener_close(&fx.ln)
	if fx.th != nil {
		thread.join(fx.th)
		thread.destroy(fx.th)
		fx.th = nil
	}
}

echo_accept_loop :: proc(w: ^EchoWorker) {
	for {
		conn, err := trans.listener_accept(w.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		thread.run_with_poly_data(conn, echo_mirror_one)
	}
}

echo_mirror_one :: proc(conn: ^trans.Connection) {
	defer trans.connection_destroy(conn)
	buf: [1024]u8
	for {
		n, err := trans.connection_read(conn, buf[:])
		if err != .None {
			return
		}
		if trans.connection_write(conn, buf[:n]) != .None {
			return
		}
	}
}

agent_run_proc :: proc(arg: ^AgentRunArg) {
	_ = agent_run(arg.agent)
}

wait_agent_connected :: proc(t: ^testing.T, agent: ^Agent, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		if agent_is_connected(agent) {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, loc = loc)
}

must_service :: proc(t: ^testing.T, value: string, loc := #caller_location) -> proto.ServiceId {
	id, err := proto.make_service_id(value)
	testing.expect_value(t, err, proto.ServiceIdError.None, loc)
	return id
}

dial_broker :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) -> ^trans.Connection {
	ep := broker_endpoint(t, fx, loc)
	conn, err := trans.connection_dial(ep)
	testing.expect_value(t, err, trans.TransportError.None, loc)
	testing.expect(t, conn != nil, loc = loc)
	return conn
}

must_write :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId = proto.CONNECTION_STREAM_ID,
	loc := #caller_location,
) {
	terr, perr := trans.write_frame(conn, opcode, payload, stream_id)
	testing.expect_value(t, terr, trans.TransportError.None, loc)
	testing.expect_value(t, perr, proto.ProtocolError.None, loc)
}

must_read_opcode :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	opcode: proto.Opcode,
	loc := #caller_location,
) -> proto.Frame {
	_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
	frame, terr, perr := trans.read_frame(conn, decoder)
	testing.expect_value(t, terr, trans.TransportError.None, loc)
	testing.expect_value(t, perr, proto.ProtocolError.None, loc)
	testing.expect_value(t, frame.header.opcode, opcode, loc)
	return frame
}

handshake_caller :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	loc := #caller_location,
) {
	testing.expect_value(t, proto.decoder_init(decoder), proto.ProtocolError.None, loc)
	payload, err := proto.encode_hello(
		proto.Hello {
			major           = proto.PROTOCOL_MAJOR,
			minor           = proto.PROTOCOL_MINOR,
			role            = .Caller,
			capability_bits = 0,
			implementation  = "test-caller",
		},
	)
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	must_write(t, conn, .Hello, payload, proto.CONNECTION_STREAM_ID, loc)
	delete(payload)
	ack := must_read_opcode(t, conn, decoder, .HelloAck, loc)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None, loc)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)

	token := TEST_TOKEN_CALLER
	tok := ([^]u8)(raw_data(token))[:len(token)]
	auth_payload, auerr := proto.encode_authenticate(proto.Authenticate{token = tok})
	testing.expect_value(t, auerr, proto.ProtocolError.None, loc)
	must_write(t, conn, .Authenticate, auth_payload, proto.CONNECTION_STREAM_ID, loc)
	delete(auth_payload)
	ok_frame := must_read_opcode(t, conn, decoder, .AuthenticateOk, loc)
	ok_msg, oerr := proto.decode_authenticate_ok(ok_frame.payload)
	testing.expect_value(t, oerr, proto.ProtocolError.None, loc)
	delete(ok_msg.principal_id)
	proto.frame_destroy(&ok_frame)
}

caller_connect_ok :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	service: string,
	loc := #caller_location,
) -> proto.StreamId {
	id := must_service(t, service, loc)
	payload, err := proto.encode_connect(proto.Connect{service_id = id})
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	must_write(t, conn, .Connect, payload, proto.CONNECTION_STREAM_ID, loc)
	delete(payload)
	ok := must_read_opcode(t, conn, decoder, .ConnectOk, loc)
	sid := ok.header.stream_id
	proto.frame_destroy(&ok)
	return sid
}
