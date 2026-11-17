#+build !windows
package private_file

import "core:os"

create_private_tmp :: proc(path: string) -> (^os.File, bool) {
	f, err := os.open(path, {.Write, .Create, .Excl}, MODE)
	if err != nil {return nil, false}
	if !protect(f, path) {
		_ = os.close(f)
		_ = os.remove(path)
		return nil, false
	}
	return f, true
}

is_private :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.allocator)
	if err != nil {return false}
	defer os.file_info_delete(fi, context.allocator)
	return handle_private(nil, fi)
}

handle_private :: proc(_: ^os.File, fi: os.File_Info) -> bool {
	return fi.type == .Regular && fi.mode & ~MODE == {}
}

protect :: proc(f: ^os.File, _: string) -> bool {
	// Set exact permissions even under a restrictive umask.
	return os.fchmod(f, MODE) == nil
}

replace :: proc(tmp, path: string) -> bool {
	return os.rename(tmp, path) == nil
}
