#+build linux, darwin
package transport

import "core:c"
import "core:strings"
import "core:sys/posix"

// Open the native path first so symlinked parent directories and ".." are
// resolved by the kernel. Nonblocking open lets us reject a FIFO with no writer.
open_regular_input :: proc(path: string, follow_final_symlink := true) -> (RegularInput, bool) {
	if len(path) == 0 || strings.index_byte(path, 0) >= 0 {
		return {}, false
	}
	cpath, err := strings.clone_to_cstring(path, context.allocator)
	if err != .None {
		return {}, false
	}
	defer delete(cpath)
	flags := posix.O_Flags{.NONBLOCK, .NOCTTY, .CLOEXEC}
	if !follow_final_symlink {
		flags += {.NOFOLLOW}
	}
	fd := posix.open(cpath, flags)
	if fd < 0 {
		return {}, false
	}
	info: posix.stat_t
	if posix.fstat(fd, &info) != .OK || !posix.S_ISREG(info.st_mode) {
		posix.close(fd)
		return {}, false
	}
	return {uintptr(fd), i64(info.st_size)}, true
}

close_regular_input :: proc(file: RegularInput) {
	posix.close(posix.FD(file.handle))
}

@(private)
regular_input_read :: proc(file: RegularInput, bytes: []byte) -> (int, bool) {
	for {
		n := posix.read(posix.FD(file.handle), raw_data(bytes), c.size_t(len(bytes)))
		if n >= 0 {
			return int(n), true
		}
		if posix.errno() != .EINTR {
			return 0, false
		}
	}
}
