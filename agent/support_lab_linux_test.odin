#+build linux
package agent

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(test)
test_agent_close_causes_support_lab :: proc(t: ^testing.T) {
	job := os.get_env("CODEX_LOOP_JOB_ID", context.temp_allocator)
	gate_dir := os.get_env("CODEX_LOOP_GATE_DIR", context.temp_allocator)
	if job != "agent-close-cause-runtime-r1" || gate_dir == "" {
		return
	}

	testing.set_fail_timeout(t, 6 * time.Minute)
	state, stdout, stderr, err := os.process_exec({
		command = {"/usr/bin/timeout", "--kill-after=20s", "315s", "/bin/bash",
			"scripts/lab_agent_close_causes.sh", fmt.tprintf("%s/support-lab", gate_dir)},
		working_dir = #directory + "..",
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	fmt.print(string(stdout))
	fmt.eprint(string(stderr))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, state.exit_code, 0)
}
