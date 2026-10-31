#+build !linux
package caller

import trans "../transport"

socket_bytes_acked :: proc(conn: ^trans.Connection) -> (n: u64, ok: bool) {
	return 0, false
}

socket_retransmits :: proc(conn: ^trans.Connection) -> (n: int, ok: bool) {
	return 0, false
}
