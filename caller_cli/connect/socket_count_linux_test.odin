#+build linux
package connect

import "core:net"
import "core:strconv"
import "core:sys/linux"

// Count this process's TCP descriptors on either side of the fixture's IPv4
// loopback endpoint. This includes the listener and sockets in CLOSE_WAIT.
// TIME_WAIT without an open descriptor does not count.
tcp_port_socket_count :: proc(port: int) -> int {
	dir, err := linux.open("/proc/self/fd", {.DIRECTORY, .CLOEXEC})
	if err != .NONE {
		return -2
	}
	defer linux.close(dir)
	count := 0
	entries: [4096]u8
	for {
		n, read_err := linux.getdents(dir, entries[:])
		if read_err != .NONE {
			return -2
		}
		if n == 0 {
			return count
		}
		// os.read_directory opens each entry for metadata and can fail the
		// whole scan if another test closed an fd since getdents listed it.
		offset := 0
		for entry in linux.dirent_iterate_buf(entries[:n], &offset) {
			number, ok := strconv.parse_int(linux.dirent_name(entry))
			if ok && fd_has_loopback_tcp_port(linux.Fd(number), port) {
				count += 1
			}
		}
	}
}

fd_has_loopback_tcp_port :: proc(fd: linux.Fd, port: int) -> bool {
	protocol: i32
	if _, err := linux.getsockopt_base(fd, int(linux.SOL_SOCKET), .PROTOCOL, &protocol); err != .NONE || protocol != i32(linux.Protocol.TCP) {
		return false
	}
	addr: linux.Sock_Addr_Any
	if linux.getsockname(fd, &addr) == .NONE && loopback_tcp_port_matches(addr, port) {
		return true
	}
	return linux.getpeername(fd, &addr) == .NONE && loopback_tcp_port_matches(addr, port)
}

loopback_tcp_port_matches :: proc(addr: linux.Sock_Addr_Any, port: int) -> bool {
	return addr.family == .INET && net.IP4_Address(addr.ipv4.sin_addr) == net.IP4_Loopback && int(addr.port) == port
}
