package private_file

import "core:crypto"
import "core:fmt"
import "core:os"

MODE :: os.Permissions{.Read_User, .Write_User}

read :: proc(path: string, limit: int) -> ([]u8, bool) {
	f, err := os.open(path, {.Read})
	if err != nil {return nil, false}
	defer os.close(f)
	fi, serr := os.fstat(f, context.allocator)
	if serr != nil {return nil, false}
	defer os.file_info_delete(fi, context.allocator)
	if !handle_private(f, fi) || fi.size <= 0 || fi.size > i64(limit) {return nil, false}
	// Read the same descriptor whose permissions were checked.
	data, rerr := os.read_entire_file(f, context.allocator)
	if rerr != nil || len(data) == 0 || len(data) > limit {delete(data); return nil, false}
	return data, true
}

// Create an exclusive private file before writing, then flush and replace in
// the destination's directory.
write_token :: proc(path, token: string) -> bool {
	random: [2]u64
	crypto.rand_bytes(([^]u8)(&random)[:size_of(random)])
	tmp := fmt.aprintf("%s.%016x%016x.tmp", path, random[0], random[1])
	defer delete(tmp)
	f, ok := create_private_tmp(tmp)
	if !ok {return false}
	closed := false
	defer {if !closed {_ = os.close(f)}; _ = os.remove(tmp)}
	contents := fmt.aprintf("%s\n", token)
	defer delete(contents)
	n, werr := os.write_string(f, contents)
	if werr != nil || n != len(contents) || os.sync(f) != nil {return false}
	cerr := os.close(f)
	closed = true
	if cerr != nil {return false}
	return replace(tmp, path)
}
