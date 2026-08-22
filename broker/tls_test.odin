package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Test-only self-signed PEMs. Not for production.
BROKER_TEST_CERT :: string(#load("../transport/testdata/test_server.crt"))
BROKER_TEST_KEY :: string(#load("../transport/testdata/test_server.key"))

broker_tls_temp_seq: int

broker_write_temp_pem :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&broker_tls_temp_seq, 1)
	path = fmt.aprintf("/tmp/thirp-broker-tls-%s-%d.pem", label, n)
	err := os.write_entire_file(path, transmute([]u8)contents)
	if err != nil {
		delete(path)
		return "", false
	}
	return path, true
}

broker_remove_temp_pem :: proc(path: string) {
	_ = os.remove(path)
	delete(path)
}

start_tls_test_server :: proc(
	t: ^testing.T,
	server: ^Server,
	reg: ^Registry,
	store: ^auth.StaticTokenAuth,
	loc := #caller_location,
) -> (
	cert_path: string,
	key_path: string,
) {
	cert_ok: bool
	cert_path, cert_ok = broker_write_temp_pem("cert", BROKER_TEST_CERT)
	testing.expect(t, cert_ok, loc = loc)
	key_ok: bool
	key_path, key_ok = broker_write_temp_pem("key", BROKER_TEST_KEY)
	testing.expect(t, key_ok, loc = loc)

	must_init_registry(t, reg, loc)
	testing.expect_value(t, auth.auth_init(store), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_HOST, PRINCIPAL_HOST), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(store, TOKEN_CALLER, PRINCIPAL_CALLER), auth.AuthError.None, loc)
	server_init(server, reg, auth.static_token_authenticator(store))
	server_disable_test_hardening(server)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second

	ctx, ctx_err := trans.tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, ctx_err, trans.TransportError.None, loc)
	testing.expect(t, ctx != nil, loc = loc)
	server.tls_ctx = ctx

	testing.expect_value(t, server_listen(server, trans.loopback_endpoint(0)), trans.TransportError.None, loc)
	server_start(server)
	return
}

dial_server_tls :: proc(
	t: ^testing.T,
	server: ^Server,
	cert_path: string,
	loc := #caller_location,
) -> ^trans.Connection {
	ep, eerr := server_endpoint(server)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	cfg := trans.TlsClientConfig {
		ca_path     = cert_path,
		server_name = "127.0.0.1",
	}
	conn, derr := trans.connection_dial_tls(ep, cfg)
	testing.expect_value(t, derr, trans.TransportError.None, loc)
	testing.expect(t, conn != nil, loc = loc)
	return conn
}

@(test)
test_tls_agent_register_succeeds :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	cert_path, key_path := start_tls_test_server(t, &server, &reg, &store)
	defer {
		stop_test_server(&server, &store, &reg)
		broker_remove_temp_pem(cert_path)
		broker_remove_temp_pem(key_path)
	}

	conn := dial_server_tls(t, &server, cert_path)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)
}

@(test)
test_tls_relay_echo_bytes_match :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	cert_path, key_path := start_tls_test_server(t, &server, &reg, &store)
	defer {
		stop_test_server(&server, &store, &reg)
		broker_remove_temp_pem(cert_path)
		broker_remove_temp_pem(key_path)
	}

	echo_ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	defer trans.listener_close(&echo_ln)
	_ = trans.listener_set_recv_timeout(&echo_ln, 2 * time.Second)
	echo_ep, eerr := trans.listener_endpoint(echo_ln)
	testing.expect_value(t, eerr, trans.TransportError.None)

	worker := EchoWorker{ln = &echo_ln}
	echo_thread := thread.create_and_start_with_poly_data(&worker, echo_accept_and_mirror)
	defer {
		thread.join(echo_thread)
		thread.destroy(echo_thread)
	}

	agent := dial_server_tls(t, &server, cert_path)
	defer trans.connection_destroy(agent)
	agent_dec: proto.FrameDecoder
	handshake_agent(t, agent, &agent_dec)
	defer proto.decoder_destroy(&agent_dec)
	send_register(t, agent, TEST_SERVICE)
	reg_ok := must_read_opcode(t, agent, &agent_dec, .RegisterOk)
	delete(string((proto.decode_register_ok(reg_ok.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&reg_ok)

	caller := dial_server_tls(t, &server, cert_path)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, TEST_SERVICE)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	stream_id := open_frame.header.stream_id
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)

	local, derr := trans.connection_dial(echo_ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(local)
	_ = trans.connection_set_recv_timeout(local, 2 * time.Second)

	must_write_stream(t, agent, .OpenOk, nil, stream_id)
	ok_frame := must_read_opcode(t, caller, &caller_dec, .ConnectOk)
	testing.expect_value(t, ok_frame.header.stream_id, stream_id)
	proto.frame_destroy(&ok_frame)

	payload := []u8{'h', 'e', 'l', 'l', 'o'}
	must_write_stream(t, caller, .Data, payload, stream_id)

	data_frame := must_read_opcode(t, agent, &agent_dec, .Data)
	testing.expect_value(t, data_frame.header.stream_id, stream_id)
	testing.expect_value(t, string(data_frame.payload), "hello")
	testing.expect_value(t, trans.connection_write(local, data_frame.payload), trans.TransportError.None)
	proto.frame_destroy(&data_frame)

	buf: [16]u8
	n, rerr := trans.connection_read(local, buf[:])
	testing.expect_value(t, rerr, trans.TransportError.None)
	testing.expect_value(t, string(buf[:n]), "hello")
	must_write_stream(t, agent, .Data, buf[:n], stream_id)

	echoed := must_read_opcode(t, caller, &caller_dec, .Data)
	testing.expect_value(t, echoed.header.stream_id, stream_id)
	testing.expect_value(t, string(echoed.payload), "hello")
	proto.frame_destroy(&echoed)
}
