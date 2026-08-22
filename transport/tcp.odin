package transport

import "core:c"
import "core:net"
import "core:sync"
import "core:sys/posix"
import "core:time"

READ_BUF_SIZE :: 4096

parse_endpoint :: proc(value: string) -> (net.Endpoint, TransportError) {
	ep, ok := net.parse_endpoint(value)
	if !ok {
		return {}, .InvalidEndpoint
	}
	return ep, .None
}

loopback_endpoint :: proc(port: int) -> net.Endpoint {
	return net.Endpoint{address = net.IP4_Loopback, port = port}
}

map_recv_error :: proc(n: int, err: net.TCP_Recv_Error) -> TransportError {
	if err != .None {
		#partial switch err {
		case .Timeout, .Would_Block:
			return .Timeout
		case .Connection_Closed, .Not_Connected:
			return .Closed
		}
		return .Network
	}
	if n == 0 {
		return .Closed
	}
	return .None
}

map_send_error :: proc(err: net.TCP_Send_Error) -> TransportError {
	if err == .None {
		return .None
	}
	#partial switch err {
	case .Timeout, .Would_Block:
		return .Timeout
	case .Not_Connected:
		return .Closed
	}
	return .Network
}

connection_alloc :: proc(socket: net.TCP_Socket, allocator := context.allocator) -> (^Connection, TransportError) {
	conn, aerr := new(Connection, allocator)
	if aerr != .None {
		net.close(socket)
		return nil, .OutOfMemory
	}
	conn.socket = socket
	conn.allocator = allocator
	conn.refs = 1
	return conn, .None
}

connection_acquire :: proc(conn: ^Connection) -> bool {
	if conn == nil {
		return false
	}
	for {
		current := sync.atomic_load(&conn.refs)
		if current <= 0 {
			return false
		}
		_, ok := sync.atomic_compare_exchange_strong(&conn.refs, current, current + 1)
		if ok {
			return true
		}
	}
}

connection_release :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	prev := sync.atomic_sub(&conn.refs, 1)
	if prev == 1 {
		free(conn, conn.allocator)
	}
}

connection_dial :: proc(endpoint: net.Endpoint, allocator := context.allocator) -> (^Connection, TransportError) {
	sock, err := net.dial_tcp(endpoint)
	if err != nil {
		#partial switch e in err {
		case net.Parse_Endpoint_Error:
			return nil, .InvalidEndpoint
		case net.Dial_Error:
			if e == .Timeout {
				return nil, .Timeout
			}
			if e == .Port_Required || e == .Invalid_Argument {
				return nil, .InvalidEndpoint
			}
		}
		return nil, .Network
	}
	conn, aerr := connection_alloc(sock, allocator)
	if aerr != .None {
		return nil, aerr
	}
	conn.remote = endpoint
	return conn, .None
}

connection_read :: proc(conn: ^Connection, dst: []u8) -> (n: int, err: TransportError) {
	if conn == nil || conn.closed {
		return 0, .Closed
	}
	if conn.tls != nil {
		return tls_connection_read(conn, dst)
	}
	bytes_read, recv_err := net.recv_tcp(conn.socket, dst)
	err = map_recv_error(bytes_read, recv_err)
	if err == .Closed {
		conn.closed = true
	}
	return bytes_read, err
}

// Peek unread TCP bytes without consuming them. Fails if TLS is already attached.
connection_peek :: proc(conn: ^Connection, dst: []u8) -> (n: int, err: TransportError) {
	if conn == nil || conn.closed {
		return 0, .Closed
	}
	if conn.tls != nil {
		return 0, .Tls
	}
	if len(dst) == 0 {
		return 0, .None
	}
	got := posix.recv(
		posix.FD(connection_socket_fd(conn)),
		raw_data(dst),
		c.size_t(len(dst)),
		{.PEEK},
	)
	if got < 0 {
		#partial switch posix.get_errno() {
		case .EAGAIN, .ETIMEDOUT:
			return 0, .Timeout
		case .ECONNRESET, .ENOTCONN, .EPIPE:
			conn.closed = true
			return 0, .Closed
		}
		return 0, .Network
	}
	if got == 0 {
		conn.closed = true
		return 0, .Closed
	}
	return int(got), .None
}

connection_set_recv_lowat :: proc(conn: ^Connection, n: int) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	val: c.int = 1
	if n > 1 {
		val = c.int(n)
	}
	rc := posix.setsockopt(
		posix.FD(connection_socket_fd(conn)),
		posix.SOL_SOCKET,
		.RCVLOWAT,
		&val,
		posix.socklen_t(size_of(val)),
	)
	if rc != .OK {
		return .Network
	}
	return .None
}

connection_write :: proc(conn: ^Connection, src: []u8) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	sync.mutex_lock(&conn.write_mutex)
	defer sync.mutex_unlock(&conn.write_mutex)
	if conn.closed {
		return .Closed
	}
	if conn.tls != nil {
		return tls_connection_write(conn, src)
	}
	_, send_err := net.send_tcp(conn.socket, src)
	err := map_send_error(send_err)
	if err == .Closed {
		conn.closed = true
	}
	return err
}

connection_set_recv_timeout :: proc(conn: ^Connection, timeout: time.Duration) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	conn.recv_timeout = timeout
	opt_err := net.set_option(conn.socket, .Receive_Timeout, timeout)
	if opt_err != .None {
		return .Network
	}
	return .None
}

connection_close :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	conn.closed = true
	tls_connection_close(conn)
	if conn.socket != 0 {
		net.close(conn.socket)
		conn.socket = 0
	}
}

connection_shutdown_write :: proc(conn: ^Connection) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	err := net.shutdown(conn.socket, .Send)
	if err != .None {
		return .Network
	}
	return .None
}

// Wake a reader or poller on another thread. Does not free TLS or the fd;
// the owning thread still runs connection_destroy.
connection_shutdown_both :: proc(conn: ^Connection) {
	if conn == nil || conn.socket == 0 {
		return
	}
	conn.closed = true
	_ = net.shutdown(conn.socket, .Both)
}

connection_destroy :: proc(conn: ^Connection, allocator := context.allocator) {
	_ = allocator
	if conn == nil {
		return
	}
	connection_close(conn)
	connection_release(conn)
}

listener_listen :: proc(endpoint: net.Endpoint) -> (Listener, TransportError) {
	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		#partial switch e in err {
		case net.Parse_Endpoint_Error:
			return {}, .InvalidEndpoint
		case net.Bind_Error:
			if e == .Invalid_Argument {
				return {}, .InvalidEndpoint
			}
		}
		return {}, .Network
	}
	return Listener{socket = sock}, .None
}

listener_endpoint :: proc(l: Listener) -> (net.Endpoint, TransportError) {
	if l.closed {
		return {}, .Closed
	}
	ep, err := net.bound_endpoint(l.socket)
	if err != .None {
		return {}, .Network
	}
	return ep, .None
}

listener_set_recv_timeout :: proc(l: ^Listener, timeout: time.Duration) -> TransportError {
	if l == nil || l.closed {
		return .Closed
	}
	opt_err := net.set_option(l.socket, .Receive_Timeout, timeout)
	if opt_err != .None {
		return .Network
	}
	return .None
}

listener_accept :: proc(l: ^Listener, allocator := context.allocator) -> (^Connection, TransportError) {
	if l == nil || l.closed {
		return nil, .Closed
	}
	sock, source, err := net.accept_tcp(l.socket)
	if err != .None {
		if l.closed {
			return nil, .Closed
		}
		#partial switch err {
		case .Timeout, .Would_Block, .Interrupted:
			return nil, .Timeout
		}
		return nil, .Network
	}
	conn, aerr := connection_alloc(sock, allocator)
	if aerr != .None {
		return nil, aerr
	}
	conn.remote = source
	return conn, .None
}

listener_close :: proc(l: ^Listener) {
	if l == nil || l.closed {
		return
	}
	l.closed = true
	net.close(l.socket)
	l.socket = 0
}
