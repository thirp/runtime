package transport

import "core:mem"
import "core:net"
import "core:sync"
import "core:time"

Connection :: struct {
	socket:        net.TCP_Socket,
	write_mutex:   sync.Mutex,
	closed:        bool,
	refs:          int,
	// Close/IO lifetime (all atomic). Every operation that touches socket or
	// tls holds io_inflight. connection_close sets close_started, shuts the
	// socket down (waking blocked IO) and only the last holder out releases
	// the fd and TLS session, exactly once (fd_released). So no send/recv/
	// SSL call can ever run on a released, possibly reused, fd or handle.
	io_inflight:   int,
	close_started: bool,
	fd_released:   bool,
	allocator:     mem.Allocator,
	remote:        net.Endpoint,
	tls:           ^TlsSession,
	recv_timeout:  time.Duration,
	send_timeout:  time.Duration, // TLS WANT_WRITE poll; 0 = block (do not use recv_timeout)
	// Test seam (atomic rawptr to a proc(^Connection)): runs inside
	// tls_connection_read between SSL_read and unlocking the TLS mutex.
	tls_read_hook: rawptr,
	// Test seams (atomic rawptr to a proc(^Connection)): run on the plain TCP
	// path after the closed check, with the socket already chosen, just before
	// send/recv. Tests use them to hold the close/IO window open. Nil in
	// production.
	write_hook:    rawptr,
	read_hook:     rawptr,
}

TlsReadHook :: proc(conn: ^Connection)
IoHook :: proc(conn: ^Connection)

Listener :: struct {
	socket: net.TCP_Socket,
	closed: bool,
}

TlsSession :: struct {
	ssl:     SSL,
	ctx:     SSL_CTX, // client-owned context; 0 if using a shared server context
	mutex:   sync.Mutex,
}

TlsServerContext :: struct {
	ctx:       SSL_CTX,
	allocator: mem.Allocator,
}

TlsClientConfig :: struct {
	ca_path:     string, // empty → system default verify paths
	server_name: string, // SNI + hostname/IP verify; required for TLS dial
	alpn:        []u8,   // OpenSSL wire format; empty → omit ALPN
	omit_sni:    bool,   // verify server_name but do not send SNI
}
