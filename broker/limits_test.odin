package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:time"

@(test)
test_limits_second_stream_quota_exceeded :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.max_streams_per_session = 1

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	caller1 := dial_server(t, &server)
	defer trans.connection_destroy(caller1)
	dec1: proto.FrameDecoder
	handshake_caller(t, caller1, &dec1)
	defer proto.decoder_destroy(&dec1)

	send_connect(t, caller1, TEST_SERVICE)
	ok := must_read_opcode(t, caller1, &dec1, .ConnectOk)
	stream_id := ok.header.stream_id
	proto.frame_destroy(&ok)

	caller2 := dial_server(t, &server)
	defer trans.connection_destroy(caller2)
	dec2: proto.FrameDecoder
	handshake_caller(t, caller2, &dec2)
	defer proto.decoder_destroy(&dec2)

	send_connect(t, caller2, TEST_SERVICE)
	fail := must_read_opcode(t, caller2, &dec2, .ConnectFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.QuotaExceeded)

	payload := []u8{'q', 'u', 'o', 't', 'a'}
	must_write_stream(t, caller1, .Data, payload, stream_id)
	echoed := must_read_opcode(t, caller1, &dec1, .Data)
	testing.expect_value(t, string(echoed.payload), "quota")
	proto.frame_destroy(&echoed)
}

@(test)
test_limits_stream_buffer_overflow_resets_one_stream :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.max_stream_buffer = 16

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	caller1 := dial_server(t, &server)
	defer trans.connection_destroy(caller1)
	dec1: proto.FrameDecoder
	handshake_caller(t, caller1, &dec1)
	defer proto.decoder_destroy(&dec1)
	send_connect(t, caller1, TEST_SERVICE)
	ok1 := must_read_opcode(t, caller1, &dec1, .ConnectOk)
	sid1 := ok1.header.stream_id
	proto.frame_destroy(&ok1)

	caller2 := dial_server(t, &server)
	defer trans.connection_destroy(caller2)
	dec2: proto.FrameDecoder
	handshake_caller(t, caller2, &dec2)
	defer proto.decoder_destroy(&dec2)
	send_connect(t, caller2, TEST_SERVICE)
	ok2 := must_read_opcode(t, caller2, &dec2, .ConnectOk)
	sid2 := ok2.header.stream_id
	proto.frame_destroy(&ok2)

	big := make([]u8, 64)
	defer delete(big)
	for i in 0 ..< len(big) {
		big[i] = u8(i)
	}
	must_write_stream(t, caller1, .Data, big, sid1)
	reset_frame := must_read_opcode(t, caller1, &dec1, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, sid1)
	proto.frame_destroy(&reset_frame)

	small := []u8{'o', 'k'}
	must_write_stream(t, caller2, .Data, small, sid2)
	echoed := must_read_opcode(t, caller2, &dec2, .Data)
	testing.expect_value(t, echoed.header.stream_id, sid2)
	testing.expect_value(t, string(echoed.payload), "ok")
	proto.frame_destroy(&echoed)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.resets[.StreamBuffer] >= 1)
	testing.expect(t, snap.limit_exceeds[.StreamBuffer] >= 1)
}

@(test)
test_limits_global_buffer_overflow_resets_one_stream :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.max_buffered_bytes = 16

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller1 := dial_server(t, &server)
	defer trans.connection_destroy(caller1)
	dec1: proto.FrameDecoder
	handshake_caller(t, caller1, &dec1)
	defer proto.decoder_destroy(&dec1)
	sid1 := open_test_stream(t, agent, &agent_dec, caller1, &dec1)

	caller2 := dial_server(t, &server)
	defer trans.connection_destroy(caller2)
	dec2: proto.FrameDecoder
	handshake_caller(t, caller2, &dec2)
	defer proto.decoder_destroy(&dec2)
	sid2 := open_test_stream(t, agent, &agent_dec, caller2, &dec2)

	big := make([]u8, 64)
	defer delete(big)
	for i in 0 ..< len(big) {
		big[i] = u8(i)
	}
	must_write_stream(t, caller1, .Data, big, sid1)
	reset_frame := must_read_opcode(t, caller1, &dec1, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, sid1)
	testing.expect_value(t, read_wire_failure(t, reset_frame), proto.WireError.InternalError)
	proto.frame_destroy(&reset_frame)

	small := []u8{'o', 'k'}
	must_write_stream(t, caller2, .Data, small, sid2)
	got: proto.Frame
	for _ in 0 ..< 8 {
		frame := must_read_frame(t, agent, &agent_dec)
		if frame.header.opcode == .Reset && frame.header.stream_id == sid1 {
			proto.frame_destroy(&frame)
			continue
		}
		got = frame
		break
	}
	testing.expect_value(t, got.header.opcode, proto.Opcode.Data)
	testing.expect_value(t, got.header.stream_id, sid2)
	testing.expect_value(t, string(got.payload), "ok")
	proto.frame_destroy(&got)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.limit_exceeds[.GlobalBuffer] >= 1)
}

@(test)
test_limits_connections_per_ip :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.max_connections_per_ip = 1

	first := dial_server(t, &server)
	defer trans.connection_destroy(first)
	dec: proto.FrameDecoder
	handshake_caller(t, first, &dec)
	defer proto.decoder_destroy(&dec)

	second := dial_server(t, &server)
	defer trans.connection_destroy(second)
	_ = trans.connection_set_recv_timeout(second, 500 * time.Millisecond)
	buf: [8]u8
	_, rerr := trans.connection_read(second, buf[:])
	testing.expect_value(t, rerr, trans.TransportError.Closed)
}

@(test)
test_limits_oversize_frame_too_large :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.max_frame_payload = 32

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)

	payload := make([]u8, 64)
	defer delete(payload)
	must_write_opcode(t, caller, .Ping, payload)
	fail := must_read_opcode(t, caller, &decoder, .Error)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.FrameTooLarge)
}

@(test)
test_limits_connect_disconnect_churn_clears_streams :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	for i in 0 ..< 20 {
		caller := dial_server(t, &server)
		decoder: proto.FrameDecoder
		handshake_caller(t, caller, &decoder)
		send_connect(t, caller, TEST_SERVICE)
		ok := must_read_opcode(t, caller, &decoder, .ConnectOk)
		sid := ok.header.stream_id
		proto.frame_destroy(&ok)
		payload := []u8{'c', u8('0' + i % 10)}
		must_write_stream(t, caller, .Data, payload, sid)
		echoed := must_read_opcode(t, caller, &decoder, .Data)
		testing.expect_value(t, echoed.header.stream_id, sid)
		proto.frame_destroy(&echoed)
		must_write_stream(t, caller, .Close, nil, sid)
		proto.decoder_destroy(&decoder)
		trans.connection_destroy(caller)
	}

	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		if relay_stream_count(&server) == 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, relay_stream_count(&server), 0)
}
