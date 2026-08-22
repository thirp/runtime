package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

read_skipping_control :: proc(
	t: ^testing.T,
	conn: ^trans.Connection,
	decoder: ^proto.FrameDecoder,
	want: proto.Opcode,
	loc := #caller_location,
) -> proto.Frame {
	for {
		frame := must_read_frame(t, conn, decoder, loc)
		#partial switch frame.header.opcode {
		case .Ping, .Pong, .Error:
			proto.frame_destroy(&frame)
			continue
		}
		testing.expect_value(t, frame.header.opcode, want, loc)
		return frame
	}
}

DrainLater :: struct {
	server: ^Server,
	delay:  time.Duration,
	grace:  time.Duration,
}

drain_later_proc :: proc(arg: ^DrainLater) {
	time.sleep(arg.delay)
	server_drain(arg.server, arg.grace)
}

@(test)
test_drain_rejects_new_connect :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	sync.atomic_store(&server.draining, true)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)
	send_connect(t, caller, TEST_SERVICE)
	fail := must_read_opcode(t, caller, &decoder, .ConnectFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.BrokerDraining)
}

@(test)
test_drain_grace_zero_resets_live_stream :: proc(t: ^testing.T) {
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

	payload := []u8{'a'}
	must_write_stream(t, caller, .Data, payload, sid)
	echoed := must_read_opcode(t, caller, &decoder, .Data)
	proto.frame_destroy(&echoed)

	server_drain(&server, 0)

	reset_frame := read_skipping_control(t, caller, &decoder, .Reset)
	testing.expect_value(t, reset_frame.header.stream_id, sid)
	code := read_wire_failure(t, reset_frame)
	proto.frame_destroy(&reset_frame)
	testing.expect_value(t, code, proto.WireError.BrokerDraining)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.resets[.BrokerDraining] >= 1)
}

@(test)
test_drain_allows_data_until_grace :: proc(t: ^testing.T) {
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

	arg := DrainLater {
		server = &server,
		delay  = 20 * time.Millisecond,
		grace  = 250 * time.Millisecond,
	}
	th := thread.create_and_start_with_poly_data(&arg, drain_later_proc)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	started := time.now()
	payload := []u8{'g'}
	must_write_stream(t, caller, .Data, payload, sid)
	echoed := read_skipping_control(t, caller, &decoder, .Data)
	testing.expect_value(t, string(echoed.payload), "g")
	proto.frame_destroy(&echoed)
	testing.expect(t, time.since(started) < 250 * time.Millisecond)

	reset_frame := read_skipping_control(t, caller, &decoder, .Reset)
	code := read_wire_failure(t, reset_frame)
	proto.frame_destroy(&reset_frame)
	testing.expect_value(t, code, proto.WireError.BrokerDraining)
	testing.expect(t, time.since(started) >= 200 * time.Millisecond)
}
