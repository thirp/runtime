package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:bytes"
import "core:testing"
import "core:time"

// The second HALF_CLOSE ends the stream. Frames already accepted for it
// (response DATA, the other side's HALF_CLOSE) used to be deleted first, so
// the peer waiting on that EOF never finished. Held writer: the frames are
// still in the caller outbox when the caller's HALF_CLOSE is applied. They
// must still be there, and the caller must then read them.
@(test)
test_second_half_close_keeps_queued_response :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	agent, agent_dec := register_test_agent(t, &server)
	defer trans.connection_destroy(agent)
	defer proto.decoder_destroy(&agent_dec)

	caller := dial_server(t, &server)
	defer trans.connection_destroy(caller)
	caller_dec: proto.FrameDecoder
	handshake_caller(t, caller, &caller_dec)
	defer proto.decoder_destroy(&caller_dec)

	sid := open_test_stream(t, agent, &agent_dec, caller, &caller_dec)
	stream, found := relay_lookup_stream(&server, sid)
	testing.expect(t, found, "stream")
	if !found {
		return
	}
	box := server_lookup_outbox(&server, stream.caller_conn)
	testing.expect(t, box != nil, "caller outbox")
	if box == nil {
		return
	}
	defer outbox_release(box)
	outbox_set_writer_hold(box, true)
	defer outbox_set_writer_hold(box, false)

	payload := make([]u8, 46 * 1024)
	defer delete(payload)
	for i in 0 ..< len(payload) {
		payload[i] = u8(i)
	}
	must_write_stream(t, agent, .Data, payload, sid)
	must_write_stream(t, agent, .HalfClose, nil, sid)

	queued := 0
	start := time.now()
	for time.since(start) < 2 * time.Second {
		queued = outbox_queued(box, sid)
		if queued >= 2 {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expectf(t, queued >= 2, "agent DATA+HALF_CLOSE never queued (have %d)", queued)
	if queued < 2 {
		return
	}

	must_write_stream(t, caller, .HalfClose, nil, sid)

	got_half := false
	wait := time.now()
	for time.since(wait) < 2 * time.Second && !got_half {
		_ = trans.connection_set_recv_timeout(agent, 200 * time.Millisecond)
		frame, terr, perr := trans.read_frame(agent, &agent_dec)
		if terr == .Timeout {
			continue
		}
		testing.expect_value(t, terr, trans.TransportError.None)
		testing.expect_value(t, perr, proto.ProtocolError.None)
		if frame.header.opcode == .HalfClose && frame.header.stream_id == sid {
			got_half = true
		}
		proto.frame_destroy(&frame)
	}
	testing.expect(t, got_half, "caller HALF_CLOSE was not forwarded")

	// Still held: a drop would have emptied this queue inside the handler.
	testing.expect_value(t, outbox_queued(box, sid), 2)
	if outbox_queued(box, sid) != 2 {
		return
	}
	sn := metrics_snapshot(&server).resets[.StreamNotFound]
	testing.expect_value(t, sn, u64(0))

	outbox_set_writer_hold(box, false)
	data := must_read_opcode(t, caller, &caller_dec, .Data)
	testing.expect(t, bytes.equal(data.payload, payload), "queued response was dropped")
	proto.frame_destroy(&data)
	hc := must_read_opcode(t, caller, &caller_dec, .HalfClose)
	testing.expect_value(t, hc.header.stream_id, sid)
	proto.frame_destroy(&hc)
	testing.expect_value(t, metrics_snapshot(&server).resets[.StreamNotFound], u64(0))
}
