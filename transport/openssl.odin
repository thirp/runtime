package transport

import "core:c"

SSL :: distinct rawptr
SSL_CTX :: distinct rawptr
SSL_METHOD :: distinct rawptr
BIO :: distinct rawptr
ASN1_TIME :: distinct rawptr
X509_STORE :: distinct rawptr
X509_STORE_CTX :: distinct rawptr
X509_STACK :: distinct rawptr
X509 :: distinct rawptr
X509_ALGOR :: distinct rawptr
EVP_PKEY :: distinct rawptr
EVP_PKEY_CTX :: distinct rawptr

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
SSL_CB_ALERT :: 0x4000
SSL3_AL_FATAL :: 2
// OpenSSL SSL_OP_BIT(7). A TCP FIN without close_notify is a clean EOF
// (SSL_ERROR_ZERO_RETURN) so the other side can still write.
SSL_OP_IGNORE_UNEXPECTED_EOF :: u64(1) << 7
SSL_CTRL_MODE :: 33
SSL_CTRL_CHAIN_CERT :: 89
SSL_CTRL_GET_CHAIN_CERTS :: 115
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
SSL_MODE_ENABLE_PARTIAL_WRITE :: 1
SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER :: 2
TLSEXT_NAMETYPE_HOST_NAME :: 0
X509_V_OK :: 0
X509_PURPOSE_SSL_SERVER :: 2
X509_V_FLAG_PARTIAL_CHAIN :: 0x80000
X509_V_FLAG_NO_CHECK_TIME :: 0x200000
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
PemPasswordCb :: #type proc "c" (buf: [^]c.char, size, rwflag: c.int, arg: rawptr) -> c.int
SslInfoCb :: #type proc "c" (ssl: SSL, flags, ret: c.int)

when ODIN_OS == .Windows {
	// MSVC needs the .lib suffix. `system:libssl` is passed as "libssl" and
	// becomes libssl.obj (LNK1181).
	foreign import openssl {
		"system:libssl.lib",
		"system:libcrypto.lib",
	}
} else when ODIN_OS == .Darwin && #config(OPENSSL_STATIC, false) {
	// Paths are relative to this package; scripts/macos_openssl.sh stages them.
	when ODIN_ARCH == .arm64 {
		foreign import openssl {
			"build/openssl-darwin-arm64/libssl.a",
			"build/openssl-darwin-arm64/libcrypto.a",
		}
	} else when ODIN_ARCH == .amd64 {
		foreign import openssl {
			"build/openssl-darwin-amd64/libssl.a",
			"build/openssl-darwin-amd64/libcrypto.a",
		}
	} else {
		#panic("OPENSSL_STATIC supports only Darwin arm64 and amd64")
	}
} else {
	foreign import openssl {
		"system:ssl",
		"system:crypto",
	}
}

foreign openssl {
	OPENSSL_init_ssl :: proc(opts: u64, settings: rawptr) -> c.int ---
	OPENSSL_cleanse :: proc(ptr: rawptr, len: c.size_t) ---
	CRYPTO_free :: proc(ptr: rawptr, file: cstring, line: c.int) ---
	TLS_server_method :: proc() -> SSL_METHOD ---
	TLS_client_method :: proc() -> SSL_METHOD ---
	SSL_CTX_new :: proc(method: SSL_METHOD) -> SSL_CTX ---
	SSL_CTX_free :: proc(ctx: SSL_CTX) ---
	SSL_CTX_set_options :: proc(ctx: SSL_CTX, op: u64) -> u64 ---
	SSL_CTX_ctrl :: proc(ctx: SSL_CTX, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_CTX_use_certificate_file :: proc(ctx: SSL_CTX, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_use_certificate_chain_file :: proc(ctx: SSL_CTX, file: cstring) -> c.int ---
	SSL_CTX_use_certificate :: proc(ctx: SSL_CTX, cert: X509) -> c.int ---
	SSL_CTX_use_PrivateKey_file :: proc(ctx: SSL_CTX, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_use_PrivateKey :: proc(ctx: SSL_CTX, key: EVP_PKEY) -> c.int ---
	SSL_CTX_check_private_key :: proc(ctx: SSL_CTX) -> c.int ---
	SSL_CTX_set_default_passwd_cb :: proc(ctx: SSL_CTX, cb: PemPasswordCb) ---
	SSL_CTX_set_verify :: proc(ctx: SSL_CTX, mode: c.int, callback: rawptr) ---
	SSL_CTX_set_default_verify_paths :: proc(ctx: SSL_CTX) -> c.int ---
	SSL_CTX_load_verify_locations :: proc(ctx: SSL_CTX, ca_file: cstring, ca_path: cstring) -> c.int ---
	SSL_new :: proc(ctx: SSL_CTX) -> SSL ---
	SSL_free :: proc(ssl: SSL) ---
	SSL_set_fd :: proc(ssl: SSL, fd: c.int) -> c.int ---
	SSL_get_rbio :: proc(ssl: SSL) -> BIO ---
	BIO_new_mem_buf :: proc(buf: rawptr, len: c.int) -> BIO ---
	BIO_free :: proc(b: BIO) -> c.int ---
	BIO_ctrl :: proc(b: BIO, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	PEM_read_bio :: proc(b: BIO, name, header: ^cstring, data: ^^u8, len: ^c.long) -> c.int ---
	PEM_read_bio_X509_AUX :: proc(b: BIO, cert: ^X509, cb: PemPasswordCb, arg: rawptr) -> X509 ---
	PEM_read_bio_PrivateKey :: proc(b: BIO, key: ^EVP_PKEY, cb: PemPasswordCb, arg: rawptr) -> EVP_PKEY ---
	EVP_PKEY_free :: proc(key: EVP_PKEY) ---
	EVP_PKEY_CTX_new :: proc(key: EVP_PKEY, engine: rawptr) -> EVP_PKEY_CTX ---
	EVP_PKEY_CTX_free :: proc(ctx: EVP_PKEY_CTX) ---
	EVP_PKEY_pairwise_check :: proc(ctx: EVP_PKEY_CTX) -> c.int ---
	SSL_accept :: proc(ssl: SSL) -> c.int ---
	SSL_connect :: proc(ssl: SSL) -> c.int ---
	SSL_read :: proc(ssl: SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_write :: proc(ssl: SSL, buf: rawptr, num: c.int) -> c.int ---
	SSL_set_info_callback :: proc(ssl: SSL, cb: SslInfoCb) ---
	SSL_set_quiet_shutdown :: proc(ssl: SSL, mode: c.int) ---
	SSL_get_error :: proc(ssl: SSL, ret_code: c.int) -> c.int ---
	SSL_ctrl :: proc(ssl: SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_set1_host :: proc(ssl: SSL, hostname: cstring) -> c.int ---
	SSL_get0_param :: proc(ssl: SSL) -> rawptr ---
	X509_VERIFY_PARAM_set1_ip_asc :: proc(param: rawptr, ip: cstring) -> c.int ---
	SSL_get_verify_result :: proc(ssl: SSL) -> c.long ---
	SSL_get_servername :: proc(ssl: SSL, type: c.int) -> cstring ---
	SSL_CTX_set_alpn_select_cb :: proc(ctx: SSL_CTX, cb: AlpnSelectCb, arg: rawptr) ---
	SSL_set_alpn_protos :: proc(ssl: SSL, protos: [^]u8, protos_len: c.uint) -> c.int ---
	ERR_clear_error :: proc() ---
	SSL_CTX_get_cert_store :: proc(ctx: SSL_CTX) -> X509_STORE ---
	X509_STORE_new :: proc() -> X509_STORE ---
	X509_STORE_free :: proc(store: X509_STORE) ---
	X509_STORE_add_cert :: proc(ctx: X509_STORE, x: X509) -> c.int ---
	X509_STORE_set_flags :: proc(store: X509_STORE, flags: c.ulong) -> c.int ---
	X509_STORE_CTX_new :: proc() -> X509_STORE_CTX ---
	X509_STORE_CTX_free :: proc(ctx: X509_STORE_CTX) ---
	X509_STORE_CTX_init :: proc(ctx: X509_STORE_CTX, store: X509_STORE, leaf: X509, chain: X509_STACK) -> c.int ---
	X509_STORE_CTX_set_purpose :: proc(ctx: X509_STORE_CTX, purpose: c.int) -> c.int ---
	X509_STORE_CTX_get0_chain :: proc(ctx: X509_STORE_CTX) -> X509_STACK ---
	X509_verify_cert :: proc(ctx: X509_STORE_CTX) -> c.int ---
	X509_check_ca :: proc(cert: X509) -> c.int ---
	X509_check_purpose :: proc(cert: X509, purpose, ca: c.int) -> c.int ---
	X509_get0_notBefore :: proc(cert: X509) -> ASN1_TIME ---
	X509_get0_notAfter :: proc(cert: X509) -> ASN1_TIME ---
	X509_cmp_current_time :: proc(value: ASN1_TIME) -> c.int ---
	ASN1_TIME_compare :: proc(a, b: ASN1_TIME) -> c.int ---
	X509_get0_signature :: proc(signature: ^rawptr, algorithm: ^X509_ALGOR, cert: X509) ---
	X509_get0_tbs_sigalg :: proc(cert: X509) -> X509_ALGOR ---
	X509_ALGOR_cmp :: proc(a, b: X509_ALGOR) -> c.int ---
	X509_cmp :: proc(a, b: X509) -> c.int ---
	OPENSSL_sk_num :: proc(stack: X509_STACK) -> c.int ---
	OPENSSL_sk_value :: proc(stack: X509_STACK, index: c.int) -> X509 ---
	d2i_X509 :: proc(a: ^X509, pp: ^^u8, length: c.long) -> X509 ---
	d2i_X509_AUX :: proc(a: ^X509, pp: ^^u8, length: c.long) -> X509 ---
	X509_free :: proc(a: X509) ---
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
