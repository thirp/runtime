package transport

import "core:c"

SSL :: distinct rawptr
SSL_CTX :: distinct rawptr
SSL_METHOD :: distinct rawptr
BIO :: distinct rawptr

SSL_FILETYPE_PEM :: 1
TLS1_2_VERSION :: 0x0303
SSL_VERIFY_NONE :: 0
SSL_VERIFY_PEER :: 1
SSL_ERROR_NONE :: 0
SSL_ERROR_SSL :: 1
SSL_ERROR_WANT_READ :: 2
SSL_ERROR_WANT_WRITE :: 3
SSL_ERROR_SYSCALL :: 5
SSL_ERROR_ZERO_RETURN :: 6
SSL_CTRL_MODE :: 33
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
SSL_MODE_ENABLE_PARTIAL_WRITE :: 1
SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER :: 2
TLSEXT_NAMETYPE_HOST_NAME :: 0
X509_V_OK :: 0
OPENSSL_INIT_LOAD_CRYPTO_STRINGS :: 0x00000002
OPENSSL_INIT_LOAD_SSL_STRINGS :: 0x00200000
SSL_TLSEXT_ERR_OK :: 0
SSL_TLSEXT_ERR_ALERT_FATAL :: 2
BIO_NOCLOSE :: 0
BIO_CTRL_SET_CLOSE :: 9

AlpnSelectCb :: #type proc "c" (
	ssl: SSL,
	out: ^^u8,
	outlen: ^u8,
	in_data: [^]u8,
	inlen: c.uint,
	arg: rawptr,
) -> c.int

foreign import openssl {
	"system:ssl",
	"system:crypto",
}

foreign openssl {
	OPENSSL_init_ssl :: proc(opts: u64, settings: rawptr) -> c.int ---
	TLS_server_method :: proc() -> SSL_METHOD ---
	TLS_client_method :: proc() -> SSL_METHOD ---
	SSL_CTX_new :: proc(method: SSL_METHOD) -> SSL_CTX ---
	SSL_CTX_free :: proc(ctx: SSL_CTX) ---
	SSL_CTX_ctrl :: proc(ctx: SSL_CTX, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_CTX_use_certificate_file :: proc(ctx: SSL_CTX, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_use_PrivateKey_file :: proc(ctx: SSL_CTX, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_check_private_key :: proc(ctx: SSL_CTX) -> c.int ---
	SSL_CTX_set_verify :: proc(ctx: SSL_CTX, mode: c.int, callback: rawptr) ---
	SSL_CTX_set_default_verify_paths :: proc(ctx: SSL_CTX) -> c.int ---
	SSL_CTX_load_verify_locations :: proc(ctx: SSL_CTX, ca_file: cstring, ca_path: cstring) -> c.int ---
	SSL_new :: proc(ctx: SSL_CTX) -> SSL ---
	SSL_free :: proc(ssl: SSL) ---
	SSL_set_fd :: proc(ssl: SSL, fd: c.int) -> c.int ---
	SSL_get_rbio :: proc(ssl: SSL) -> BIO ---
	BIO_ctrl :: proc(b: BIO, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_accept :: proc(ssl: SSL) -> c.int ---
	SSL_connect :: proc(ssl: SSL) -> c.int ---
	SSL_read :: proc(ssl: SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_write :: proc(ssl: SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_set_quiet_shutdown :: proc(ssl: SSL, mode: c.int) ---
	SSL_get_error :: proc(ssl: SSL, ret_code: c.int) -> c.int ---
	SSL_ctrl :: proc(ssl: SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_set1_host :: proc(ssl: SSL, hostname: cstring) -> c.int ---
	SSL_get_verify_result :: proc(ssl: SSL) -> c.long ---
	SSL_get_servername :: proc(ssl: SSL, type: c.int) -> cstring ---
	SSL_CTX_set_alpn_select_cb :: proc(ctx: SSL_CTX, cb: AlpnSelectCb, arg: rawptr) ---
	SSL_set_alpn_protos :: proc(ssl: SSL, protos: [^]u8, protos_len: c.uint) -> c.int ---
	ERR_clear_error :: proc() ---
}

ssl_ctx_set_min_proto_tls12 :: proc(ctx: SSL_CTX) -> bool {
	rc := SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, c.long(TLS1_2_VERSION), nil)
	return rc != 0
}

ssl_enable_partial_write :: proc(ssl: SSL) {
	_ = SSL_ctrl(
		ssl,
		SSL_CTRL_MODE,
		c.long(SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER),
		nil,
	)
}

ssl_set_sni :: proc(ssl: SSL, name: cstring) {
	_ = SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_HOST_NAME, rawptr(name))
}

ssl_set_fd_noclose :: proc(ssl: SSL, fd: c.int) -> bool {
	if SSL_set_fd(ssl, fd) != 1 {
		return false
	}
	bio := SSL_get_rbio(ssl)
	if bio == nil {
		return false
	}
	_ = BIO_ctrl(bio, BIO_CTRL_SET_CLOSE, c.long(BIO_NOCLOSE), nil)
	return true
}
