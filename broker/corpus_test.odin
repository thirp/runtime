package broker

import auth "../auth"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_corpus_malformed_handshake_does_not_leak_registry :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	samples := [][]u8 {
		{},
		{1},
		{1, 20},
		{1, 20, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0},
		{0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 20, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{1, 16, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		{1, 16, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 'l', 'e', 'f', 't', 'o', 'v', 'e', 'r'},
	}
	for sample in samples {
		conn := dial_server(t, &server)
		_ = trans.connection_write(conn, sample)
		time.sleep(20 * time.Millisecond)
		trans.connection_destroy(conn)
	}

	conn := dial_server(t, &server)
	send_register(t, conn, TEST_SERVICE)
	time.sleep(20 * time.Millisecond)
	trans.connection_destroy(conn)

	auth_conn := dial_server(t, &server)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None)
	send_hello(t, auth_conn, .Caller)
	ack := must_read_opcode(t, auth_conn, &decoder, .HelloAck)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)
	must_write_stream(t, auth_conn, .Data, []u8{'x'}, proto.make_stream_id(1))
	time.sleep(20 * time.Millisecond)
	proto.decoder_destroy(&decoder)
	trans.connection_destroy(auth_conn)

	secret_conn := dial_server(t, &server)
	secret_dec: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&secret_dec), proto.ProtocolError.None)
	send_hello(t, secret_conn, .Caller)
	sack := must_read_opcode(t, secret_conn, &secret_dec, .HelloAck)
	smsg, serr := proto.decode_hello_ack(sack.payload)
	testing.expect_value(t, serr, proto.ProtocolError.None)
	delete(smsg.implementation)
	proto.frame_destroy(&sack)
	send_authenticate(t, secret_conn, "corpus-secret-token-xyz")
	fail := must_read_frame(t, secret_conn, &secret_dec)
	proto.frame_destroy(&fail)
	proto.decoder_destroy(&secret_dec)
	trans.connection_destroy(secret_conn)

	testing.expect(t, server_wait_idle(&server, 2 * time.Second))
	services, sessions, _ := registry_metrics(server.registry)
	testing.expect_value(t, services, 0)
	testing.expect_value(t, sessions, 0)

	logs := obs_wait_contains(LOG_EVENT_AUTH_FAILED, 2 * time.Second)
	defer delete(logs)
	testing.expect(t, !strings.contains(logs, "corpus-secret-token-xyz"))
	testing.expect(t, !strings.contains(logs, TOKEN_HOST))
	testing.expect(t, !strings.contains(logs, TOKEN_CALLER))
}
