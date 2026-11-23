package connect

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_enrollment_caller_conf_a1_base_replay :: proc(t: ^testing.T) {
	// The loop's Linux gate carries these environment variables and a Git
	// bundle with the base history. The ordinary suite also runs from archives.
	job := os.get_env("CODEX_LOOP_JOB_ID", context.temp_allocator)
	gate_dir := os.get_env("CODEX_LOOP_GATE_DIR", context.temp_allocator)
	if job != "runtime-caller-fail-loud-r1" || gate_dir == "" {return}

	state, stdout, stderr, err := os.process_exec({
		command = {"/bin/bash", "scripts/replay_caller_conf_tls_base.sh"},
		working_dir = #directory + "../..",
	}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	fmt.print(string(stdout))
	fmt.eprint(string(stderr))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, state.exit_code, 0)
}
