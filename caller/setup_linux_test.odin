#+build linux
package caller

import "core:testing"
import "core:time"

@(test)
test_broker_setup_syn_drop :: proc(t: ^testing.T) {
	sink := syn_sink_start(t)
	if sink.sock == 0 {return}
	defer syn_sink_stop(&sink)
	c: Caller
	start := time.now()
	err := caller_init(&c, {broker = sink.ep, token = TEST_TOKEN_CALLER, insecure = true, dial_timeout = 500*time.Millisecond})
	elapsed := time.since(start)
	if err == .None {caller_destroy(&c)}
	testing.expect_value(t, err, CallerError.Timeout)
	testing.expect(t, elapsed >= 450*time.Millisecond && elapsed < time.Second, "SYN retries must respect 500ms deadline")
}
