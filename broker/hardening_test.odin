package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:testing"
import "core:time"

read_agent_data_skipping_reset :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	want_sid: proto.StreamId,
	idle_sid: proto.StreamId,
	loc := #caller_location,
) -> proto.Frame {
	for _ in 0 ..< 8 {
		frame := must_read_frame(t, conn, decoder, loc)
		if frame.header.opcode == .Reset && frame.header.stream_id == idle_sid {
			proto.frame_destroy(&frame)
			continue
		}
		testing.expect_value(t, frame.header.opcode, proto.Opcode.Data, loc)
		testing.expect_value(t, frame.header.stream_id, want_sid, loc)
		return frame
	}
	testing.expect(t, false, loc = loc)
	return {}
}

hello_then_auth :: proc(
	t: ^testing.T,
	server: ^Server,
	token: string,
	loc := #caller_location,
) -> (
	^trans.Connection,
	proto.FrameDecoder,
) {
	conn := dial_server(t, server, loc)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None, loc)
	send_hello(t, conn, .Caller, proto.PROTOCOL_MAJOR, loc)
	ack := must_read_opcode(t, conn, &decoder, .HelloAck, loc)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None, loc)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)
	send_authenticate(t, conn, token, loc)
	return conn, decoder
}

@(test)
test_hardening_auth_burst_rate_limited :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.auth_rate = rate_limit_config(2, time.Hour)

	for _ in 0 ..< 2 {
		conn, decoder := hello_then_auth(t, &server, "bad-token")
		fail := must_read_opcode(t, conn, &decoder, .AuthenticateFailed)
		testing.expect_value(t, read_wire_failure(t, fail), proto.WireError.AuthenticationFailed)
		proto.frame_destroy(&fail)
		proto.decoder_destroy(&decoder)
		trans.connection_destroy(conn)
	}

	conn, decoder := hello_then_auth(t, &server, "bad-token")
	fail := must_read_opcode(t, conn, &decoder, .AuthenticateFailed)
	testing.expect_value(t, read_wire_failure(t, fail), proto.WireError.RateLimited)
	proto.frame_destroy(&fail)
	proto.decoder_destroy(&decoder)
	trans.connection_destroy(conn)

	valid, valid_dec := hello_then_auth(t, &server, TOKEN_CALLER)
	limited := must_read_opcode(t, valid, &valid_dec, .AuthenticateFailed)
	testing.expect_value(t, read_wire_failure(t, limited), proto.WireError.RateLimited)
	proto.frame_destroy(&limited)
	proto.decoder_destroy(&valid_dec)
	trans.connection_destroy(valid)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.rate_limit_exceeds[.Authentication] >= 1)
}

@(test)
test_hardening_register_burst_keeps_connection :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.register_rate = rate_limit_config(2, time.Hour)

	agent := dial_server(t, &server)
	defer trans.connection_destroy(agent)
	decoder: proto.FrameDecoder
	handshake_agent(t, agent, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, agent, "demo/a")
	ok1 := must_read_opcode(t, agent, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok1.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok1)

	send_unregister(t, agent, "demo/a")
	ok2 := must_read_opcode(t, agent, &decoder, .UnregisterOk)
	delete(string((proto.decode_unregister_ok(ok2.payload) or_else proto.UnregisterOk{}).service_id))
	proto.frame_destroy(&ok2)

	send_register(t, agent, "demo/b")
	fail := must_read_opcode(t, agent, &decoder, .RegisterFailed)
	testing.expect_value(t, read_wire_failure(t, fail), proto.WireError.RateLimited)
	proto.frame_destroy(&fail)

	payload, perr := proto.encode_ping(proto.Ping{nonce = 1})
	testing.expect_value(t, perr, proto.ProtocolError.None)
	defer delete(payload)
	must_write_opcode(t, agent, .Ping, payload)
	pong := must_read_opcode(t, agent, &decoder, .Pong)
	proto.frame_destroy(&pong)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.rate_limit_exceeds[.Registration] >= 1)
	testing.expect(t, snap.registration_failures[.RateLimited] >= 1)
}

@(test)
test_hardening_connect_burst_including_not_found :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.connect_rate = rate_limit_config(2, time.Hour)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_connect(t, caller, "demo/missing")
	f1 := must_read_opcode(t, caller, &decoder, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, f1), proto.WireError.ServiceNotFound)
	proto.frame_destroy(&f1)

	send_connect(t, caller, "demo/missing")
	f2 := must_read_opcode(t, caller, &decoder, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, f2), proto.WireError.ServiceNotFound)
	proto.frame_destroy(&f2)

	send_connect(t, caller, "demo/missing")
	f3 := must_read_opcode(t, caller, &decoder, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, f3), proto.WireError.RateLimited)
	proto.frame_destroy(&f3)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.rate_limit_exceeds[.Connect] >= 1)
	testing.expect(t, snap.connection_failures[.RateLimited] >= 1)
}

@(test)
test_hardening_connect_ip_limiter_two_principals :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.connect_rate = rate_limit_config(1, time.Hour)
	testing.expect_value(t, auth.auth_add_token(&store, "caller-2-token", "client-2"), auth.AuthError.None)

	a := dial_server(t, &server)
	defer trans.connection_destroy(a)
	dec_a: proto.FrameDecoder
	handshake_as(t, a, &dec_a, .Caller, TOKEN_CALLER, PRINCIPAL_CALLER)
	defer proto.decoder_destroy(&dec_a)
	send_connect(t, a, "demo/missing")
	f1 := must_read_opcode(t, a, &dec_a, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, f1), proto.WireError.ServiceNotFound)
	proto.frame_destroy(&f1)

	b := dial_server(t, &server)
	defer trans.connection_destroy(b)
	dec_b: proto.FrameDecoder
	handshake_as(t, b, &dec_b, .Caller, "caller-2-token", "client-2")
	defer proto.decoder_destroy(&dec_b)
	send_connect(t, b, "demo/missing")
	f2 := must_read_opcode(t, b, &dec_b, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, f2), proto.WireError.RateLimited)
	proto.frame_destroy(&f2)
}

@(test)
test_hardening_echo_connect_with_limits_disabled :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	send_connect(t, caller, TEST_SERVICE)
	ok := must_read_opcode(t, caller, &decoder, .ConnectOk)
	sid := ok.header.stream_id
	proto.frame_destroy(&ok)
	must_write_stream(t, caller, .Data, []u8{'o', 'k'}, sid)
	echoed := must_read_opcode(t, caller, &decoder, .Data)
	testing.expect_value(t, string(echoed.payload), "ok")
	proto.frame_destroy(&echoed)
}

@(test)
test_hardening_connect_rejected_at_global_buffer_ceiling :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)

	server.max_buffered_bytes = 8
	sync.atomic_store(&server.buffered_bytes, 8)

	send_connect(t, caller, "demo/missing")
	fail := must_read_opcode(t, caller, &decoder, .ConnectFailed)
	testing.expect_value(t, read_wire_failure(t, fail), proto.WireError.QuotaExceeded)
	proto.frame_destroy(&fail)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.limit_exceeds[.GlobalBuffer] >= 1)
	testing.expect(t, snap.connection_failures[.QuotaExceeded] >= 1)
}

@(test)
test_hardening_accept_closed_at_global_buffer_ceiling :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	held := dial_server(t, &server)
	defer trans.connection_destroy(held)
	server.max_buffered_bytes = 1
	sync.atomic_store(&server.buffered_bytes, 1)

	second := dial_server(t, &server)
	defer trans.connection_destroy(second)
	_ = trans.connection_set_recv_timeout(second, 500 * time.Millisecond)
	buf: [8]u8
	_, rerr := trans.connection_read(second, buf[:])
	testing.expect_value(t, rerr, trans.TransportError.Closed)
}

@(test)
test_hardening_stream_idle_resets_idle_sibling_stays :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.stream_idle_timeout = 80 * time.Millisecond

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
	handshake_caller(t, c2, &d2)
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
	testing.expect(t, snap.resets[.StreamIdle] >= 1)
}

@(test)
test_hardening_stream_idle_zero_does_not_reset :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.stream_idle_timeout = 0

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	sid := open_test_stream(t, agent, &agent_dec, caller, &decoder)
	time.sleep(120 * time.Millisecond)
	must_write_stream(t, caller, .Data, []u8{'x'}, sid)
	got := must_read_opcode(t, agent, &agent_dec, .Data)
	testing.expect_value(t, got.header.stream_id, sid)
	testing.expect_value(t, string(got.payload), "x")
	proto.frame_destroy(&got)
}
