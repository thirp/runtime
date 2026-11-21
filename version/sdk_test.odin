package version

import "core:fmt"
import "core:os"
import "core:testing"

CHECK_SDK_API :: "scripts/check_sdk_api.sh"
REPO_ROOT :: #directory + ".."

@(test)
test_sdk_public_api_and_package_boundary :: proc(t: ^testing.T) {
	bash := "/bin/bash"
	when ODIN_OS == .Windows {
		// Git for Windows provides Bash and the Unix tools the check invokes.
		program_files := os.get_env("ProgramFiles", context.temp_allocator)
		git_bash := fmt.tprintf(`%s\Git\bin\bash.exe`, program_files)
		bash = git_bash if os.exists(git_bash) else "bash.exe"
	}
	state, stdout, stderr, err := os.process_exec(
		{command = []string{bash, CHECK_SDK_API}, working_dir = REPO_ROOT},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	testing.expect_value(t, err, nil)
	if state.exit_code != 0 {
		fmt.eprintf("check_sdk_api stdout: %s\n", string(stdout))
		fmt.eprintf("check_sdk_api stderr: %s\n", string(stderr))
	}
	testing.expect_value(t, state.exit_code, 0)
}

@(test)
test_sdk_docs_and_examples_exist :: proc(t: ^testing.T) {
	testing.expect(t, os.exists(#directory + "../docs/SDK.md"))
	testing.expect(t, os.exists(#directory + "../docs/sdk-public-api.txt"))
	testing.expect(t, os.exists(#directory + "../examples/sdk/odin/ephemeral_host/main.odin"))
	testing.expect(t, os.exists(#directory + "../examples/sdk/odin/join_code_client/main.odin"))
	testing.expect(t, os.exists(#directory + "../examples/sdk/c/echo_client/echo_client.c"))
	testing.expect(t, os.exists(#directory + "../scripts/release_sdk.sh"))
	testing.expect(t, os.exists(#directory + "../scripts/verify_sdk.sh"))
	testing.expect(t, os.exists(#directory + "../scripts/release_broker.sh"))
	testing.expect(t, os.exists(#directory + "../scripts/verify_broker.sh"))
}
