package config

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

config_temp_seq: int

EXAMPLES_DIR :: #directory + "../examples/production/"

write_temp_config :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&config_temp_seq, 1)
	path = fmt.aprintf("/tmp/thirp-config-%s-%d.conf", label, n)
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

