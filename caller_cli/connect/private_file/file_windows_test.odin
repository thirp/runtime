#+build windows
package private_file

import "core:fmt"
import "core:os"
import "core:testing"
import win "core:sys/windows"

EVERYONE_SID :: win.SID{Revision = 1, SubAuthorityCount = 1,
	IdentifierAuthority = {Value = {0, 0, 0, 0, 0, 1}}, SubAuthority = {0 = 0}}
USERS_SID :: win.SID{Revision = 1, SubAuthorityCount = 2,
	IdentifierAuthority = {Value = {0, 0, 0, 0, 0, 5}}, SubAuthority = {0 = 32, 1 = 545}}

foreign import test_advapi32 "system:Advapi32.lib"

@(default_calling_convention="system")
foreign test_advapi32 {
	AddAccessAllowedAceEx :: proc(pAcl: rawptr, dwAceRevision, AceFlags, AccessMask: win.DWORD, pSid: rawptr) -> win.BOOL ---
	AddAccessDeniedAce :: proc(pAcl: rawptr, dwAceRevision, AccessMask: win.DWORD, pSid: rawptr) -> win.BOOL ---
	AddAccessAllowedObjectAce :: proc(pAcl: rawptr, dwAceRevision, AceFlags, AccessMask: win.DWORD, ObjectTypeGuid, InheritedObjectTypeGuid, pSid: rawptr) -> win.BOOL ---
}

// Always retain the current user and SYSTEM; optionally add a third principal.
windows_test_acl :: proc(path: string, other: rawptr = nil, mask: win.DWORD = win.FILE_READ_DATA,
	protected := true, inherited := false, deny := false) -> bool {
	sid_buf: [32]u64
	user := current_user_sid(([^]u8)(rawptr(&sid_buf))[:size_of(sid_buf)])
	if user == nil {return false}
	system := SYSTEM_SID
	acl_buf: [128]u64
	if InitializeAcl(&acl_buf, size_of(acl_buf), ACL_REVISION) == win.FALSE {return false}
	if deny && other != nil {
		if AddAccessDeniedAce(&acl_buf, ACL_REVISION, mask, other) == win.FALSE {return false}
	}
	if AddAccessAllowedAce(&acl_buf, ACL_REVISION, win.FILE_ALL_ACCESS, user) == win.FALSE {return false}
	if EqualSid(user, &system) != win.TRUE &&
		AddAccessAllowedAce(&acl_buf, ACL_REVISION, win.FILE_ALL_ACCESS, &system) == win.FALSE {return false}
	if other != nil && !deny {
		flags := win.DWORD(INHERITED_ACE) if inherited else win.DWORD(0)
		if AddAccessAllowedAceEx(&acl_buf, ACL_REVISION, flags, mask, other) == win.FALSE {return false}
	}
	info := win.DWORD(win.DACL_SECURITY_INFORMATION)
	info |= win.PROTECTED_DACL_SECURITY_INFORMATION if protected else win.UNPROTECTED_DACL_SECURITY_INFORMATION
	return SetNamedSecurityInfoW(wide_path(path), SE_FILE_OBJECT, info, nil, nil, &acl_buf, nil) == 0
}

windows_test_exact_dacl :: proc(t: ^testing.T, path: string) {
	f, err := os.open(path, {.Read})
	testing.expect(t, err == nil)
	if err != nil {return}
	defer os.close(f)
	windows_test_exact_handle_dacl(t, f)
}

windows_test_exact_handle_dacl :: proc(t: ^testing.T, f: ^os.File) {
	dacl, sd: rawptr
	rc := GetSecurityInfo(win.HANDLE(os.fd(f)), SE_FILE_OBJECT, win.DACL_SECURITY_INFORMATION, nil, nil, &dacl, nil, &sd)
	defer if sd != nil {win.LocalFree(sd)}
	testing.expect(t, rc == 0 && dacl != nil && sd != nil)
	if rc != 0 || dacl == nil || sd == nil {return}
	control: win.WORD
	revision: win.DWORD
	testing.expect(t, GetSecurityDescriptorControl(sd, &control, &revision) != win.FALSE)
	testing.expect(t, control & SE_DACL_PROTECTED != 0)
	sid_buf: [32]u64
	user := current_user_sid(([^]u8)(rawptr(&sid_buf))[:size_of(sid_buf)])
	testing.expect(t, user != nil)
	if user == nil {return}
	system := SYSTEM_SID
	count := 1 if EqualSid(user, &system) == win.TRUE else 2
	testing.expect_value(t, (^win.ACL)(dacl).AceCount, u16(count))
	for i in 0..<count {
		ace: rawptr
		ok := GetAce(dacl, win.DWORD(i), &ace) != win.FALSE && ace != nil
		testing.expect(t, ok)
		if !ok {return}
		h := (^Ace_Header)(ace)
		testing.expect_value(t, h.ace_type, ACCESS_ALLOWED_ACE_TYPE)
		testing.expect_value(t, h.ace_flags, u8(0))
		testing.expect_value(t, (^win.DWORD)(rawptr(uintptr(ace) + 4))^, win.DWORD(win.FILE_ALL_ACCESS))
		expected := user if i == 0 else rawptr(&system)
		testing.expect(t, EqualSid(rawptr(uintptr(ace) + SID_START_OFFSET), expected) == win.TRUE)
	}
}

@(test)
test_private_tmp_created_with_protected_dacl_and_no_sharing :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-private-tmp-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.token.tmp", dir)
	defer {os.remove(path); delete(path)}
	f, ok := create_private_tmp(path)
	if !testing.expect(t, ok) {return}
	defer os.close(f)
	// Inspect the creation handle immediately, without a subsequent protect call.
	windows_test_exact_handle_dacl(t, f)
	fi, ferr := os.fstat(f, context.allocator)
	defer os.file_info_delete(fi, context.allocator)
	testing.expect(t, ferr == nil)
	testing.expect_value(t, fi.size, i64(0))
	h := win.CreateFileW(wide_path(path), win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	open_error := win.GetLastError()
	if h != win.INVALID_HANDLE {win.CloseHandle(h)}
	testing.expect(t, h == win.INVALID_HANDLE)
	testing.expect_value(t, open_error, win.ERROR_SHARING_VIOLATION)
}

windows_test_everyone_mask :: proc(t: ^testing.T, mask: win.DWORD, private := false) {
	dir, err := os.make_directory_temp("", "thirp-private-mask-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.conf", dir)
	defer {os.remove(path); delete(path)}
	if !testing.expect(t, write_token(path, "secret")) {return}
	everyone := EVERYONE_SID
	if !testing.expect(t, windows_test_acl(path, &everyone, mask)) {return}
	if private {
		testing.expect(t, is_private(path))
		data, ok := read(path, 1024)
		defer delete(data)
		testing.expect(t, ok)
		testing.expect_value(t, string(data), "secret\n")
	} else {
		windows_test_refused(t, path)
	}
}

@(test)
test_dacl_refuses_everyone_write_data :: proc(t: ^testing.T) {
	windows_test_everyone_mask(t, win.FILE_WRITE_DATA)
}

@(test)
test_dacl_refuses_everyone_write_dac :: proc(t: ^testing.T) {
	windows_test_everyone_mask(t, win.WRITE_DAC)
}

@(test)
test_dacl_refuses_everyone_other_mutation_rights :: proc(t: ^testing.T) {
	for mask in ([]win.DWORD{win.WRITE_OWNER, win.FILE_APPEND_DATA, win.DELETE,
		win.GENERIC_WRITE, win.GENERIC_ALL, win.FILE_WRITE_EA, win.FILE_WRITE_ATTRIBUTES}) {
		windows_test_everyone_mask(t, mask)
	}
}

@(test)
test_dacl_accepts_everyone_metadata_only :: proc(t: ^testing.T) {
	windows_test_everyone_mask(t, win.READ_CONTROL | win.SYNCHRONIZE | win.FILE_READ_ATTRIBUTES, true)
}

@(test)
test_dacl_private_masks_in_memory :: proc(t: ^testing.T) {
	// A fixed non-SYSTEM user keeps this table meaningful under LocalSystem too.
	user, system, everyone := USERS_SID, SYSTEM_SID, EVERYONE_SID
	cases := []struct {mask: win.DWORD, private: bool}{
		{0, true},
		{METADATA_ONLY, true},
		{ACCESS_SYSTEM_SECURITY, true},
		{METADATA_ONLY | ACCESS_SYSTEM_SECURITY, true},
		{win.FILE_READ_DATA, false},
		{win.FILE_WRITE_DATA, false},
		{win.FILE_APPEND_DATA, false},
		{win.FILE_WRITE_EA, false},
		{win.FILE_WRITE_ATTRIBUTES, false},
		{win.WRITE_DAC, false},
		{win.WRITE_OWNER, false},
		{win.DELETE, false},
		{win.GENERIC_READ, false},
		{win.GENERIC_WRITE, false},
		{win.GENERIC_ALL, false},
		{0x02000000, false}, // MAXIMUM_ALLOWED
		{win.FILE_EXECUTE, false},
		{METADATA_ONLY | win.WRITE_DAC, false},
		{ACCESS_SYSTEM_SECURITY | win.FILE_WRITE_DATA, false},
	}
	for ace_type in ([]u8{ACCESS_ALLOWED_ACE_TYPE, ACCESS_ALLOWED_CALLBACK_ACE_TYPE,
		ACCESS_ALLOWED_OBJECT_ACE_TYPE, ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE}) {
		for tc in cases {
			acl_buf: [128]u64
			REVISION_DS :: win.DWORD(4)
			if !testing.expect(t, InitializeAcl(&acl_buf, size_of(acl_buf), REVISION_DS) != win.FALSE) {return}
			if !testing.expect(t, AddAccessAllowedAce(&acl_buf, REVISION_DS, win.FILE_ALL_ACCESS, &user) != win.FALSE) {return}
			added: win.BOOL
			if ace_type == ACCESS_ALLOWED_OBJECT_ACE_TYPE || ace_type == ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE {
				guid: [16]u8
				added = AddAccessAllowedObjectAce(&acl_buf, REVISION_DS, 0, tc.mask, &guid, nil, &everyone)
			} else {
				added = AddAccessAllowedAce(&acl_buf, REVISION_DS, tc.mask, &everyone)
			}
			if !testing.expect(t, added != win.FALSE) {return}
			ace: rawptr
			if !testing.expect(t, GetAce(&acl_buf, 1, &ace) != win.FALSE && ace != nil) {return}
			// Callback ACEs share these SID layouts and may carry trailing condition data.
			(^Ace_Header)(ace).ace_type = ace_type
			testing.expect_value(t, dacl_private(&acl_buf, &user, &system), tc.private)
		}
	}
}

@(test)
test_dacl_private_bounds_metadata_only_sid :: proc(t: ^testing.T) {
	user, system, everyone := USERS_SID, SYSTEM_SID, EVERYONE_SID
	for mask in ([]win.DWORD{0, METADATA_ONLY}) {
		acl_buf: [64]u64
		if !testing.expect(t, InitializeAcl(&acl_buf, size_of(acl_buf), ACL_REVISION) != win.FALSE) {return}
		if !testing.expect(t, AddAccessAllowedAce(&acl_buf, ACL_REVISION, mask, &everyone) != win.FALSE) {return}
		ace: rawptr
		if !testing.expect(t, GetAce(&acl_buf, 0, &ace) != win.FALSE && ace != nil) {return}
		// The claimed SID extends beyond the ACE even though the mask is harmless.
		([^]u8)(ace)[SID_START_OFFSET + 1] = 15
		testing.expect(t, !dacl_private(&acl_buf, &user, &system))
		([^]u8)(ace)[SID_START_OFFSET + 1] = 1
		([^]u8)(ace)[SID_START_OFFSET] = 0 // invalid SID revision, still in bounds
		testing.expect(t, !dacl_private(&acl_buf, &user, &system))
	}
}

@(test)
test_protect_exact_dacl_for_current_user :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-private-protect-*", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.conf", dir)
	defer {os.remove(path); delete(path)}
	if !testing.expect(t, os.write_entire_file(path, "fixture") == nil) {return}
	f, oerr := os.open(path, {.Read})
	if !testing.expect(t, oerr == nil) {return}
	defer os.close(f)
	if !testing.expect(t, protect(f, path)) {return}
	windows_test_exact_handle_dacl(t, f)
}

@(test)
test_dacl_private_single_system_ace :: proc(t: ^testing.T) {
	system, user := SYSTEM_SID, USERS_SID
	acl_buf: [64]u64
	if !testing.expect(t, initialize_private_dacl(([^]u8)(rawptr(&acl_buf))[:size_of(acl_buf)], &system)) {return}
	testing.expect_value(t, (^win.ACL)(rawptr(&acl_buf)).AceCount, u16(1))
	testing.expect(t, dacl_private(&acl_buf, &system, &system))
	// Privacy checks exclude other principals; they do not promise user access.
	testing.expect(t, dacl_private(&acl_buf, &user, &system))
	ace: rawptr
	if !testing.expect(t, GetAce(&acl_buf, 0, &ace) != win.FALSE && ace != nil) {return}
	testing.expect_value(t, (^Ace_Header)(ace).ace_type, ACCESS_ALLOWED_ACE_TYPE)
	testing.expect_value(t, (^Ace_Header)(ace).ace_flags, u8(0))
	testing.expect_value(t, (^win.DWORD)(rawptr(uintptr(ace) + 4))^, win.DWORD(win.FILE_ALL_ACCESS))
	testing.expect(t, EqualSid(rawptr(uintptr(ace) + SID_START_OFFSET), &system) == win.TRUE)
}

windows_test_refused :: proc(t: ^testing.T, path: string) {
	testing.expect(t, !is_private(path))
	data, ok := read(path, 1024)
	defer delete(data)
	testing.expect(t, !ok && len(data) == 0)
}

@(test)
windows_private_file_write_and_rotation :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-private-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.token", dir)
	defer {os.remove(path); delete(path)}
	for token in ([]string{"old-token", "rotated-token"}) {
		ok := write_token(path, token)
		testing.expect(t, ok)
		if !ok {return}
		testing.expect(t, is_private(path))
		windows_test_exact_dacl(t, path)
		data, accepted := read(path, 1024)
		testing.expect(t, accepted)
		testing.expect_value(t, string(data), fmt.tprintf("%s\n", token))
		delete(data)
	}
	// A sharing violation must leave the old token and its ACL in place.
	f, oerr := os.open(path, {.Read}) // core:os does not share FILE_SHARE_DELETE
	testing.expect(t, oerr == nil)
	if oerr != nil {return}
	testing.expect(t, !write_token(path, "must-not-replace"))
	os.close(f)
	windows_test_exact_dacl(t, path)
	data, accepted := read(path, 1024)
	testing.expect(t, accepted)
	testing.expect_value(t, string(data), "rotated-token\n")
	delete(data)
	// Exercise rollback when the final path fails its ACL check.
	unsafe := fmt.aprintf("%s/unsafe.tmp", dir)
	defer {os.remove(unsafe); delete(unsafe)}
	if !testing.expect(t, write_token(unsafe, "unsafe-token")) {return}
	everyone := EVERYONE_SID
	testing.expect(t, windows_test_acl(unsafe, &everyone))
	testing.expect(t, !replace(unsafe, path))
	windows_test_exact_dacl(t, path)
	data, accepted = read(path, 1024)
	testing.expect(t, accepted)
	testing.expect_value(t, string(data), "rotated-token\n")
	delete(data)
	df, doerr := os.open(dir, {.Read})
	testing.expect(t, doerr == nil)
	if doerr != nil {return}
	defer os.close(df)
	entries, derr := os.read_dir(df, -1, context.allocator)
	testing.expect(t, derr == nil)
	testing.expect_value(t, len(entries), 1) // no temporary or backup left over
	os.file_info_slice_delete(entries, context.allocator)
}

@(test)
windows_private_file_refuses_other_readers :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-private-readers-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.conf", dir)
	defer {os.remove(path); delete(path)}
	if !testing.expect(t, write_token(path, "secret")) {return}
	everyone, users := EVERYONE_SID, USERS_SID
	for sid in ([]rawptr{&everyone, &users}) {
		for mask in ([]win.DWORD{win.FILE_READ_DATA, win.GENERIC_READ, win.GENERIC_ALL,
			win.FILE_ALL_ACCESS, win.READ_CONTROL | win.FILE_READ_DATA}) {
			testing.expect(t, windows_test_acl(path, sid, mask))
			windows_test_refused(t, path)
		}
	}
	// Security metadata alone does not grant access to the file's data.
	testing.expect(t, windows_test_acl(path, &everyone, win.READ_CONTROL))
	testing.expect(t, is_private(path))
	// Deny ACEs are permitted (this one does not deny our data read).
	testing.expect(t, windows_test_acl(path, &everyone, win.FILE_WRITE_DATA, deny = true))
	testing.expect(t, is_private(path))
}

@(test)
windows_private_file_refuses_inheritance_and_null_dacl :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-private-inherit-*", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer {os.remove(dir); delete(dir)}
	path := fmt.aprintf("%s/caller.token", dir)
	defer {os.remove(path); delete(path)}
	if !testing.expect(t, write_token(path, "secret")) {return}
	testing.expect(t, windows_test_acl(path, protected = false))
	windows_test_refused(t, path)
	// An inherited ACE in a protected DACL is refused. Checked on the in-memory
	// ACL: Windows clears INHERITED_ACE when it stores a protected DACL
	// (observed on Windows 11 build 26300, VM 321), so on disk the file below
	// really is user + SYSTEM only and stays private.
	system := SYSTEM_SID
	sid_buf: [32]u64
	user := current_user_sid(([^]u8)(rawptr(&sid_buf))[:size_of(sid_buf)])
	testing.expect(t, user != nil)
	acl_buf: [128]u64
	testing.expect(t, InitializeAcl(&acl_buf, size_of(acl_buf), ACL_REVISION) != win.FALSE)
	testing.expect(t, AddAccessAllowedAce(&acl_buf, ACL_REVISION, win.FILE_ALL_ACCESS, user) != win.FALSE)
	testing.expect(t, dacl_private(&acl_buf, user, &system))
	testing.expect(t, AddAccessAllowedAceEx(&acl_buf, ACL_REVISION, win.DWORD(INHERITED_ACE), win.FILE_ALL_ACCESS, &system) != win.FALSE)
	testing.expect(t, !dacl_private(&acl_buf, user, &system))
	testing.expect(t, windows_test_acl(path, &system, inherited = true))
	testing.expect(t, is_private(path))
	info := win.DWORD(win.DACL_SECURITY_INFORMATION) | win.DWORD(win.PROTECTED_DACL_SECURITY_INFORMATION)
	testing.expect(t, SetNamedSecurityInfoW(wide_path(path), SE_FILE_OBJECT, info, nil, nil, nil, nil) == 0)
	windows_test_refused(t, path)
	// A directory is never a private regular file, even with the right ACL.
	testing.expect(t, windows_test_acl(dir))
	windows_test_refused(t, dir)
}
