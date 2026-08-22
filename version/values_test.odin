package version

import "core:os"
import "core:strings"
import "core:testing"

VERSION_PATH :: #directory + "../VERSION.txt"
THIRP_H_PATH :: #directory + "../c_abi/thirp.h"

@(test)
test_project_version_matches_version_file :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(VERSION_PATH, context.allocator)
	testing.expect_value(t, err, nil)
	defer delete(data)
	file_version := strings.trim_space(string(data))
	testing.expect_value(t, PROJECT_VERSION, file_version)
}

@(test)
test_project_version_is_zero_dot_semver :: proc(t: ^testing.T) {
	testing.expect(t, is_zero_dot_semver(PROJECT_VERSION))
}

@(test)
test_version_line_contains_name_version_protocol :: proc(t: ^testing.T) {
	line := version_line("thirp-broker")
	defer delete(line)
	testing.expect(t, strings.contains(line, "thirp-broker"))
	testing.expect(t, strings.contains(line, PROJECT_VERSION))
	testing.expect(t, strings.contains(line, "protocol 1.0"))
	testing.expect(t, strings.contains(line, config_string(PROJECT_COMMIT)))
}

@(test)
test_config_string_strips_surrounding_quotes :: proc(t: ^testing.T) {
	testing.expect_value(t, config_string("unknown"), "unknown")
	testing.expect_value(t, config_string("\"6eb9349d1862e6200336d37735f5ad1a11c8f907\""), "6eb9349d1862e6200336d37735f5ad1a11c8f907")
	testing.expect_value(t, config_string("dfc71c845c9445c7e42b483895bb8dc8aa60771f"), "dfc71c845c9445c7e42b483895bb8dc8aa60771f")
}

@(test)
test_thirp_h_version_string_matches_project_version :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(THIRP_H_PATH, context.allocator)
	testing.expect_value(t, err, nil)
	defer delete(data)
	needle := fmt_version_define(PROJECT_VERSION)
	defer delete(needle)
	testing.expect(t, strings.contains(string(data), needle))
}

is_zero_dot_semver :: proc(value: string) -> bool {
	if len(value) < 5 {
		return false
	}
	if value[0] != '0' || value[1] != '.' {
		return false
	}
	dot := -1
	for i in 2 ..< len(value) {
		b := value[i]
		if b == '.' {
			if dot >= 0 {
				return false
			}
			if i == 2 {
				return false
			}
			dot = i
			continue
		}
		if b < '0' || b > '9' {
			return false
		}
	}
	if dot < 0 || dot == len(value) - 1 {
		return false
	}
	return true
}

fmt_version_define :: proc(ver: string, allocator := context.allocator) -> string {
	return strings.concatenate({`#define THIRP_VERSION_STRING "`, ver, `"`}, allocator)
}
