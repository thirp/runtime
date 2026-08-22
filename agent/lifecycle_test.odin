package agent

import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:thread"
import "core:time"

TEST_SERVICE_B :: "demo/echo-b"

@(test)
test_agent_unregister_a_keeps_b_across_reconnect :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: Agent
	testing.expect_value(
		t,
		agent_init(
			&agent,
			AgentConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_HOST, insecure = true},
		),
		AgentError.None,
	)
	defer agent_destroy(&agent)

	sid_a := must_service(t, TEST_SERVICE)
	sid_b := must_service(t, TEST_SERVICE_B)
	testing.expect_value(t, register_service(&agent, sid_a, LocalTarget{address = echo_ep}), AgentError.None)
	testing.expect_value(t, register_service(&agent, sid_b, LocalTarget{address = echo_ep}), AgentError.None)

	run: AgentRunArg
	run.agent = &agent
	th := thread.create_and_start_with_poly_data(&run, agent_run_proc)
	defer {
		agent_stop(&agent)
		thread.join(th)
		thread.destroy(th)
	}
	wait_agent_connected(t, &agent)
	wait_lookup(t, &fx.reg, sid_a, true)
	wait_lookup(t, &fx.reg, sid_b, true)

	testing.expect_value(t, unregister_service(&agent, sid_a), AgentError.None)
	wait_lookup(t, &fx.reg, sid_a, false)
	_, found_b := brk.lookup_service(&fx.reg, sid_b)
	testing.expect(t, found_b)

	expect_connect_failed(t, &fx, TEST_SERVICE, proto.WireError.ServiceNotFound)
	echo_via_service(t, &fx, TEST_SERVICE_B, []u8{'b', '1'})

	sync_close_live(&agent)
	dropped := time.now()
	for time.since(dropped) < 2 * time.Second {
		if !agent_is_connected(&agent) {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	wait_agent_connected(t, &agent)
	wait_lookup(t, &fx.reg, sid_b, true)
	_, found_a := brk.lookup_service(&fx.reg, sid_a)
	testing.expect(t, !found_a)
	echo_via_service(t, &fx, TEST_SERVICE_B, []u8{'b', '2'})
}

wait_lookup :: proc(t: ^testing.T, reg: ^brk.Registry, id: proto.ServiceId, want: bool, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		_, found := brk.lookup_service(reg, id)
		if found == want {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	_, found := brk.lookup_service(reg, id)
	testing.expect_value(t, found, want, loc)
}

expect_connect_failed :: proc(
	t: ^testing.T,
	fx: ^TestBroker,
	service: string,
	want: proto.WireError,
	loc := #caller_location,
) {
	caller := dial_broker(t, fx, loc)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder, loc)
	defer proto.decoder_destroy(&decoder)
	id := must_service(t, service, loc)
	payload, err := proto.encode_connect(proto.Connect{service_id = id})
	testing.expect_value(t, err, proto.ProtocolError.None, loc)
	must_write(t, caller, .Connect, payload, proto.CONNECTION_STREAM_ID, loc)
	delete(payload)
	fail := must_read_opcode(t, caller, &decoder, .ConnectFailed, loc)
	got, derr := proto.decode_wire_failure(fail.payload)
	testing.expect_value(t, derr, proto.ProtocolError.None, loc)
	defer delete(got.diagnostic)
	code, ok := proto.wire_error_from_u16(got.code)
	testing.expect(t, ok, loc = loc)
	testing.expect_value(t, code, want, loc)
	proto.frame_destroy(&fail)
}

echo_via_service :: proc(t: ^testing.T, fx: ^TestBroker, service: string, payload: []u8, loc := #caller_location) {
	caller := dial_broker(t, fx, loc)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder, loc)
	defer proto.decoder_destroy(&decoder)
	stream := caller_connect_ok(t, caller, &decoder, service, loc)
	must_write(t, caller, .Data, payload, stream, loc)
	got := must_read_opcode(t, caller, &decoder, .Data, loc)
	testing.expect_value(t, string(got.payload), string(payload), loc)
	proto.frame_destroy(&got)
}
