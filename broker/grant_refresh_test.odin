package broker

import proto "../protocol"
import trans "../transport"
import "core:testing"
import "core:time"

grant_refresh_after :: proc(t: time.Time, d: time.Duration) -> time.Time {
	return time.Time{_nsec = t._nsec + i64(d)}
}

@(test)
test_grant_refresh_extends_open_stream_deadlines :: proc(t: ^testing.T) {
	// These map-only rows borrow their strings; no relay-owned allocations.
	server := Server{streams = make(map[proto.StreamId]RelayStream)}
	defer delete(server.streams)
	now := time.now()
	original := grant_refresh_after(now, time.Hour)
	renewed := grant_refresh_after(now, 3 * time.Hour)
	lease := grant_refresh_after(now, 2 * time.Hour)
	for id in 1 ..= 2 {
		server.streams[proto.StreamId(id)] = RelayStream{
			access_grant_id = GRANT_A,
			state = id == 1 ? .Open : .Opening,
			valid_until = original,
			authorization_lease_until = original,
		}
	}
	server.streams[3] = RelayStream{access_grant_id = GRANT_B, valid_until = original}
	server.streams[4] = RelayStream{} // Static authorizers have no deadlines.

	server_set_grant_lease(&server, GRANT_A, lease, renewed)
	for id in 1 ..= 2 {
		stream := server.streams[proto.StreamId(id)]
		testing.expect_value(t, stream.valid_until, renewed)
		testing.expect_value(t, stream.authorization_lease_until, lease)
		_, expired := stream_grant_expiry_reason(stream, grant_refresh_after(original, time.Second))
		testing.expect(t, !expired, "renewed stream survives original admission expiry")
		deadline, set := stream_grant_deadline(stream)
		testing.expect(t, set)
		testing.expect_value(t, deadline, lease)
		reason, lease_expired := stream_grant_expiry_reason(stream, lease)
		testing.expect(t, lease_expired)
		testing.expect_value(t, reason, ResetReason.LeaseExpired)
	}
	testing.expect_value(t, server.streams[3].valid_until, original)
	testing.expect_value(t, server.streams[3].authorization_lease_until, time.Time{})
	_, static_deadline := stream_grant_deadline(server.streams[4])
	testing.expect(t, !static_deadline)

	// A later lease-only refresh must preserve the actual admission expiry.
	server_set_grant_lease(&server, GRANT_A, grant_refresh_after(now, 4 * time.Hour))
	stream := server.streams[1]
	testing.expect_value(t, stream.valid_until, renewed)
	deadline, _ := stream_grant_deadline(stream)
	testing.expect_value(t, deadline, renewed)
	_, before_final := stream_grant_expiry_reason(stream, grant_refresh_after(renewed, -time.Nanosecond))
	testing.expect(t, !before_final)
	reason, at_final := stream_grant_expiry_reason(stream, renewed)
	testing.expect(t, at_final)
	testing.expect_value(t, reason, ResetReason.GrantExpired)
}

@(test)
test_grant_refresh_does_not_revive_expired_streams :: proc(t: ^testing.T) {
	server := Server{streams = make(map[proto.StreamId]RelayStream)}
	defer delete(server.streams)
	now := time.now()
	past := grant_refresh_after(now, -time.Hour)
	future := grant_refresh_after(now, time.Hour)
	server.streams[1] = RelayStream{
		access_grant_id = GRANT_A, valid_until = past, authorization_lease_until = future,
	}
	server.streams[2] = RelayStream{
		access_grant_id = GRANT_A, valid_until = future, authorization_lease_until = past,
	}
	server_set_grant_lease(&server, GRANT_A, future, future)
	server_set_grant_lease(&server, GRANT_A, future) // Legacy refresh cannot revive either.
	testing.expect_value(t, server.streams[1].valid_until, past)
	testing.expect_value(t, server.streams[2].authorization_lease_until, past)
	for id in 1 ..= 2 {
		_, expired := stream_grant_expiry_reason(server.streams[proto.StreamId(id)], now)
		testing.expect(t, expired)
	}
	// A refresh never creates a row removed by a prior reset.
	delete_key(&server.streams, 1)
	delete_key(&server.streams, 2)
	server_set_grant_lease(&server, GRANT_A, future, future)
	testing.expect_value(t, len(server.streams), 0)
}

@(test)
test_grant_refresh_refusal_keeps_distinct_expiry_reasons :: proc(t: ^testing.T) {
	server := Server{streams = make(map[proto.StreamId]RelayStream)}
	defer delete(server.streams)
	now := time.now()
	future := grant_refresh_after(now, time.Hour)
	past := grant_refresh_after(now, -time.Hour)
	server.streams[1] = RelayStream{
		access_grant_id = GRANT_A, valid_until = future, authorization_lease_until = future,
	}
	// Existing refusal/expiry callers cap only the lease; they cannot extend admission.
	server_set_grant_lease(&server, GRANT_A, past)
	stream := server.streams[1]
	testing.expect_value(t, stream.valid_until, future)
	reason, expired := stream_grant_expiry_reason(stream, now)
	testing.expect(t, expired)
	testing.expect_value(t, reason, ResetReason.LeaseExpired)

	server.streams[1] = RelayStream{
		access_grant_id = GRANT_A, valid_until = future, authorization_lease_until = future,
	}
	// Authoritative admission shortening must also be honored, not just extensions.
	server_set_grant_lease(&server, GRANT_A, future, past)
	reason, expired = stream_grant_expiry_reason(server.streams[1], now)
	testing.expect(t, expired)
	testing.expect_value(t, reason, ResetReason.GrantExpired)
}

@(test)
test_grant_refresh_expiry_and_revoke_reset_queues :: proc(t: ^testing.T) {
	// Exercise real relay ownership and RESET queues without a listener/writer.
	server: Server
	server_init(&server, nil, {})
	defer server_destroy(&server)
	caller := trans.Connection{refs = 1}
	agent := trans.Connection{refs = 1}
	relay_bind_agent(&server, 1, &agent)
	caller_box := new(ConnOutbox)
	outbox_init(caller_box, &caller, &server)
	defer outbox_release(caller_box)
	server_register_outbox(&server, &caller, caller_box)
	agent_box := new(ConnOutbox)
	outbox_init(agent_box, &agent, &server)
	defer outbox_release(agent_box)
	server_register_outbox(&server, &agent, agent_box)
	h := ConnHandler{server = &server, conn = &caller}

	reasons := []ResetReason{.GrantExpired, .LeaseExpired, .GrantRevoked}
	for reason in reasons {
		now := time.now()
		future := grant_refresh_after(now, time.Hour)
		past := grant_refresh_after(now, -time.Hour)
		sid, held_agent, err := relay_open_stream(&server, ServiceId(TEST_SERVICE), 1, &caller,
			AuthzDecision{access_grant_id = GRANT_A, valid_until = future, authorization_lease_until = future}, nil)
		testing.expect_value(t, err, RelayOpenError.None)
		trans.connection_release(held_agent)
		_, applied := relay_apply(&server, sid, .OpenOk, .Agent)
		testing.expect_value(t, applied, StreamError.None)
		code: proto.WireError = .Timeout
		#partial switch reason {
		case .GrantExpired:
			server_set_grant_lease(&server, GRANT_A, future, past)
			conn_expire_grant_streams(&h)
		case .LeaseExpired:
			server_set_grant_lease(&server, GRANT_A, past)
			conn_expire_grant_streams(&h)
		case .GrantRevoked:
			server_reset_grant(&server, GRANT_A)
			code = .Unauthorized
		}
		boxes := []^ConnOutbox{caller_box, agent_box}
		for box in boxes {
			frame, ok := outbox_take_next(box)
			testing.expect(t, ok)
			testing.expect_value(t, frame.opcode, proto.Opcode.Reset)
			testing.expect_value(t, frame.stream_id, sid)
			testing.expect_value(t, read_wire_failure(t, proto.Frame{payload = frame.payload}), code)
			delete(frame.payload)
		}
		testing.expect_value(t, relay_stream_count(&server), 0)
		testing.expect_value(t, metrics_snapshot_counters(&server.metrics).resets[reason], u64(1))
		server_set_grant_lease(&server, GRANT_A, future, future)
		testing.expect_value(t, relay_stream_count(&server), 0)
	}
	testing.expect_value(t, caller.refs, 1)
	testing.expect_value(t, agent.refs, 1)
}
