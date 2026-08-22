package transport

import "core:c"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

TLS_HANDSHAKE_TIMEOUT :: 10 * time.Second

openssl_once: sync.Once

openssl_ensure_init :: proc() {
	sync.once_do(&openssl_once, proc() {
		_ = OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, nil)
		_ = posix.sigignore(.SIGPIPE)
	})
}

tls_server_context_init :: proc(
	cert_path, key_path: string,
	allocator := context.allocator,
) -> (
	^TlsServerContext,
	TransportError,
) {
	openssl_ensure_init()
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
	SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)

	cert_c := strings.clone_to_cstring(cert_path, allocator)
	defer delete(cert_c, allocator)
	key_c := strings.clone_to_cstring(key_path, allocator)
	defer delete(key_c, allocator)

	if SSL_CTX_use_certificate_file(ctx, cert_c, SSL_FILETYPE_PEM) != 1 {
		SSL_CTX_free(ctx)
		return nil, .Tls
	}
	if SSL_CTX_use_PrivateKey_file(ctx, key_c, SSL_FILETYPE_PEM) != 1 {
		SSL_CTX_free(ctx)
		return nil, .Tls
	}
	if SSL_CTX_check_private_key(ctx) != 1 {
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

tls_client_context_new :: proc(cfg: TlsClientConfig, allocator := context.allocator) -> (SSL_CTX, TransportError) {
	openssl_ensure_init()
	ctx := SSL_CTX_new(TLS_client_method())
	if ctx == nil {
		return nil, .Tls
	}
	if !ssl_ctx_set_min_proto_tls12(ctx) {
		SSL_CTX_free(ctx)
		return nil, .Tls
	}
	SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
	if len(cfg.ca_path) == 0 {
		if SSL_CTX_set_default_verify_paths(ctx) != 1 {
			SSL_CTX_free(ctx)
			return nil, .Tls
		}
	} else {
		ca_c := strings.clone_to_cstring(cfg.ca_path, allocator)
		defer delete(ca_c, allocator)
		if SSL_CTX_load_verify_locations(ctx, ca_c, nil) != 1 {
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
	if conn == nil || conn.closed || ctx == nil || ctx.ctx == nil {
		return .Tls
	}
	openssl_ensure_init()
	ERR_clear_error()
	ssl := SSL_new(ctx.ctx)
	if ssl == nil {
		return .Tls
	}
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
	_ = connection_set_recv_timeout(conn, handshake_timeout)
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
	owned_ctx, cerr := tls_client_context_new(cfg, allocator)
	if cerr != .None {
		connection_destroy(conn, allocator)
		return nil, cerr
	}
	ERR_clear_error()
	ssl := SSL_new(owned_ctx)
	if ssl == nil {
		SSL_CTX_free(owned_ctx)
		connection_destroy(conn, allocator)
		return nil, .Tls
	}
	ssl_enable_partial_write(ssl)
	if !ssl_set_fd_noclose(ssl, connection_socket_fd(conn)) {
		SSL_free(ssl)
		SSL_CTX_free(owned_ctx)
		connection_destroy(conn, allocator)
		return nil, .Tls
	}
	name_c := strings.clone_to_cstring(cfg.server_name, allocator)
	defer delete(name_c, allocator)
	if SSL_set1_host(ssl, name_c) != 1 {
		SSL_free(ssl)
		SSL_CTX_free(owned_ctx)
		connection_destroy(conn, allocator)
		return nil, .Tls
	}
	if !cfg.omit_sni {
		ssl_set_sni(ssl, name_c)
	}
	if len(cfg.alpn) > 0 {
		if SSL_set_alpn_protos(ssl, raw_data(cfg.alpn), c.uint(len(cfg.alpn))) != 0 {
			SSL_free(ssl)
			SSL_CTX_free(owned_ctx)
			connection_destroy(conn, allocator)
			return nil, .Tls
		}
	}

	_ = connection_set_recv_timeout(conn, TLS_HANDSHAKE_TIMEOUT)
	rc := SSL_connect(ssl)
	if rc != 1 || SSL_get_verify_result(ssl) != X509_V_OK {
		SSL_free(ssl)
		SSL_CTX_free(owned_ctx)
		connection_destroy(conn, allocator)
		return nil, .Tls
	}
	aerr := tls_attach_ssl(conn, ssl, owned_ctx)
	if aerr != .None {
		connection_destroy(conn, allocator)
		return nil, aerr
	}
	return conn, .None
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

tls_poll :: proc(conn: ^Connection, want_write: bool, timeout: time.Duration) -> TransportError {
	if conn == nil || conn.closed {
		return .Closed
	}
	pfd: posix.pollfd
	pfd.fd = posix.FD(connection_socket_fd(conn))
	pfd.events = want_write ? {.OUT} : {.IN}
	n := posix.poll(&pfd, 1, tls_poll_timeout_ms(timeout))
	if n == 0 {
		return .Timeout
	}
	if n < 0 {
		return .Network
	}
	if .NVAL in pfd.revents {
		conn.closed = true
		return .Closed
	}
	ready := want_write ? (.OUT in pfd.revents) : (.IN in pfd.revents)
	if ready {
		return .None
	}
	if .HUP in pfd.revents || .ERR in pfd.revents {
		conn.closed = true
		return .Closed
	}
	return .None
}

tls_map_ssl_error :: proc(conn: ^Connection, rc: c.int, ssl_err: c.int) -> TransportError {
	_ = rc
	switch ssl_err {
	case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
		return .WouldBlock
	case SSL_ERROR_ZERO_RETURN:
		conn.closed = true
		return .Closed
	case SSL_ERROR_SYSCALL:
		conn.closed = true
		return .Closed
	}
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
		rc := SSL_read(conn.tls.ssl, raw_data(dst), c.int(to_read))
		ssl_err := SSL_get_error(conn.tls.ssl, rc)
		sync.mutex_unlock(&conn.tls.mutex)
		if rc > 0 {
			return int(rc), .None
		}
		mapped := tls_map_ssl_error(conn, rc, ssl_err)
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
		rc := SSL_write(conn.tls.ssl, raw_data(src[off:]), c.int(remain))
		ssl_err := SSL_get_error(conn.tls.ssl, rc)
		sync.mutex_unlock(&conn.tls.mutex)
		if rc > 0 {
			off += int(rc)
			continue
		}
		mapped := tls_map_ssl_error(conn, rc, ssl_err)
		if mapped != .WouldBlock {
			return mapped
		}
		poll_err := tls_poll(conn, ssl_err != SSL_ERROR_WANT_READ, conn.recv_timeout)
		if poll_err != .None {
			return poll_err
		}
	}
	return .None
}

tls_connection_close :: proc(conn: ^Connection) {
	if conn.tls == nil {
		return
	}
	tls_session_free(conn)
}
