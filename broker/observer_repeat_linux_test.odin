#+build linux
package broker

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The Linux gate runs this with the same test executable as the suite.
// Each invocation exercises the original TCP fixture and memory checks.
@(test)
test_connection_observer_bytes_on_close_native_repeat :: proc(t: ^testing.T) {
	if !RUN_FLAKY {
		return
	}
	executable, err := os.get_executable_path(context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	// Keep the runner's normal concurrency with three socket-free tests.
	selection :: "-tests:broker.test_connection_observer_bytes_on_close," +
		"broker.test_outbox_enqueue_data_up_to_stream_cap," +
		"broker.test_outbox_connection_cap_fails_before_stream_cap," +
		"broker.test_outbox_control_frames_enqueue_at_data_cap"
	repeats :: 200
	for run in 1 ..= repeats {
		state, stdout, stderr, exec_err := os.process_exec({command = {executable, selection}}, context.allocator)
		defer delete(stdout)
		defer delete(stderr)
		if !testing.expectf(t, exec_err == nil && state.exit_code == 0 &&
		   !strings.contains(string(stdout), "+++ leak") && !strings.contains(string(stderr), "+++ leak"),
			"native observer run %d/%d failed (%v/%v)\n%s\n%s", run, repeats, exec_err, state.exit_code, string(stdout), string(stderr)) {
			return
		}
	}
	fmt.printfln("RESULT native Linux TCP broker.test_connection_observer_bytes_on_close passed %d/%d", repeats, repeats)
}
