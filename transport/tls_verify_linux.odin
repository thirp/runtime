package transport

import "core:c"

tls_client_context_load_system_ca :: proc(ctx: SSL_CTX) -> bool {
	return SSL_CTX_set_default_verify_paths(ctx) == 1
}
