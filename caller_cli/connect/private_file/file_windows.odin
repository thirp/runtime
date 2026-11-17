#+build windows
package private_file

import "core:fmt"
import "core:os"
import win "core:sys/windows"

SE_FILE_OBJECT :: win.DWORD(1)
ACL_REVISION :: win.DWORD(2)
ACCESS_ALLOWED_ACE_TYPE :: u8(0)
ACCESS_DENIED_ACE_TYPE :: u8(1)
ACCESS_ALLOWED_OBJECT_ACE_TYPE :: u8(5)
ACCESS_DENIED_OBJECT_ACE_TYPE :: u8(6)
ACCESS_ALLOWED_CALLBACK_ACE_TYPE :: u8(9)
ACCESS_DENIED_CALLBACK_ACE_TYPE :: u8(10)
ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE :: u8(11)
ACCESS_DENIED_CALLBACK_OBJECT_ACE_TYPE :: u8(12)
INHERITED_ACE :: u8(0x10)
SE_DACL_PROTECTED :: win.WORD(0x1000)
SID_START_OFFSET :: 8
METADATA_ONLY :: win.READ_CONTROL | win.SYNCHRONIZE | win.FILE_READ_ATTRIBUTES | win.FILE_READ_EA
ACCESS_SYSTEM_SECURITY :: win.DWORD(0x01000000)

SYSTEM_SID :: win.SID{Revision = 1, SubAuthorityCount = 1,
	IdentifierAuthority = {Value = {0, 0, 0, 0, 0, 5}}, SubAuthority = {0 = 18}}

foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention="system")
foreign advapi32 {
	InitializeAcl :: proc(pAcl: rawptr, nAclLength, dwAclRevision: win.DWORD) -> win.BOOL ---
	AddAccessAllowedAce :: proc(pAcl: rawptr, dwAceRevision, AccessMask: win.DWORD, pSid: rawptr) -> win.BOOL ---
	GetLengthSid :: proc(pSid: rawptr) -> win.DWORD ---
	EqualSid :: proc(pSid1, pSid2: rawptr) -> win.BOOL ---
	IsValidSid :: proc(pSid: rawptr) -> win.BOOL ---
	SetNamedSecurityInfoW :: proc(pObjectName: win.wstring, ObjectType, SecurityInfo: win.DWORD, psidOwner, psidGroup, pDacl, pSacl: rawptr) -> win.DWORD ---
	GetSecurityInfo :: proc(handle: win.HANDLE, ObjectType, SecurityInfo: win.DWORD, ppsidOwner, ppsidGroup: rawptr, ppDacl: ^rawptr, ppSacl: rawptr, ppSecurityDescriptor: ^rawptr) -> win.DWORD ---
	GetSecurityDescriptorControl :: proc(pSecurityDescriptor: rawptr, pControl: ^win.WORD, lpdwRevision: ^win.DWORD) -> win.BOOL ---
	GetAce :: proc(pAcl: rawptr, dwAceIndex: win.DWORD, pAce: ^rawptr) -> win.BOOL ---
	InitializeSecurityDescriptor :: proc(pSecurityDescriptor: rawptr, dwRevision: win.DWORD) -> win.BOOL ---
	SetSecurityDescriptorDacl :: proc(pSecurityDescriptor: rawptr, bDaclPresent: win.BOOL, pDacl: rawptr, bDaclDefaulted: win.BOOL) -> win.BOOL ---
	SetSecurityDescriptorControl :: proc(pSecurityDescriptor: rawptr, ControlBitsOfInterest, ControlBitsToSet: win.WORD) -> win.BOOL ---
}

Ace_Header :: struct {ace_type, ace_flags: u8, ace_size: u16}
Security_Descriptor :: struct {
	revision, sbz1: u8,
	control: win.WORD,
	owner, group, sacl, dacl: rawptr,
}

is_private :: proc(path: string) -> bool {
	f, err := os.open(path, {.Read})
	if err != nil {return false}
	defer os.close(f)
	fi, serr := os.fstat(f, context.allocator)
	if serr != nil {return false}
	defer os.file_info_delete(fi, context.allocator)
	return handle_private(f, fi)
}

handle_private :: proc(f: ^os.File, fi: os.File_Info) -> bool {
	if fi.type != .Regular {return false}
	dacl, sd: rawptr
	rc := GetSecurityInfo(win.HANDLE(os.fd(f)), SE_FILE_OBJECT, win.DACL_SECURITY_INFORMATION, nil, nil, &dacl, nil, &sd)
	defer if sd != nil {win.LocalFree(sd)}
	if rc != 0 || sd == nil || dacl == nil {return false}
	control: win.WORD
	revision: win.DWORD
	if GetSecurityDescriptorControl(sd, &control, &revision) == win.FALSE || control & SE_DACL_PROTECTED == 0 {return false}
	sid_buf: [32]u64
	user := current_user_sid(([^]u8)(rawptr(&sid_buf))[:size_of(sid_buf)])
	if user == nil {return false}
	system := SYSTEM_SID
	return dacl_private(dacl, user, &system)
}

dacl_private :: proc(dacl, user, system: rawptr) -> bool {
	if dacl == nil {return false}
	acl := (^win.ACL)(dacl)
	for i in 0..<int(acl.AceCount) {
		ace: rawptr
		if GetAce(dacl, win.DWORD(i), &ace) == win.FALSE || ace == nil {return false}
		h := (^Ace_Header)(ace)
		if h.ace_size < size_of(Ace_Header) || h.ace_flags & INHERITED_ACE != 0 {return false}
		switch h.ace_type {
		case ACCESS_DENIED_ACE_TYPE, ACCESS_DENIED_OBJECT_ACE_TYPE,
			ACCESS_DENIED_CALLBACK_ACE_TYPE, ACCESS_DENIED_CALLBACK_OBJECT_ACE_TYPE:
			continue
		case ACCESS_ALLOWED_ACE_TYPE, ACCESS_ALLOWED_CALLBACK_ACE_TYPE,
			ACCESS_ALLOWED_OBJECT_ACE_TYPE, ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE:
			if int(h.ace_size) < SID_START_OFFSET {return false}
			mask := (^win.DWORD)(rawptr(uintptr(ace) + size_of(Ace_Header)))^
			offset := SID_START_OFFSET
			if h.ace_type == ACCESS_ALLOWED_OBJECT_ACE_TYPE || h.ace_type == ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE {
				if h.ace_size < 12 {return false}
				flags := (^u32)(rawptr(uintptr(ace) + 8))^
				if flags & ~u32(3) != 0 {return false}
				offset = 12
				if flags & 1 != 0 {offset += 16} // ObjectType GUID
				if flags & 2 != 0 {offset += 16} // InheritedObjectType GUID
			}
			// Bound the variable-length SID before asking Advapi32 to inspect it.
			if int(h.ace_size) < offset + 8 {return false}
			sid := rawptr(uintptr(ace) + uintptr(offset))
			count := ([^]u8)(sid)[1]
			if int(h.ace_size) < offset + 8 + 4*int(count) || IsValidSid(sid) == win.FALSE {return false}
			// Other SIDs may only receive metadata rights; ACCESS_SYSTEM_SECURITY is not a DACL right.
			if EqualSid(sid, user) != win.TRUE && EqualSid(sid, system) != win.TRUE &&
				mask & ~(METADATA_ONLY | ACCESS_SYSTEM_SECURITY) != 0 {return false}
		case:
			// Unknown grant formats cannot establish that the file is private.
			return false
		}
	}
	return true
}

initialize_private_dacl :: proc(buf: []u8, user: rawptr) -> bool {
	if user == nil || len(buf) == 0 {return false}
	system := SYSTEM_SID
	is_system := EqualSid(user, &system) == win.TRUE
	acl_size := size_of(win.ACL) + SID_START_OFFSET + int(GetLengthSid(user))
	if !is_system {acl_size += SID_START_OFFSET + int(GetLengthSid(&system))}
	if acl_size > len(buf) {return false}
	acl := rawptr(&buf[0])
	if InitializeAcl(acl, win.DWORD(acl_size), ACL_REVISION) == win.FALSE {return false}
	if AddAccessAllowedAce(acl, ACL_REVISION, win.FILE_ALL_ACCESS, user) == win.FALSE {return false}
	if !is_system && AddAccessAllowedAce(acl, ACL_REVISION, win.FILE_ALL_ACCESS, &system) == win.FALSE {return false}
	return true
}

create_private_tmp :: proc(path: string) -> (^os.File, bool) {
	// TOKEN_USER and the ACL need pointer/DWORD-aligned storage.
	sid_buf: [32]u64
	user := current_user_sid(([^]u8)(rawptr(&sid_buf))[:size_of(sid_buf)])
	acl_buf: [64]u64
	if !initialize_private_dacl(([^]u8)(rawptr(&acl_buf))[:size_of(acl_buf)], user) {return nil, false}
	sd: Security_Descriptor
	if InitializeSecurityDescriptor(&sd, 1) == win.FALSE ||
		SetSecurityDescriptorDacl(&sd, win.TRUE, &acl_buf, win.FALSE) == win.FALSE ||
		SetSecurityDescriptorControl(&sd, SE_DACL_PROTECTED, SE_DACL_PROTECTED) == win.FALSE {return nil, false}
	wpath := wide_path(path)
	if wpath == nil {return nil, false}
	sa := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), lpSecurityDescriptor = &sd}
	h := win.CreateFileW(wpath, win.GENERIC_WRITE | win.READ_CONTROL | win.FILE_READ_ATTRIBUTES,
		0, &sa, win.CREATE_NEW, win.FILE_ATTRIBUTE_NORMAL, nil)
	if h == win.INVALID_HANDLE {return nil, false}
	// core:os writes, syncs and closes this handle with WriteFile/FlushFileBuffers/CloseHandle.
	f := os.new_file(uintptr(h), path)
	if f == nil {
		win.CloseHandle(h)
		_ = os.remove(path)
		return nil, false
	}
	fi, err := os.fstat(f, context.allocator)
	defer os.file_info_delete(fi, context.allocator)
	if err != nil || !handle_private(f, fi) {
		_ = os.close(f)
		_ = os.remove(path)
		return nil, false
	}
	return f, true
}

protect :: proc(f: ^os.File, path: string) -> bool {
	sid_buf: [32]u64
	user := current_user_sid(([^]u8)(rawptr(&sid_buf))[:size_of(sid_buf)])
	acl_buf: [64]u64
	if !initialize_private_dacl(([^]u8)(rawptr(&acl_buf))[:size_of(acl_buf)], user) {return false}
	wpath := wide_path(path)
	if wpath == nil {return false}
	info := win.DWORD(win.DACL_SECURITY_INFORMATION) | win.DWORD(win.PROTECTED_DACL_SECURITY_INFORMATION)
	if SetNamedSecurityInfoW(wpath, SE_FILE_OBJECT, info, nil, nil, &acl_buf, nil) != 0 {return false}
	fi, err := os.fstat(f, context.allocator)
	if err != nil {return false}
	defer os.file_info_delete(fi, context.allocator)
	return handle_private(f, fi)
}

replace :: proc(tmp, path: string) -> bool {
	// Retain the old file (including its ACL) until the final-path check passes.
	// A hard link does not introduce a gap in the atomic destination replace.
	backup := fmt.aprintf("%s.old", tmp)
	defer delete(backup)
	wtmp, wpath, wbackup := wide_path(tmp), wide_path(path), wide_path(backup)
	if wtmp == nil || wpath == nil || wbackup == nil {return false}
	had_old := win.CreateHardLinkW(wbackup, wpath, nil) != win.FALSE
	if !had_old && win.GetLastError() != win.ERROR_FILE_NOT_FOUND {return false}
	keep_backup := false
	defer if had_old && !keep_backup {_ = os.remove(backup)}
	flags := win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH
	if win.MoveFileExW(wtmp, wpath, flags) == win.FALSE {return false}
	if is_private(path) {return true}
	if had_old {
		// If rollback itself fails, retain the old token at backup for recovery.
		keep_backup = win.MoveFileExW(wbackup, wpath, flags) == win.FALSE
	} else {_ = os.remove(path)}
	return false
}

current_user_sid :: proc(buf: []u8) -> rawptr {
	if len(buf) < 64 {return nil}
	tok: win.HANDLE
	if win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &tok) == win.FALSE {return nil}
	defer win.CloseHandle(tok)
	ret: win.DWORD
	if win.GetTokenInformation(tok, .TokenUser, rawptr(&buf[0]), win.DWORD(len(buf)), &ret) == win.FALSE {return nil}
	return (^win.TOKEN_USER)(rawptr(&buf[0])).User.Sid
}

wide_path :: proc(path: string) -> win.wstring {
	if len(path) == 0 {return nil}
	buf := make([]u8, len(path), context.temp_allocator)
	for c, i in transmute([]u8)path {buf[i] = '\\' if c == '/' else c}
	return win.utf8_to_wstring(string(buf))
}
