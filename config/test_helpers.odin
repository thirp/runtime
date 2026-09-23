package config

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

config_temp_seq: int

EXAMPLES_DIR :: #directory + "../examples/production/"

write_temp_config :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&config_temp_seq, 1)
	temp_dir := os.get_env("TEMP", context.temp_allocator)
	if len(temp_dir) == 0 {
		temp_dir = os.get_env("TMP", context.temp_allocator)
	}
	if len(temp_dir) == 0 {
		temp_dir = os.get_env("TMPDIR", context.temp_allocator)
	}
	when ODIN_OS == .Windows {
		if len(temp_dir) == 0 {
			temp_dir = "C:\\Windows\\Temp"
		}
	} else {
		if len(temp_dir) == 0 {
			temp_dir = "/tmp"
		}
	}
	path = fmt.aprintf("%s%cthirp-config-%s-%d.conf", temp_dir, os.Path_Separator, label, n)
	err := os.write_entire_file(path, transmute([]u8)contents)
	if err != nil {
		delete(path)
		return "", false
	}
	return path, true
}

remove_temp_config :: proc(path: string) {
	_ = os.remove(path)
	delete(path)
}

expect_issue_contains :: proc(t: ^testing.T, issues: []ValidationIssue, message: string) -> bool {
	for issue in issues {
		if issue.message == message {
			return true
		}
	}
	testing.expectf(t, false, "missing issue: %s", message)
	return false
}

