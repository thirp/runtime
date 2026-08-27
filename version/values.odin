package version

import "core:fmt"

// Project version. Independent of PROTOCOL_MAJOR / PROTOCOL_MINOR.
// Override at release: odin build ... -define:THIRP_COMMIT="<sha>"
// Quote the SHA so a hex that starts with a digit stays a string; version_line
// strips the surrounding quotes Odin then keeps in the constant.
PROJECT_VERSION :: #config(THIRP_VERSION, "0.16.1")
PROJECT_COMMIT :: #config(THIRP_COMMIT, "unknown")
PROTOCOL_LABEL :: "1.0"

config_string :: proc(raw: string) -> string {
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw) - 1] == '"' {
		return raw[1:len(raw) - 1]
	}
	return raw
}

version_line :: proc(binary_name: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%s %s (commit %s, protocol %s)",
		binary_name,
		PROJECT_VERSION,
		config_string(PROJECT_COMMIT),
		PROTOCOL_LABEL,
		allocator = allocator,
	)
}
