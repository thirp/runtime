#+build !windows
package private_file

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
unix_private_file_permissions_and_read_limits :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-private-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.conf", dir)
	defer {os.remove(path); delete(path)}
	if !testing.expect(t, write_token(path, "secret")) {return}
	testing.expect(t, is_private(path))
	for mode in ([]os.Permissions{MODE+{.Read_Group}, MODE+{.Write_Other}, MODE+{.Execute_User}}) {
		testing.expect(t, os.chmod(path, mode) == nil)
		testing.expect(t, !is_private(path))
		data, ok := read(path, 1024)
		testing.expect(t, !ok && len(data) == 0)
		delete(data)
	}
	testing.expect(t, os.chmod(path, MODE) == nil)
	data, ok := read(path, 6)
	testing.expect(t, !ok && len(data) == 0)
	delete(data)
	data, ok = read(path, 7)
	testing.expect(t, ok)
	testing.expect_value(t, string(data), "secret\n")
	delete(data)
	testing.expect(t, !is_private(dir))
}

@(test)
unix_private_file_rotation_preserves_exact_mode :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-private-rotate-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.token", dir)
	defer {os.remove(path); delete(path)}
	if !testing.expect(t, write_token(path, "old")) {return}
	// Replacement uses the new file's exact mode, not the old file's mode.
	testing.expect(t, os.chmod(path, {.Read_User}) == nil)
	testing.expect(t, write_token(path, "new"))
	fi, serr := os.stat(path, context.allocator)
	testing.expect(t, serr == nil)
	testing.expect_value(t, fi.mode, MODE)
	os.file_info_delete(fi, context.allocator)
	data, ok := read(path, 1024)
	testing.expect(t, ok)
	testing.expect_value(t, string(data), "new\n")
	delete(data)
}
