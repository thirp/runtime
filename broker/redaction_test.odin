package broker

import auth "../auth"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

REDACT_SECRET :: "redact-me-unique-token-9f3a"
REDACT_PRINCIPAL :: "redact-host"

redaction_logs: log.Capture

redaction_sink :: proc(text: string) {
	log.capture_sink(&redaction_logs, text)
}

@(test)
test_conn_auth_logs_do_not_emit_token :: proc(t: ^testing.T) {
	redaction_logs.text = make([dynamic]u8)
	defer delete(redaction_logs.text)

	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	start_empty_production_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	logger: log.Logger
	log.logger_init(&logger, .Debug, redaction_sink)
	server.logger = &logger

	fail_conn := dial_server(t, &server)
	defer trans.connection_destroy(fail_conn)
	fail_dec: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&fail_dec), proto.ProtocolError.None)
	defer proto.decoder_destroy(&fail_dec)
	send_hello(t, fail_conn, .Agent)
	ack := must_read_opcode(t, fail_conn, &fail_dec, .HelloAck)
	ack_msg, aerr := proto.decode_hello_ack(ack.payload)
	testing.expect_value(t, aerr, proto.ProtocolError.None)
	delete(ack_msg.implementation)
	proto.frame_destroy(&ack)
	send_authenticate(t, fail_conn, REDACT_SECRET)
	expect_wire(t, fail_conn, &fail_dec, .AuthenticateFailed, .AuthenticationFailed)

	testing.expect_value(
		t,
		auth.auth_add_credential(
			&store,
			auth.CredentialSpec {
				token        = REDACT_SECRET,
				principal_id = REDACT_PRINCIPAL,
				label        = "redact-label",
			},
		),
		auth.AuthError.None,
	)

	ok_conn := dial_server(t, &server)
	defer trans.connection_destroy(ok_conn)
	ok_dec: proto.FrameDecoder
	handshake_as(t, ok_conn, &ok_dec, .Agent, REDACT_SECRET, REDACT_PRINCIPAL)
	defer proto.decoder_destroy(&ok_dec)

	deadline := time.now()
	snapshot: [dynamic]u8
	defer delete(snapshot)
	for time.since(deadline) < 2 * time.Second {
		sync.mutex_lock(&redaction_logs.mutex)
		clear(&snapshot)
		append(&snapshot, ..redaction_logs.text[:])
		got := string(snapshot[:])
		ready := strings.contains(got, json_event(LOG_EVENT_AUTH_FAILED)) &&
			strings.contains(got, json_event(LOG_EVENT_SESSION_AUTHENTICATED))
		sync.mutex_unlock(&redaction_logs.mutex)
		if ready {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	got := string(snapshot[:])
	testing.expect(t, strings.contains(got, json_event(LOG_EVENT_AUTH_FAILED)))
	testing.expect(t, strings.contains(got, json_event(LOG_EVENT_SESSION_AUTHENTICATED)))
	testing.expect(t, !strings.contains(got, REDACT_SECRET))
	testing.expect(t, !strings.contains(got, "\"token\":\"" + REDACT_SECRET + "\""))
}
