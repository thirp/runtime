#+build linux
package caller

import trans "../transport"
import "core:c"
import "core:sys/posix"

// linux/tcp.h: tcpi_bytes_acked is at this offset in struct tcp_info.
TCP_INFO_BYTES_ACKED_OFF :: 120
TCP_INFO_SIZE :: 248
TCP_INFO_OPTION :: posix.Sock_Option(11)

socket_bytes_acked :: proc(conn: ^trans.Connection) -> (n: u64, ok: bool) {
	if conn == nil {
		return 0, false
	}
	buf: [TCP_INFO_SIZE]u8
	length := posix.socklen_t(TCP_INFO_SIZE)
	fd := posix.FD(trans.connection_socket_fd(conn))
	if posix.getsockopt(fd, c.int(posix.IPPROTO_TCP), TCP_INFO_OPTION, &buf[0], &length) != .OK {
		return 0, false
	}
	if int(length) < TCP_INFO_BYTES_ACKED_OFF + 8 {
		return 0, false
	}
	off := TCP_INFO_BYTES_ACKED_OFF
	n = u64(buf[off]) | u64(buf[off + 1]) << 8 | u64(buf[off + 2]) << 16 | u64(buf[off + 3]) << 24 | u64(buf[off + 4]) << 32 | u64(buf[off + 5]) << 40 | u64(buf[off + 6]) << 48 | u64(buf[off + 7]) << 56
	return n, true
}

// linux/tcp.h: tcpi_retransmits is the third u8 in struct tcp_info.
TCP_INFO_RETRANSMITS_OFF :: 2

socket_retransmits :: proc(conn: ^trans.Connection) -> (n: int, ok: bool) {
	if conn == nil {
		return 0, false
	}
	buf: [TCP_INFO_SIZE]u8
	length := posix.socklen_t(TCP_INFO_SIZE)
	fd := posix.FD(trans.connection_socket_fd(conn))
	if posix.getsockopt(fd, c.int(posix.IPPROTO_TCP), TCP_INFO_OPTION, &buf[0], &length) != .OK {
		return 0, false
	}
	if int(length) <= TCP_INFO_RETRANSMITS_OFF {
		return 0, false
	}
	return int(buf[TCP_INFO_RETRANSMITS_OFF]), true
}
