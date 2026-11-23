package transport

RegularInput :: struct {
	handle: uintptr,
	size:   i64,
}

// Read the file size measured on the opened handle. Reject a short read or
// additional bytes if an in-place edit changes the size during the snapshot.
read_regular_input :: proc(file: RegularInput, bytes: []byte) -> bool {
	for offset := 0; offset < len(bytes); {
		n, ok := regular_input_read(file, bytes[offset:])
		if !ok || n == 0 {
			return false
		}
		offset += n
	}
	trailing: [1]byte
	n, ok := regular_input_read(file, trailing[:])
	return ok && n == 0
}
