#+build linux, darwin
package broker

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
test_tls_reload_marker_resolves_native_parent :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-reload-native-*", context.allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer delete(dir)
	defer os.remove_all(dir)
	nested := fmt.aprintf("%s/actual/nested", dir)
	defer delete(nested)
	native := fmt.aprintf("%s/actual/broker.crt.reload", dir)
	defer delete(native)
	lexical := fmt.aprintf("%s/broker.crt.reload", dir)
	defer delete(lexical)
	link := fmt.aprintf("%s/link", dir)
	defer delete(link)
	through_link := fmt.aprintf("%s/link/../broker.crt.reload", dir)
	defer delete(through_link)
	marker_link := fmt.aprintf("%s/alias.reload", dir)
	defer delete(marker_link)
	if !testing.expect(t, os.make_directory_all(nested) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(native, "11111111111111111111111111111111\n") == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(lexical, "22222222222222222222222222222222\n") == nil) {
		return
	}
	link_c := strings.clone_to_cstring(link)
	defer delete(link_c)
	marker_link_c := strings.clone_to_cstring(marker_link)
	defer delete(marker_link_c)
	if !testing.expect_value(t, posix.symlink("actual/nested", link_c), posix.result.OK) ||
	   !testing.expect_value(t, posix.symlink("actual/broker.crt.reload", marker_link_c), posix.result.OK) {
		return
	}
	want, native_ok := tls_reload_read_request(native)
	got, through_ok := tls_reload_read_request(through_link)
	_, alias_ok := tls_reload_read_request(marker_link)
	testing.expect(t, native_ok && through_ok)
	testing.expect_value(t, got, want)
	testing.expect(t, !alias_ok, "refuse a symlink at the marker itself")
}
