package transport

import "core:strings"
import win "core:sys/windows"

open_regular_input :: proc(path: string, follow_final_symlink := true) -> (RegularInput, bool) {
	if len(path) == 0 || strings.index_byte(path, 0) >= 0 {
		return {}, false
	}
	// The conversion includes a terminating NUL beyond the returned slice.
	wide := win.utf8_to_utf16(path, context.allocator)
	if len(wide) == 0 {
		return {}, false
	}
	defer free(raw_data(wide))
	flags: win.DWORD = win.FILE_ATTRIBUTE_NORMAL
	if !follow_final_symlink {
		flags |= win.FILE_FLAG_OPEN_REPARSE_POINT
	}
	handle := win.CreateFileW(
		win.wstring(raw_data(wide)), win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil, win.OPEN_EXISTING, flags, nil,
	)
	if handle == win.INVALID_HANDLE_VALUE {
		return {}, false
	}
	info: win.BY_HANDLE_FILE_INFORMATION
	if win.GetFileType(handle) != win.FILE_TYPE_DISK ||
	   win.GetFileInformationByHandle(handle, &info) == win.FALSE ||
	   info.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY != 0 ||
	   (!follow_final_symlink && info.dwFileAttributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
		win.CloseHandle(handle)
		return {}, false
	}
	return {uintptr(handle), i64(info.nFileSizeHigh) << 32 | i64(info.nFileSizeLow)}, true
}

close_regular_input :: proc(file: RegularInput) {
	win.CloseHandle(win.HANDLE(file.handle))
}

@(private)
regular_input_read :: proc(file: RegularInput, bytes: []byte) -> (int, bool) {
	n: win.DWORD
	if win.ReadFile(win.HANDLE(file.handle), raw_data(bytes), win.DWORD(len(bytes)), &n, nil) == win.FALSE {
		return 0, win.GetLastError() == win.ERROR_HANDLE_EOF
	}
	return int(n), true
}
