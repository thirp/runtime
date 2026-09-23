package broker

import log "../logging"
import proto "../protocol"
import "core:strings"
import "core:testing"

@(test)
test_stream_not_found_log_ok_rate_limits_within_window :: proc(t: ^testing.T) {
	// Fake timestamps: first event in a window logs, later ones do not, next
	// window logs again. No sleep.
	last: i64
	window := i64(STREAM_NOT_FOUND_LOG_WINDOW)
	testing.expect(t, stream_not_found_log_ok(&last, 1_000, window))
	testing.expect(t, !stream_not_found_log_ok(&last, 1_001, window))
	testing.expect(t, !stream_not_found_log_ok(&last, 1_000 + window - 1, window))
	testing.expect(t, stream_not_found_log_ok(&last, 1_000 + window, window))
	testing.expect(t, !stream_not_found_log_ok(&last, 1_000 + window + 1, window))
	testing.expect(t, !stream_not_found_log_ok(nil, 1, window))
	testing.expect(t, !stream_not_found_log_ok(&last, 1, 0))
}

@(test)
test_conn_log_stream_not_found_rate_limits_metrics_still_count :: proc(t: ^testing.T) {
	// Same thread as the sink so capture allocs match the test allocator.
	// Eight STREAM_NOT_FOUND resets: metric is 8, Info line is 1.
	server: Server
	cap: log.Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	context.user_ptr = &cap
	logger: log.Logger
	log.logger_init(&logger, .Info, proc(text: string) {
		c := (^log.Capture)(context.user_ptr)
		log.capture_sink(c, text)
	})
	server.logger = &logger
	h: ConnHandler
	h.server = &server

	N :: 8
	for i in 0 ..< N {
		metrics_inc_reset(&server.metrics, .StreamNotFound)
		conn_log_stream_not_found(&h, proto.make_stream_id(u64(100 + i)))
	}

	snap := metrics_snapshot_counters(&server.metrics)
	testing.expect_value(t, snap.resets[.StreamNotFound], u64(N))
	got := string(cap.text[:])
	testing.expect_value(t, strings.count(got, json_event(LOG_EVENT_STREAM_RESET)), 1)
	testing.expect(t, strings.contains(got, json_reason(LABEL_STREAM_NOT_FOUND)))
}
