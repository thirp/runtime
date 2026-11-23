package broker

import trans "../transport"
import "core:sync"

// Reload the configured certificate chain and key on a TLS-enabled server.
// As with other server operations, callers must finish before server_destroy.
server_reload_tls :: proc(server: ^Server, cert_path, key_path: string) -> trans.TransportError {
	err := server_replace_tls_context(server, cert_path, key_path)
	if err != .None {
		server_log(server, .Error, LOG_EVENT_TLS_RELOAD_FAILED, {
			reason = "unable to load TLS certificate chain and key",
		})
		return err
	}
	server_log(server, .Info, LOG_EVENT_TLS_RELOADED)
	return .None
}

@(private)
server_replace_tls_context :: proc(server: ^Server, cert_path, key_path: string) -> trans.TransportError {
	// Only reloaders take this lock. Handshakes can start while the files
	// are being read and validated.
	sync.mutex_lock(&server.tls_reload_mutex)
	defer sync.mutex_unlock(&server.tls_reload_mutex)
	if server.tls_ctx == nil {
		return .Tls
	}
	replacement, err := trans.tls_server_context_init(cert_path, key_path, server.allocator, allow_key_prompt = false)
	if err != .None {
		return err
	}

	sync.mutex_lock(&server.tls_ctx_mutex)
	previous := server.tls_ctx
	server.tls_ctx = replacement
	sync.mutex_unlock(&server.tls_ctx_mutex)
	trans.tls_server_context_destroy(previous)
	return .None
}

@(private)
server_accept_tls :: proc(server: ^Server, conn: ^trans.Connection) -> trans.TransportError {
	sync.mutex_lock(&server.tls_ctx_mutex)
	tls_enabled := server.tls_ctx != nil
	ssl := trans.tls_server_session_new(server.tls_ctx)
	sync.mutex_unlock(&server.tls_ctx_mutex)
	if !tls_enabled {
		return .None
	}
	return trans.connection_tls_accept_session(conn, ssl)
}
