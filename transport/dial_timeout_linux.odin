#+build linux
package transport

import "core:net"
import "core:sys/linux"
import "core:time"

// Blocking connect retries SYNs for about two minutes. A local service that
// drops SYNs must fail inside the caller's dial timeout, or the caller's
// one pending slot stays taken until that dial gives up.
connection_dial_timeout :: proc(
	endpoint: net.Endpoint,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (
	^Connection,
	TransportError,
) {
	if timeout <= 0 {
		return connection_dial(endpoint, allocator)
	}
	if endpoint.port == 0 {
		return nil, .InvalidEndpoint
	}
	family: linux.Address_Family
	switch _ in endpoint.address {
	case net.IP4_Address:
		family = .INET
	case net.IP6_Address:
		family = .INET6
	case:
		return nil, .InvalidEndpoint
	}
	fd, serr := linux.socket(family, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP)
	if serr != .NONE {
		return nil, .Network
	}
	addr := dial_sock_addr(endpoint)
	cerr := linux.connect(fd, &addr)
	if cerr == .EINPROGRESS || cerr == .EAGAIN || cerr == .EALREADY {
		terr := dial_wait_connected(fd, timeout)
		if terr != .None {
			_ = linux.close(fd)
			return nil, terr
		}
	} else if cerr == .NONE || cerr == .EISCONN {
		// connected
	} else if cerr != .NONE {
		_ = linux.close(fd)
		if cerr == .ETIMEDOUT {
			return nil, .Timeout
		}
		if cerr == .EINVAL {
			return nil, .InvalidEndpoint
		}
		return nil, .Network
	}
	sock := net.TCP_Socket(net.Socket(fd))
	if net.set_blocking(sock, true) != nil {
		net.close(sock)
		return nil, .Network
	}
	nodelay: b32 = true
	_ = linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.NODELAY, &nodelay)
	conn, aerr := connection_alloc(sock, allocator)
	if aerr != .None {
		net.close(sock)
		return nil, aerr
	}
	conn.remote = endpoint
	return conn, .None
}

@(private)
dial_sock_addr :: proc(endpoint: net.Endpoint) -> linux.Sock_Addr_Any {
	switch a in endpoint.address {
	case net.IP4_Address:
		return {
			ipv4 = {
				sin_family = .INET,
				sin_port = u16be(u16(endpoint.port)),
				sin_addr = ([4]u8)(a),
			},
		}
	case net.IP6_Address:
		raw := transmute([16]u8)a
		return {
			ipv6 = {
				sin6_family = .INET6,
				sin6_port = u16be(u16(endpoint.port)),
				sin6_addr = raw,
			},
		}
	case:
		return {}
	}
}

@(private)
dial_wait_connected :: proc(fd: linux.Fd, timeout: time.Duration) -> TransportError {
	deadline := time.time_add(time.now(), timeout)
	for {
		left := time.diff(time.now(), deadline)
		if left <= 0 {
			return .Timeout
		}
		ms := i64(left) / 1_000_000
		if ms < 1 {
			ms = 1
		}
		if ms > 2_000_000_000 {
			ms = 2_000_000_000
		}
		pfd := linux.Poll_Fd {
			fd = fd,
			events = {.OUT},
		}
		n, perr := linux.poll([]linux.Poll_Fd{pfd}, i32(ms))
		if perr == .EINTR {
			continue
		}
		if perr != .NONE {
			return .Network
		}
		if n == 0 {
			return .Timeout
		}
		soerr: i32
		_, gerr := linux.getsockopt_base(fd, int(linux.SOL_SOCKET), linux.Socket_Option.ERROR, &soerr)
		if gerr != .NONE {
			return .Network
		}
		if soerr == 0 {
			return .None
		}
		if linux.Errno(soerr) == .ETIMEDOUT || linux.Errno(soerr) == .EAGAIN {
			return .Timeout
		}
		return .Network
	}
}
