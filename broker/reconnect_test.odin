package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:time"

@(test)
test_reconnect_restores_registration :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	svc := must_service_id(t, TEST_SERVICE)
	_, found := lookup_service(&reg, svc)
	testing.expect(t, found)

	proto.decoder_destroy(&agent_dec)
	trans.connection_destroy(agent)

	deadline := time.now()
	for time.since(deadline) < 2 * time.Second {
		_, found = lookup_service(&reg, svc)
		if !found {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	_, found = lookup_service(&reg, svc)
	testing.expect(t, !found)

	agent2, agent_dec2 := register_test_agent(t, &server)
	defer trans.connection_destroy(agent2)
	defer proto.decoder_destroy(&agent_dec2)
	_, found = lookup_service(&reg, svc)
	testing.expect(t, found)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	sid := open_test_stream(t, agent2, &agent_dec2, caller, &caller_dec)
	payload := []u8{'r', 'e'}
	must_write_stream(t, caller, .Data, payload, sid)
	got := must_read_opcode(t, agent2, &agent_dec2, .Data)
	testing.expect_value(t, string(got.payload), "re")
	proto.frame_destroy(&got)
	must_write_stream(t, agent2, .Data, payload, sid)
	echoed := must_read_opcode(t, caller, &caller_dec, .Data)
	testing.expect_value(t, string(echoed.payload), "re")
	proto.frame_destroy(&echoed)
}
