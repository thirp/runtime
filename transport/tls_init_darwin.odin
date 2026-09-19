package transport

import "core:c"
import "core:sys/posix"

openssl_once_init :: proc() {
	_ = OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, nil)
	_ = posix.sigignore(.SIGPIPE)
}
