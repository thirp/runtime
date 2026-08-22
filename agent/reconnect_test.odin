package agent

import proto "../protocol"
import "core:testing"
import "core:time"

@(test)
test_reconnect_backoff_doubles_until_cap :: proc(t: ^testing.T) {
	testing.expect_value(t, reconnect_backoff(0), 250 * time.Millisecond)
	testing.expect_value(t, reconnect_backoff(1), 500 * time.Millisecond)
	testing.expect_value(t, reconnect_backoff(2), 1 * time.Second)
	testing.expect_value(t, reconnect_backoff(3), 2 * time.Second)
	testing.expect_value(t, reconnect_backoff(4), 4 * time.Second)
	testing.expect_value(t, reconnect_backoff(5), 8 * time.Second)
	testing.expect_value(t, reconnect_backoff(6), 15 * time.Second)
	testing.expect_value(t, reconnect_backoff(7), 15 * time.Second)
	testing.expect_value(t, reconnect_backoff(20), 15 * time.Second)
}

@(test)
test_reconnect_delay_jitter_stays_in_range :: proc(t: ^testing.T) {
	base := reconnect_backoff(2)
	d0 := reconnect_delay(2, 0)
	d1 := reconnect_delay(2, 0xFFFFFFFFFFFFFFFF)
	testing.expect(t, d0 >= base / 2)
	testing.expect(t, d0 <= base)
	testing.expect(t, d1 >= base / 2)
	testing.expect(t, d1 <= base)
	testing.expect(t, d0 <= d1)
	testing.expect(t, reconnect_delay(6, 0) <= RECONNECT_MAX)
	testing.expect(t, reconnect_delay(6, 12345) <= RECONNECT_MAX)
}

@(test)
test_classify_dial_error_maps_transport :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_dial_error(.Tls), ReconnectClass.Tls)
	testing.expect_value(t, classify_dial_error(.Network), ReconnectClass.Network)
	testing.expect_value(t, classify_dial_error(.Closed), ReconnectClass.Network)
	testing.expect_value(t, classify_dial_error(.InvalidEndpoint), ReconnectClass.Configuration)
	testing.expect_value(t, classify_dial_error(.Timeout), ReconnectClass.BrokerUnavailable)
}

@(test)
test_classify_handshake_maps_wire_results :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_handshake(.AuthFailed), ReconnectClass.Authentication)
	testing.expect_value(t, classify_handshake(.Unauthorized), ReconnectClass.Authorization)
	testing.expect_value(t, classify_handshake(.DuplicateRegistration), ReconnectClass.DuplicateRegistration)
	testing.expect_value(t, classify_handshake(.Configuration), ReconnectClass.Configuration)
	testing.expect_value(t, classify_handshake(.Transport), ReconnectClass.BrokerUnavailable)
	testing.expect_value(t, classify_handshake(.RegisterFailed), ReconnectClass.BrokerUnavailable)
	testing.expect_value(t, classify_handshake(.RateLimited), ReconnectClass.RateLimited)
	testing.expect(t, reconnect_class_is_permanent(.Authentication))
	testing.expect(t, reconnect_class_is_permanent(.Authorization))
	testing.expect(t, reconnect_class_is_permanent(.Configuration))
	testing.expect(t, !reconnect_class_is_permanent(.DuplicateRegistration))
	testing.expect(t, !reconnect_class_is_permanent(.Tls))
	testing.expect(t, !reconnect_class_is_permanent(.RateLimited))
	testing.expect_value(t, reconnect_class_reason(.Authentication), "authentication")
	testing.expect_value(t, reconnect_class_reason(.Authorization), "authorization")
	testing.expect_value(t, reconnect_class_reason(.DuplicateRegistration), "duplicate_registration")
	testing.expect_value(t, reconnect_class_reason(.RateLimited), "rate_limited")
}

@(test)
test_handshake_from_register_failed_decodes_wire :: proc(t: ^testing.T) {
	unauth, uerr := proto.encode_wire_failure(
		proto.WireFailure{code = proto.wire_error_to_u16(.Unauthorized), diagnostic = ""},
	)
	testing.expect_value(t, uerr, proto.ProtocolError.None)
	defer delete(unauth)
	testing.expect_value(t, handshake_from_register_failed(unauth), HandshakeResult.Unauthorized)

	dup, derr := proto.encode_wire_failure(
		proto.WireFailure{code = proto.wire_error_to_u16(.ServiceAlreadyRegistered), diagnostic = ""},
	)
	testing.expect_value(t, derr, proto.ProtocolError.None)
	defer delete(dup)
	testing.expect_value(t, handshake_from_register_failed(dup), HandshakeResult.DuplicateRegistration)

	auth, aerr := proto.encode_wire_failure(
		proto.WireFailure{code = proto.wire_error_to_u16(.AuthenticationFailed), diagnostic = ""},
	)
	testing.expect_value(t, aerr, proto.ProtocolError.None)
	defer delete(auth)
	testing.expect_value(t, handshake_from_register_failed(auth), HandshakeResult.AuthFailed)

	limited, lerr := proto.encode_wire_failure(
		proto.WireFailure{code = proto.wire_error_to_u16(.RateLimited), diagnostic = ""},
	)
	testing.expect_value(t, lerr, proto.ProtocolError.None)
	defer delete(limited)
	testing.expect_value(t, handshake_from_register_failed(limited), HandshakeResult.RateLimited)
}

@(test)
test_authenticate_failed_rate_limited_is_transient :: proc(t: ^testing.T) {
	limited, lerr := proto.encode_wire_failure(
		proto.WireFailure{code = proto.wire_error_to_u16(.RateLimited), diagnostic = ""},
	)
	testing.expect_value(t, lerr, proto.ProtocolError.None)
	defer delete(limited)
	fail, derr := proto.decode_wire_failure(limited)
	testing.expect_value(t, derr, proto.ProtocolError.None)
	code, ok := proto.wire_error_from_u16(fail.code)
	delete(fail.diagnostic)
	testing.expect(t, ok)
	testing.expect_value(t, code, proto.WireError.RateLimited)
	testing.expect_value(t, classify_handshake(.RateLimited), ReconnectClass.RateLimited)
	testing.expect(t, !reconnect_class_is_permanent(.RateLimited))
	testing.expect_value(t, classify_handshake(.AuthFailed), ReconnectClass.Authentication)
	testing.expect(t, reconnect_class_is_permanent(.Authentication))
}
