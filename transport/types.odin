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
	allocator:     mem.Allocator,
	remote:        net.Endpoint,
	tls:           ^TlsSession,
	recv_timeout:  time.Duration,
}

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
