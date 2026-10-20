package transport

import "core:net"
import "core:sync"
import "core:time"

READ_BUF_SIZE :: 4096

parse_endpoint :: proc(value: string) -> (net.Endpoint, TransportError) {
	ep, ok := net.parse_endpoint(value)
	if !ok {
		return {}, .InvalidEndpoint
	}
	return ep, .None
}

// Host part of HOST:PORT or [IPv6]:PORT. IP-only parse_endpoint stays for listen.
endpoint_host :: proc(value: string) -> (string, bool) {
	host, _, ok := net.split_port(value)
	if !ok || len(host) == 0 {
		return "", false
	}
	return host, true
}

// IP or DNS HOST:PORT. Prefers A over AAAA. Listen addresses keep parse_endpoint.
resolve_endpoint :: proc(value: string) -> (net.Endpoint, TransportError) {
	ep4, ep6, err := net.resolve(value)
	if err != nil {
		return {}, .InvalidEndpoint
	}
	if ep4.address != nil {
		return ep4, .None
	}
	if ep6.address != nil {
		return ep6, .None
	}
	return {}, .InvalidEndpoint
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

// Start an operation that touches conn.socket or conn.tls. False once close
// has started (the fd may be released at any moment) or once the struct is
// being freed. A true return also holds a reference, so neither the fd nor
// the Connection itself can go away while the operation runs, even if the
// owner destroys it from another thread. Pair every true with conn_io_exit.
@(private)
conn_io_enter :: proc(conn: ^Connection) -> bool {
	if !connection_acquire(conn) {
		return false
	}
	sync.atomic_add(&conn.io_inflight, 1)
	if sync.atomic_load(&conn.close_started) {
		conn_io_exit(conn)
		return false
	}
	return true
}

// End an operation. The last one out after close started releases the fd;
// dropping the operation's reference may then free the Connection.
@(private)
conn_io_exit :: proc(conn: ^Connection) {
	prev := sync.atomic_sub(&conn.io_inflight, 1)
	if prev == 1 && sync.atomic_load(&conn.close_started) {
		conn_release_fd(conn)
	}
	connection_release(conn)
}

@(private)
conn_closing :: proc(conn: ^Connection) -> bool {
	return sync.atomic_load(&conn.close_started)
}

// Free TLS and close the fd/handle. Runs once, only when no operation holds
// io_inflight, so nothing can still be using either.
@(private)
conn_release_fd :: proc(conn: ^Connection) {
	if _, won := sync.atomic_compare_exchange_strong(&conn.fd_released, false, true); !won {
		return
	}
	tls_connection_close(conn)
	if conn.socket != 0 {
		net.close(conn.socket)
		conn.socket = 0
	}
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
	if !conn_io_enter(conn) {
		return 0, .Closed
	}
	defer conn_io_exit(conn)
	if conn.tls != nil {
		return tls_connection_read(conn, dst)
	}
	sock := conn.socket
	if hook := sync.atomic_load(&conn.read_hook); hook != nil {
		(IoHook)(hook)(conn)
	}
	bytes_read, recv_err := net.recv_tcp(sock, dst)
	for recv_err == .Interrupted && bytes_read == 0 && !conn_closing(conn) {
		bytes_read, recv_err = net.recv_tcp(sock, dst)
	}
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
	if !conn_io_enter(conn) {
		return 0, .Closed
	}
	defer conn_io_exit(conn)
	return connection_peek_impl(conn, dst)
}

connection_set_recv_lowat :: proc(conn: ^Connection, n: int) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	if !conn_io_enter(conn) {
		return .Closed
	}
	defer conn_io_exit(conn)
	return connection_set_recv_lowat_impl(conn, n)
}

connection_write :: proc(conn: ^Connection, src: []u8) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	// Enter before locking so the reference outlives the unlock (defers run
	// in reverse: unlock, then exit).
	if !conn_io_enter(conn) {
		return .Closed
	}
	defer conn_io_exit(conn)
	sync.mutex_lock(&conn.write_mutex)
	defer sync.mutex_unlock(&conn.write_mutex)
	if conn.closed || conn_closing(conn) {
		return .Closed
	}
	if conn.tls != nil {
		return tls_connection_write(conn, src)
	}
	// A signal (EINTR) must not end the stream: resume after the bytes the
	// interrupted send already took.
	sock := conn.socket
	if hook := sync.atomic_load(&conn.write_hook); hook != nil {
		(IoHook)(hook)(conn)
	}
	off := 0
	send_err: net.TCP_Send_Error
	for {
		sent: int
		sent, send_err = net.send_tcp(sock, src[off:])
		off += sent
		if send_err != .Interrupted || off >= len(src) || conn_closing(conn) {
			break
		}
	}
	if send_err == .Interrupted {
		send_err = .None
	}
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
	if !conn_io_enter(conn) {
		return .Closed
	}
	defer conn_io_exit(conn)
	conn.recv_timeout = timeout
	opt_err := net.set_option(conn.socket, .Receive_Timeout, timeout)
	if opt_err != .None {
		return .Network
	}
	return .None
}

// Send timeout for TLS WANT_WRITE polls and SO_SNDTIMEO on the TCP socket.
// Zero means block until the peer drains (preferred for DATA backpressure).
// Must not share the short recv_timeout used by relay heartbeat polling —
// that incorrectly turns healthy backpressure into write Timeout / RESET.
connection_set_send_timeout :: proc(conn: ^Connection, timeout: time.Duration) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	if !conn_io_enter(conn) {
		return .Closed
	}
	defer conn_io_exit(conn)
	conn.send_timeout = timeout
	opt_err := net.set_option(conn.socket, .Send_Timeout, timeout)
	if opt_err != .None {
		return .Network
	}
	return .None
}

// Close the connection. Safe against concurrent IO on other threads: marks it
// closed, shuts the socket down so blocked send/recv/poll return (and aborts
// pending Winsock IO), and leaves releasing the fd and TLS session to the
// last operation still inside (or does it here when none is). The fd number
// therefore cannot be reused while any thread might still send or recv on it.
connection_close :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	sync.atomic_store(&conn.closed, true)
	if !connection_acquire(conn) {
		return // already being freed; nothing left to close
	}
	sync.atomic_add(&conn.io_inflight, 1) // keep the fd while we shut it down
	if _, won := sync.atomic_compare_exchange_strong(&conn.close_started, false, true); won {
		// Only shut down when another thread is inside an operation; with
		// none, the fd is closed right away exactly as before (same FIN/RST
		// the peer always saw). Anyone entering from here on backs out.
		if conn.socket != 0 && sync.atomic_load(&conn.io_inflight) > 1 {
			_ = net.shutdown(conn.socket, .Both)
			connection_abort_io_impl(conn)
		}
	}
	conn_io_exit(conn)
}

connection_shutdown_write :: proc(conn: ^Connection) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	if !conn_io_enter(conn) {
		return .Closed
	}
	defer conn_io_exit(conn)
	err := net.shutdown(conn.socket, .Send)
	if err != .None {
		return .Network
	}
	return .None
}

// Wait until a read would not block (data, EOF or error) or timeout passes.
// Lets a reader poll a stop flag instead of relying on shutdown() from
// another thread to wake a blocking recv, which Windows does not promise.
connection_wait_readable :: proc(conn: ^Connection, timeout: time.Duration) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	if !conn_io_enter(conn) {
		return .Closed
	}
	defer conn_io_exit(conn)
	return tls_wait_socket_impl(conn, false, timeout)
}

// Wake a reader or poller on another thread. Does not free TLS or the fd;
// the owning thread still runs connection_destroy.
connection_shutdown_both :: proc(conn: ^Connection) {
	if conn == nil || !conn_io_enter(conn) {
		return
	}
	defer conn_io_exit(conn)
	if conn.socket == 0 {
		return
	}
	sync.atomic_store(&conn.closed, true)
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

// Wait until accept would not block, or timeout passes. SO_RCVTIMEO bounds
// accept() on Linux but not on Windows, so a loop that must notice a stop
// flag waits here first instead of relying on listener_set_recv_timeout.
listener_wait_acceptable :: proc(l: ^Listener, timeout: time.Duration) -> TransportError {
	if l == nil || l.closed {
		return .Closed
	}
	tmp := Connection{socket = l.socket}
	return tls_wait_socket_impl(&tmp, false, timeout)
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
