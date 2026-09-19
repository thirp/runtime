package transport

import "core:c"
import "core:strings"

tls_client_context_load_system_ca :: proc(ctx: SSL_CTX) -> bool {
	if SSL_CTX_set_default_verify_paths(ctx) != 1 {
		ca_c := cstring("/etc/ssl/cert.pem")
		if SSL_CTX_load_verify_locations(ctx, ca_c, nil) != 1 {
			return false
		}
	}
	return true
}
