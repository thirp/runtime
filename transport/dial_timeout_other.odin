#+build !linux
package transport

import "core:net"
import "core:time"


connection_dial_timeout :: proc(
	endpoint: net.Endpoint,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (
	^Connection,
	TransportError,
) {
	if timeout <= 0 {return connection_dial(endpoint, allocator)}
	if endpoint.port == 0 {return nil, .InvalidEndpoint}
	family: net.Address_Family
	switch _ in endpoint.address {
	case net.IP4_Address: family = .IP4
	case net.IP6_Address: family = .IP6
	case: return nil, .InvalidEndpoint
	}
	any_sock, serr := net.create_socket(family, .TCP)
	if serr != .None {return nil, .Network}
	sock := any_sock.(net.TCP_Socket)
	if net.set_blocking(sock, false) != nil {net.close(sock); return nil, .Network}
	err := dial_connect_other(sock, endpoint, timeout)
	if err != .None {net.close(sock); return nil, err}
	if net.set_blocking(sock, true) != nil {net.close(sock); return nil, .Network}
	_ = net.set_option(sock, .TCP_Nodelay, true)
	conn, aerr := connection_alloc(sock, allocator)
	if aerr != .None {net.close(sock); return nil, aerr}
	conn.remote = endpoint
	return conn, .None
}
