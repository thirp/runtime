package transport

import "core:c"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

TLS_HANDSHAKE_TIMEOUT :: 10 * time.Second

openssl_once: sync.Once

openssl_ensure_init :: proc() {
	sync.once_do(&openssl_once, openssl_once_init)
}

tls_server_context_init :: proc(
	cert_path, key_path: string,
	allocator := context.allocator,
	allow_key_prompt := true,
) -> (
	^TlsServerContext,
	TransportError,
) {
	openssl_ensure_init()
	ERR_clear_error()
	defer ERR_clear_error()
	if len(cert_path) == 0 || len(key_path) == 0 {
		return nil, .Tls
	}
	ctx := SSL_CTX_new(TLS_server_method())
	if ctx == nil {
		return nil, .Tls
	}
	if !ssl_ctx_set_min_proto_tls12(ctx) {
		SSL_CTX_free(ctx)
		return nil, .Tls
	}
	// Peer SHUT_WR is a FIN, not a broken TLS session. Without this, the
	// read fails hard and a response still in flight cannot be written.
	_ = SSL_CTX_set_options(ctx, SSL_OP_IGNORE_UNEXPECTED_EOF)
	SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)

	loaded: bool
	if allow_key_prompt {
		cert_c := strings.clone_to_cstring(cert_path, allocator)
		defer delete(cert_c, allocator)
		key_c := strings.clone_to_cstring(key_path, allocator)
		defer delete(key_c, allocator)
		loaded = SSL_CTX_use_certificate_chain_file(ctx, cert_c) == 1 &&
		         SSL_CTX_use_PrivateKey_file(ctx, key_c, SSL_FILETYPE_PEM) == 1
	} else {
		SSL_CTX_set_default_passwd_cb(ctx, tls_no_pem_password)
		loaded = tls_load_reload_pem(ctx, cert_path, key_path, allocator)
	}
	if !loaded || SSL_CTX_check_private_key(ctx) != 1 {
		SSL_CTX_free(ctx)
		return nil, .Tls
	}

	server, aerr := new(TlsServerContext, allocator)
	if aerr != .None {
		SSL_CTX_free(ctx)
		return nil, .OutOfMemory
	}
	server.ctx = ctx
	server.allocator = allocator
	return server, .None
}

tls_server_context_destroy :: proc(ctx: ^TlsServerContext) {
	if ctx == nil {
		return
	}
	if ctx.ctx != nil {
		SSL_CTX_free(ctx.ctx)
		ctx.ctx = nil
	}
	free(ctx, ctx.allocator)
}

ALPN_HTTP11 :: [8]u8{'h', 't', 't', 'p', '/', '1', '.', '1'}

ssl_alpn_select_http11 :: proc "c" (
	ssl: SSL,
	out: ^^u8,
	outlen: ^u8,
	in_data: [^]u8,
	inlen: c.uint,
	arg: rawptr,
) -> c.int {
	_ = ssl
	_ = arg
	want := ALPN_HTTP11
	i: c.uint = 0
	for i < inlen {
		n := c.uint(in_data[i])
		i += 1
		if n == 0 || i + n > inlen {
			return SSL_TLSEXT_ERR_ALERT_FATAL
		}
		if n == c.uint(len(want)) {
			match := true
			for j in 0 ..< len(want) {
				if in_data[i + c.uint(j)] != want[j] {
					match = false
					break
				}
			}
			if match {
				out^ = &in_data[i]
				outlen^ = u8(n)
				return SSL_TLSEXT_ERR_OK
			}
		}
		i += n
	}
	return SSL_TLSEXT_ERR_ALERT_FATAL
}

tls_server_context_set_alpn_http11 :: proc(ctx: ^TlsServerContext) {
	if ctx == nil || ctx.ctx == nil {
		return
	}
	SSL_CTX_set_alpn_select_cb(ctx.ctx, ssl_alpn_select_http11, nil)
}

connection_tls_servername :: proc(conn: ^Connection) -> string {
	if conn == nil || conn.tls == nil || conn.tls.ssl == nil {
		return ""
	}
	name := SSL_get_servername(conn.tls.ssl, TLSEXT_NAMETYPE_HOST_NAME)
	if name == nil {
		return ""
	}
	return string(name)
}

tls_client_context_new :: proc(cfg: TlsClientConfig, verify_failed: ^bool, allocator := context.allocator) -> (SSL_CTX, TransportError) {
	openssl_ensure_init()
	ctx := SSL_CTX_new(TLS_client_method())
	if ctx == nil {
		return nil, .Tls
	}
	if !ssl_ctx_set_min_proto_tls12(ctx) {
		SSL_CTX_free(ctx)
		return nil, .Tls
	}
	// SSL_OP_IGNORE_UNEXPECTED_EOF on OpenSSL 3.5.7: a TCP FIN with no
	// close_notify is a clean EOF, and so is a TLS record cut mid-way.
	// Both are SSL_ERROR_ZERO_RETURN, mapped to TransportError.Closed,
	// not .Tls. Frames are length-prefixed, so that is safe. read_frame
	// returns ProtocolError.Truncated when EOF leaves a short frame
	// buffered, and the session ends. A FIN after a complete frame leaves
	// the decoder empty, so the next read is a clean close.
	_ = SSL_CTX_set_options(ctx, SSL_OP_IGNORE_UNEXPECTED_EOF)
	SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
	if len(cfg.ca_path) == 0 {
		if !tls_client_context_load_system_ca(ctx) {
			if verify_failed != nil {verify_failed^ = true}
			SSL_CTX_free(ctx)
			return nil, .Tls
		}
	} else {
		ca_c := strings.clone_to_cstring(cfg.ca_path, allocator)
		defer delete(ca_c, allocator)
		if SSL_CTX_load_verify_locations(ctx, ca_c, nil) != 1 {
			if verify_failed != nil {verify_failed^ = true}
			SSL_CTX_free(ctx)
			return nil, .Tls
		}
	}
	return ctx, .None
}

connection_socket_fd :: proc(conn: ^Connection) -> c.int {
	return c.int(conn.socket)
}

tls_attach_ssl :: proc(conn: ^Connection, ssl: SSL, owned_ctx: SSL_CTX) -> TransportError {
	session, aerr := new(TlsSession, conn.allocator)
	if aerr != .None {
		SSL_free(ssl)
		if owned_ctx != nil {
			SSL_CTX_free(owned_ctx)
		}
		return .OutOfMemory
	}
	session.ssl = ssl
	session.ctx = owned_ctx
	conn.tls = session
	SSL_set_info_callback(ssl, tls_info_callback)
	if err := net.set_blocking(conn.socket, false); err != nil {
		tls_session_free(conn)
		return .Network
	}
	return .None
}

tls_session_free :: proc(conn: ^Connection) {
	if conn == nil || conn.tls == nil {
		return
	}
	session := conn.tls
	conn.tls = nil
	if session.ssl != nil {
		SSL_set_quiet_shutdown(session.ssl, 1)
		SSL_free(session.ssl)
		session.ssl = nil
	}
	if session.ctx != nil {
		SSL_CTX_free(session.ctx)
		session.ctx = nil
	}
	free(session, conn.allocator)
}

connection_tls_accept :: proc(
	conn: ^Connection,
	ctx: ^TlsServerContext,
	timeout := TLS_HANDSHAKE_TIMEOUT,
) -> TransportError {
	if conn == nil || conn.closed {
		return .Tls
	}
	return connection_tls_accept_session(conn, tls_server_session_new(ctx), timeout)
}

// SSL_new retains the OpenSSL context independently of the Odin wrapper.
tls_server_session_new :: proc(ctx: ^TlsServerContext) -> SSL {
	if ctx == nil || ctx.ctx == nil {
		return nil
	}
	ERR_clear_error()
	return SSL_new(ctx.ctx)
}

// Takes ownership of ssl. The context owner can publish a replacement while
// this handshake is in progress or while the resulting session is in use.
connection_tls_accept_session :: proc(
	conn: ^Connection,
	ssl: SSL,
	timeout := TLS_HANDSHAKE_TIMEOUT,
) -> TransportError {
	if ssl == nil {
		return .Tls
	}
	if conn == nil || conn.closed {
		SSL_free(ssl)
		return .Tls
	}
	if !conn_io_enter(conn) {
		SSL_free(ssl)
		return .Tls
	}
	defer conn_io_exit(conn)
	ssl_enable_partial_write(ssl)
	if !ssl_set_fd_noclose(ssl, connection_socket_fd(conn)) {
		SSL_free(ssl)
		return .Tls
	}
	handshake_timeout := timeout
	if handshake_timeout <= 0 {
		handshake_timeout = TLS_HANDSHAKE_TIMEOUT
	}
	start := time.now()
	// SSL_accept uses the blocking socket until TLS is attached.
	_ = connection_set_recv_timeouts(conn, handshake_timeout, handshake_timeout)
	rc := SSL_accept(ssl)
	if rc != 1 {
		SSL_free(ssl)
		if time.since(start) >= handshake_timeout {
			return .Timeout
		}
		return .Tls
	}
	return tls_attach_ssl(conn, ssl, nil)
}

connection_dial_tls :: proc(
	endpoint: net.Endpoint,
	cfg: TlsClientConfig,
	allocator := context.allocator,
) -> (
	^Connection,
	TransportError,
) {
	if len(cfg.server_name) == 0 {
		return nil, .Tls
	}
	conn, derr := connection_dial(endpoint, allocator)
	if derr != .None {
		return nil, derr
	}
	err := connection_tls_connect(conn, cfg)
	if err != .None {
		connection_destroy(conn, allocator)
		return nil, err
	}
	return conn, .None
}

// Upgrade an owned TCP connection before sharing it. The caller may bound
// the entire setup by shutting down this socket at its absolute deadline.
// Keep the legacy TLS receive timeout for users of connection_dial_tls.
connection_tls_connect :: proc(conn: ^Connection, cfg: TlsClientConfig, timeout := TLS_HANDSHAKE_TIMEOUT,
	verify_failed: ^bool = nil, verify_ip := false) -> TransportError {
	if verify_failed != nil {verify_failed^ = false}
	if conn == nil || len(cfg.server_name) == 0 || !conn_io_enter(conn) {
		return .Tls
	}
	defer conn_io_exit(conn)
	allocator := conn.allocator
	owned_ctx, cerr := tls_client_context_new(cfg, verify_failed, allocator)
	if cerr != .None {
		return cerr
	}
	ERR_clear_error()
	ssl := SSL_new(owned_ctx)
	if ssl == nil {
		SSL_CTX_free(owned_ctx)
		return .Tls
	}
	ssl_enable_partial_write(ssl)
	if !ssl_set_fd_noclose(ssl, connection_socket_fd(conn)) {
		SSL_free(ssl)
		SSL_CTX_free(owned_ctx)
		return .Tls
	}
	name_c := strings.clone_to_cstring(cfg.server_name, allocator)
	defer delete(name_c, allocator)
	name_ok := verify_ip ? X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), name_c) : SSL_set1_host(ssl, name_c)
	if name_ok != 1 {
		if verify_failed != nil {verify_failed^ = true}
		SSL_free(ssl)
		SSL_CTX_free(owned_ctx)
		return .Tls
	}
	if !cfg.omit_sni && !verify_ip {
		ssl_set_sni(ssl, name_c)
	}
	if len(cfg.alpn) > 0 {
		if SSL_set_alpn_protos(ssl, raw_data(cfg.alpn), c.uint(len(cfg.alpn))) != 0 {
			SSL_free(ssl)
			SSL_CTX_free(owned_ctx)
			return .Tls
		}
	}

	// SSL_connect uses the blocking socket until TLS is attached.
	_ = connection_set_recv_timeouts(conn, timeout, timeout)
	rc := SSL_connect(ssl)
	verified := SSL_get_verify_result(ssl) == X509_V_OK
	if rc != 1 || !verified {
		if verify_failed != nil {verify_failed^ = !verified}
		SSL_free(ssl)
		SSL_CTX_free(owned_ctx)
		return .Tls
	}
	aerr := tls_attach_ssl(conn, ssl, owned_ctx)
	if aerr != .None {
		return aerr
	}
	return .None
}

tls_poll_timeout_ms :: proc(timeout: time.Duration) -> c.int {
	if timeout <= 0 {
		return -1
	}
	ms := timeout / time.Millisecond
	if ms <= 0 {
		return 0
	}
	if ms > time.Duration(max(c.int)) {
		return max(c.int)
	}
	return c.int(ms)
}

tls_wait_socket :: proc(conn: ^Connection, want_write: bool, timeout: time.Duration, defer_on_interrupt := false) -> TransportError {
	err: TransportError
	when ODIN_TEST {
		if conn != nil && sync.atomic_exchange(&conn.test_interrupt_poll, false) {
			err = .WouldBlock
		}
	}
	if err == .None {
		err = tls_wait_socket_impl(conn, want_write, timeout)
	}
	// The native wait reports interruption as WouldBlock. A keepalive can
	// defer because it has not started a write. Other callers keep the
	// existing error handling, including during a partial frame write.
	return .Network if err == .WouldBlock && !defer_on_interrupt else err
}

tls_poll :: proc(conn: ^Connection, want_write: bool, timeout: time.Duration) -> TransportError {
	return tls_wait_socket(conn, want_write, timeout)
}

// OpenSSL calls this synchronously on the SSL_read/SSL_write thread. A
// close_notify is a warning alert and retains the existing half-close path.
@(private, thread_local)
tls_fatal_alert: bool

@(private)
tls_info_callback :: proc "c" (ssl: SSL, flags, ret: c.int) {
	if flags & SSL_CB_ALERT != 0 && ret >> 8 == SSL3_AL_FATAL {
		tls_fatal_alert = true
	}
}

tls_map_ssl_error :: proc(conn: ^Connection, ssl_err: c.int, code: i32, alert: bool) -> TransportError {
	switch ssl_err {
	case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
		return .WouldBlock
	case SSL_ERROR_ZERO_RETURN:
		// close_notify, or a TCP FIN accepted by SSL_OP_IGNORE_UNEXPECTED_EOF.
		// The reply can still be written. Do not set conn.closed.
		connection_note_close(conn, .PeerEOF)
		return .Closed
	case SSL_ERROR_SYSCALL:
		cause := socket_error_cause(code)
		connection_note_close(conn, cause)
		when ODIN_OS == .Linux {
			if cause == .ReadDeadline {
				conn.user_timed_out = true
			}
		}
		conn.closed = true
		return .Closed
	}
	connection_note_close(conn, .TLSAlert if alert else .TLSError)
	return .Tls
}

tls_connection_read :: proc(conn: ^Connection, dst: []u8) -> (n: int, err: TransportError) {
	if len(dst) == 0 {
		return 0, .None
	}
	to_read := min(len(dst), int(max(c.int)))
	for {
		if conn.closed {
			return 0, .Closed
		}
		sync.mutex_lock(&conn.tls.mutex)
		if conn.closed || conn.tls.ssl == nil {
			sync.mutex_unlock(&conn.tls.mutex)
			return 0, .Closed
		}
		ERR_clear_error()
		tls_fatal_alert = false
		rc := SSL_read(conn.tls.ssl, raw_data(dst), c.int(to_read))
		code := socket_syscall_error()
		mapped: TransportError
		ssl_err: c.int
		if rc <= 0 {
			ssl_err = SSL_get_error(conn.tls.ssl, rc)
			mapped = tls_map_ssl_error(conn, ssl_err, code, tls_fatal_alert)
		}
		if hook := sync.atomic_load(&conn.tls_read_hook); hook != nil {
			(TlsReadHook)(hook)(conn)
		}
		sync.mutex_unlock(&conn.tls.mutex)
		if rc > 0 {
			return int(rc), .None
		}
		if mapped != .WouldBlock {
			return 0, mapped
		}
		poll_err := tls_poll(conn, ssl_err == SSL_ERROR_WANT_WRITE, conn.recv_timeout)
		if poll_err != .None {
			return 0, poll_err
		}
	}
}

tls_connection_write :: proc(conn: ^Connection, src: []u8) -> TransportError {
	if len(src) == 0 {
		return .None
	}
	off := 0
	for off < len(src) {
		if conn.closed {
			return .Closed
		}
		remain := min(len(src) - off, int(max(c.int)))
		sync.mutex_lock(&conn.tls.mutex)
		if conn.closed || conn.tls.ssl == nil {
			sync.mutex_unlock(&conn.tls.mutex)
			return .Closed
		}
		ERR_clear_error()
		tls_fatal_alert = false
		rc := SSL_write(conn.tls.ssl, raw_data(src[off:]), c.int(remain))
		code := socket_syscall_error()
		mapped: TransportError
		ssl_err: c.int
		if rc <= 0 {
			ssl_err = SSL_get_error(conn.tls.ssl, rc)
			mapped = tls_map_ssl_error(conn, ssl_err, code, tls_fatal_alert)
		}
		sync.mutex_unlock(&conn.tls.mutex)
		if rc > 0 {
			off += int(rc)
			continue
		}
		if mapped != .WouldBlock {
			return mapped
		}
		poll_err := tls_poll(conn, ssl_err != SSL_ERROR_WANT_READ, conn.send_timeout)
		if poll_err != .None {
			return poll_err
		}
	}
	return .None
}

// Only from conn_release_fd (no operation in flight) or before the
// connection is shared.
tls_connection_close :: proc(conn: ^Connection) {
	if conn.tls == nil {
		return
	}
	tls_session_free(conn)
}
