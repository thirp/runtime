package broker

import auth "../auth"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

obs_logs: log.Capture
obs_test_mutex: sync.Mutex

obs_sink :: proc(text: string) {
	log.capture_sink(&obs_logs, text)
}

obs_reset_logs :: proc() {
	sync.mutex_lock(&obs_logs.mutex)
	if obs_logs.text == nil {
		obs_logs.text = make([dynamic]u8)
	} else {
		clear(&obs_logs.text)
	}
	sync.mutex_unlock(&obs_logs.mutex)
}

obs_free_logs :: proc() {
	sync.mutex_lock(&obs_logs.mutex)
	delete(obs_logs.text)
	obs_logs.text = {}
	sync.mutex_unlock(&obs_logs.mutex)
	sync.mutex_unlock(&obs_test_mutex)
}

obs_attach_logger :: proc(server: ^Server, logger: ^log.Logger) {
	sync.mutex_lock(&obs_test_mutex)
	obs_reset_logs()
	log.logger_init(logger, .Debug, obs_sink)
	server.logger = logger
}

obs_wait_contains :: proc(needle: string, timeout := 2 * time.Second) -> string {
	deadline := time.now()
	snapshot: [dynamic]u8
	defer delete(snapshot)
	for time.since(deadline) < timeout {
		sync.mutex_lock(&obs_logs.mutex)
		clear(&snapshot)
		append(&snapshot, ..obs_logs.text[:])
		got := string(snapshot[:])
		found := strings.contains(got, needle)
		sync.mutex_unlock(&obs_logs.mutex)
		if found {
			return strings.clone(got)
		}
		time.sleep(10 * time.Millisecond)
	}
	sync.mutex_lock(&obs_logs.mutex)
	clear(&snapshot)
	append(&snapshot, ..obs_logs.text[:])
	sync.mutex_unlock(&obs_logs.mutex)
	return strings.clone(string(snapshot[:]))
}

@(test)
test_obs_connect_absent_service_is_labeled :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_caller(t, caller, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_connect(t, caller, TEST_SERVICE)
	expect_wire(t, caller, &decoder, .ConnectFailed, .ServiceNotFound)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.connection_failures[.ServiceNotFound], u64(1))
	got := obs_wait_contains(json_event(LOG_EVENT_CONNECT_FAILED))
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"error_code\":\"SERVICE_NOT_FOUND\""))
}

@(test)
test_obs_caller_unauthorized_is_labeled :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	agent, agent_dec := register_site_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	decoder: proto.FrameDecoder
	handshake_as(t, caller, &decoder, .Caller, TOKEN_CALLER_D, PRINCIPAL_CALLER_D)
	defer proto.decoder_destroy(&decoder)

	send_connect(t, caller, SITE_SERVICE)
	expect_wire(t, caller, &decoder, .ConnectFailed, .Unauthorized)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.authorization_failures[.Namespace], u64(1))
	testing.expect_value(t, snap.connection_failures[.Unauthorized], u64(1))
	got := obs_wait_contains(json_event(LOG_EVENT_CONNECT_FAILED))
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"error_code\":\"UNAUTHORIZED\""))
	testing.expect(t, strings.contains(got, json_reason(LABEL_NAMESPACE)))
}

@(test)
test_obs_agent_unauthorized_capability_is_labeled :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST_C, PRINCIPAL_HOST_C)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, SITE_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.authorization_failures[.Capability], u64(1))
	testing.expect_value(t, snap.registration_failures[.Capability], u64(1))
	got := obs_wait_contains(json_event(LOG_EVENT_REGISTER_FAILED))
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"error_code\":\"UNAUTHORIZED\""))
	testing.expect(t, strings.contains(got, json_reason(LABEL_CAPABILITY)))
}

@(test)
test_obs_agent_unauthorized_namespace_is_labeled :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_as(t, conn, &decoder, .Agent, TOKEN_HOST, PRINCIPAL_HOST)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, OTHER_SERVICE)
	expect_wire(t, conn, &decoder, .RegisterFailed, .Unauthorized)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.authorization_failures[.Namespace], u64(1))
	testing.expect_value(t, snap.registration_failures[.Namespace], u64(1))
	got := obs_wait_contains(json_event(LOG_EVENT_REGISTER_FAILED))
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"error_code\":\"UNAUTHORIZED\""))
	testing.expect(t, strings.contains(got, json_reason(LABEL_NAMESPACE)))
}

@(test)
test_obs_role_violation_increments_counter :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_caller(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	send_register(t, conn, TEST_SERVICE)
	expect_wire(t, conn, &decoder, .Error, .ProtocolError)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.role_violations_total, u64(1))
	got := obs_wait_contains(json_event(LOG_EVENT_ROLE_VIOLATION))
	defer delete(got)
	testing.expect(t, strings.contains(got, json_reason(REASON_CALLER_REGISTER)))
}

@(test)
test_obs_local_target_down_is_labeled :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	send_connect(t, caller, TEST_SERVICE)
	open_frame := must_read_opcode(t, agent, &agent_dec, .Open)
	stream_id := open_frame.header.stream_id
	delete(string((proto.decode_open(open_frame.payload) or_else proto.Open{}).service_id))
	proto.frame_destroy(&open_frame)

	fail_payload, perr := proto.encode_wire_failure(
		proto.WireFailure {
			code       = proto.wire_error_to_u16(.LocalServiceUnavailable),
			diagnostic = "dial failed",
		},
	)
	testing.expect_value(t, perr, proto.ProtocolError.None)
	defer delete(fail_payload)
	must_write_stream(t, agent, .OpenFailed, fail_payload, stream_id)

	fail := must_read_opcode(t, caller, &caller_dec, .ConnectFailed)
	code := read_wire_failure(t, fail)
	proto.frame_destroy(&fail)
	testing.expect_value(t, code, proto.WireError.LocalServiceUnavailable)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.connection_failures[.LocalServiceUnavailable], u64(1))
	got := obs_wait_contains(json_event(LOG_EVENT_CONNECT_FAILED))
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"error_code\":\"LOCAL_SERVICE_UNAVAILABLE\""))
}

@(test)
test_obs_resource_limit_still_counted :: proc(t: ^testing.T) {
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
	proto.frame_destroy(&ok)

	caller2 := dial_server(t, &server)
	defer trans.connection_destroy(caller2)
	dec2: proto.FrameDecoder
	handshake_caller(t, caller2, &dec2)
	defer proto.decoder_destroy(&dec2)
	send_connect(t, caller2, TEST_SERVICE)
	expect_wire(t, caller2, &dec2, .ConnectFailed, .QuotaExceeded)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.limit_exceeds[.StreamsPerSession], u64(1))
	testing.expect_value(t, snap.connection_failures[.QuotaExceeded], u64(1))
}

@(test)
test_obs_drain_rejects_register_and_connect :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	agent := dial_server(t, &server)
	defer trans.connection_destroy(agent)
	agent_dec: proto.FrameDecoder
	handshake_agent(t, agent, &agent_dec)
	defer proto.decoder_destroy(&agent_dec)

	sync.atomic_store(&server.draining, true)
	send_register(t, agent, TEST_SERVICE)
	expect_wire(t, agent, &agent_dec, .RegisterFailed, .BrokerDraining)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)
	send_connect(t, caller, TEST_SERVICE)
	expect_wire(t, caller, &caller_dec, .ConnectFailed, .BrokerDraining)

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.registration_failures[.BrokerDraining], u64(1))
	testing.expect_value(t, snap.connection_failures[.BrokerDraining], u64(1))
	got := obs_wait_contains("\"error_code\":\"BROKER_DRAINING\"")
	defer delete(got)
	testing.expect(t, strings.contains(got, json_event(LOG_EVENT_REGISTER_FAILED)))
	testing.expect(t, strings.contains(got, json_event(LOG_EVENT_CONNECT_FAILED)))
}

@(test)
test_obs_session_timeout_increments_counter :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	server.heartbeat_interval = 20 * time.Millisecond
	server.session_timeout = 80 * time.Millisecond
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)
	send_register(t, conn, TEST_SERVICE)
	ok_frame := must_read_opcode(t, conn, &decoder, .RegisterOk)
	delete(string((proto.decode_register_ok(ok_frame.payload) or_else proto.RegisterOk{}).service_id))
	proto.frame_destroy(&ok_frame)

	deadline := time.now()
	for time.since(deadline) < 1 * time.Second {
		snap := metrics_snapshot_counters(&server.metrics)
		if snap.session_timeouts_total >= 1 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect(t, snap.session_timeouts_total >= 1)
	got := obs_wait_contains(json_event(LOG_EVENT_SESSION_CLOSED))
	defer delete(got)
	testing.expect(t, strings.contains(got, json_reason(LABEL_IDLE_TIMEOUT)))
}

@(test)
test_obs_auth_failed_includes_peer_role :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&decoder)
	send_hello(t, conn, .Caller)
	ack := must_read_opcode(t, conn, &decoder, .HelloAck)
	ack_msg, _ := proto.decode_hello_ack(ack.payload)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)
	send_authenticate(t, conn, "wrong-token")
	expect_wire(t, conn, &decoder, .AuthenticateFailed, .AuthenticationFailed)

	got := obs_wait_contains(json_event(LOG_EVENT_AUTH_FAILED))
	defer delete(got)
	testing.expect(t, strings.contains(got, json_reason(LABEL_CALLER)))
	testing.expect(t, !strings.contains(got, "wrong-token"))
}

@(test)
test_obs_session_authenticated_includes_organization_id :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)
	logger: log.Logger
	obs_attach_logger(&server, &logger)
	defer obs_free_logs()

	conn := dial_server(t, &server)
	defer trans.connection_destroy(conn)
	decoder: proto.FrameDecoder
	handshake_agent(t, conn, &decoder)
	defer proto.decoder_destroy(&decoder)

	got := obs_wait_contains(json_event(LOG_EVENT_SESSION_AUTHENTICATED))
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"organization_id\":\"org/dev\""))
	testing.expect(t, strings.contains(got, "\"principal_id\":\"host-a\""))
}
