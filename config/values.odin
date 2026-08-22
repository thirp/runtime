package config

import proto "../protocol"
import trans "../transport"
import "core:fmt"
import "core:strconv"
import "core:strings"

sourced_string :: proc(value: string, line: int, flag: string, allocator := context.allocator) -> (SourcedString, ConfigError) {
	owned, err := strings.clone(value, allocator)
	if err != .None {
		return {}, .OutOfMemory
	}
	return SourcedString{value = owned, line = line, flag = flag, set = true}, .None
}

sourced_int :: proc(value: int, line: int, flag: string) -> SourcedInt {
	return SourcedInt{value = value, line = line, flag = flag, set = true}
}

sourced_bool :: proc(value: bool, line: int, flag: string) -> SourcedBool {
	return SourcedBool{value = value, line = line, flag = flag, set = true}
}

clone_sourced_string :: proc(src: SourcedString, allocator := context.allocator) -> (SourcedString, ConfigError) {
	if !src.set {
		return {}, .None
	}
	return sourced_string(src.value, src.line, src.flag, allocator)
}

clone_sourced_list :: proc(src: []SourcedString, dst: ^[dynamic]SourcedString, allocator := context.allocator) -> ConfigError {
	for item in src {
		cloned, err := clone_sourced_string(item, allocator)
		if err != .None {
			return err
		}
		_, aerr := append(dst, cloned)
		if aerr != .None {
			delete(cloned.value, allocator)
			return .OutOfMemory
		}
	}
	return .None
}

destroy_sourced_string :: proc(src: SourcedString, allocator := context.allocator) {
	if src.set {
		delete(src.value, allocator)
	}
}

destroy_sourced_list :: proc(list: [dynamic]SourcedString, allocator := context.allocator) {
	for item in list {
		destroy_sourced_string(item, allocator)
	}
	delete(list)
}

split_key_value :: proc(spec: string) -> (key, value: string, ok: bool) {
	eq := strings.index_byte(spec, '=')
	if eq <= 0 || eq >= len(spec) - 1 {
		return "", "", false
	}
	return spec[:eq], spec[eq + 1:], true
}

parse_bool_value :: proc(value: string) -> (bool, bool) {
	switch value {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}

parse_nonneg_int :: proc(value: string) -> (int, bool) {
	n, ok := strconv.parse_int(value)
	if !ok || n < 0 {
		return 0, false
	}
	return n, true
}

check_host_port :: proc(value: string, allow_port_zero: bool) -> bool {
	ep, err := trans.parse_endpoint(value)
	if err == .None {
		return allow_port_zero || ep.port != 0
	}
	colon := strings.last_index_byte(value, ':')
	if colon <= 0 || colon >= len(value) - 1 {
		return false
	}
	host := value[:colon]
	port_str := value[colon + 1:]
	if len(host) == 0 || strings.contains(host, " ") {
		return false
	}
	port, ok := parse_nonneg_int(port_str)
	if !ok || port > 65535 {
		return false
	}
	if port == 0 && !allow_port_zero {
		return false
	}
	return true
}

check_identity :: proc(value: string) -> bool {
	return len(value) > 0 && len(value) <= MAX_IDENTITY_LEN
}

check_grant_pattern :: proc(pattern: string) -> bool {
	if len(pattern) == 0 {
		return false
	}
	if strings.has_suffix(pattern, "/*") {
		stem := pattern[:len(pattern) - 2]
		if len(stem) == 0 || strings.contains(stem, "*") {
			return false
		}
		return proto.check_service_id(stem) == .None
	}
	if strings.contains(pattern, "*") {
		return false
	}
	return proto.check_service_id(pattern) == .None
}

check_capability_spec :: proc(spec: string) -> bool {
	principal, value, ok := split_key_value(spec)
	if !ok || !check_identity(principal) {
		return false
	}
	return parse_capability_names(value)
}

parse_capability_names :: proc(value: string) -> bool {
	if len(value) == 0 {
		return false
	}
	start := 0
	seen := false
	for i := 0; i <= len(value); i += 1 {
		if i < len(value) && value[i] != ',' {
			continue
		}
		part := trim_ascii_space(value[start:i])
		start = i + 1
		if len(part) == 0 {
			return false
		}
		switch part {
		case "register", "connect":
			seen = true
		case:
			return false
		}
	}
	return seen
}

check_grant_spec :: proc(spec: string) -> bool {
	key, pattern, ok := split_key_value(spec)
	if !ok || !check_identity(key) {
		return false
	}
	return check_grant_pattern(pattern)
}

append_issue :: proc(issues: ^[dynamic]ValidationIssue, line: int, flag, message: string, allocator := context.allocator) -> ConfigError {
	msg, err := strings.clone(message, allocator)
	if err != .None {
		return .OutOfMemory
	}
	_, aerr := append(issues, ValidationIssue{line = line, flag = flag, message = msg})
	if aerr != .None {
		delete(msg, allocator)
		return .OutOfMemory
	}
	return .None
}

issues_destroy :: proc(issues: [dynamic]ValidationIssue) {
	for issue in issues {
		delete(issue.message, issues.allocator)
	}
	delete(issues)
}

format_issue :: proc(issue: ValidationIssue, allocator := context.allocator) -> string {
	if issue.line > 0 {
		return fmt.aprintf("config: line %d: %s", issue.line, issue.message, allocator = allocator)
	}
	if len(issue.flag) > 0 {
		return fmt.aprintf("flag: %s: %s", issue.flag, issue.message, allocator = allocator)
	}
	return fmt.aprintf("config: %s", issue.message, allocator = allocator)
}

issue_source :: proc(src: SourcedString) -> (line: int, flag: string) {
	return src.line, src.flag
}

issue_source_int :: proc(src: SourcedInt) -> (line: int, flag: string) {
	return src.line, src.flag
}

issue_source_bool :: proc(src: SourcedBool) -> (line: int, flag: string) {
	return src.line, src.flag
}
