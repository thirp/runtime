package transport

import proto "../protocol"
import "core:net"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_listen_dial_loopback_exchanges_bytes :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	testing.expect(t, client != nil)
	defer connection_destroy(client)

	server, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	testing.expect(t, server != nil)
	defer connection_destroy(server)

	msg := []u8{'p', 'i', 'n', 'g'}
	testing.expect_value(t, connection_write(client, msg), TransportError.None)

	buf: [16]u8
	n, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.None)
	testing.expect_value(t, n, len(msg))
	testing.expect_value(t, string(buf[:n]), "ping")
	testing.expect_value(t, server.remote.address, net.IP4_Loopback)
}

@(test)
test_connection_close_is_visible_to_peer :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	defer connection_destroy(client)

	server, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(server)

	connection_close(client)
	buf: [8]u8
	_, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.Closed)
}

@(test)
test_parse_endpoint_rejects_garbage :: proc(t: ^testing.T) {
	_, err := parse_endpoint("not-an-endpoint")
	testing.expect_value(t, err, TransportError.InvalidEndpoint)
	_, err = parse_endpoint("127.0.0.1:9000")
	testing.expect_value(t, err, TransportError.None)
	_, err = parse_endpoint("localhost:9000")
	testing.expect_value(t, err, TransportError.InvalidEndpoint)
}

@(test)
test_resolve_endpoint_accepts_ip_and_localhost :: proc(t: ^testing.T) {
	ep, err := resolve_endpoint("127.0.0.1:9000")
	testing.expect_value(t, err, TransportError.None)
	testing.expect_value(t, ep.port, 9000)
	testing.expect_value(t, ep.address, net.IP4_Address{127, 0, 0, 1})
	ep, err = resolve_endpoint("localhost:9000")
	testing.expect_value(t, err, TransportError.None)
	testing.expect_value(t, ep.port, 9000)
	host, hok := endpoint_host("broker.us-east-1.thirp.net:8443")
	testing.expect(t, hok)
	testing.expect_value(t, host, "broker.us-east-1.thirp.net")
	_, err = resolve_endpoint("https://broker.example:8443")
	testing.expect_value(t, err, TransportError.InvalidEndpoint)
	_, err = resolve_endpoint("not-an-endpoint")
	testing.expect_value(t, err, TransportError.InvalidEndpoint)
}

@(test)
test_set_recv_timeout_returns_timeout :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	defer connection_destroy(client)

	server, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(server)

	testing.expect_value(t, connection_set_recv_timeout(server, 20 * time.Millisecond), TransportError.None)
	buf: [8]u8
	_, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.Timeout)
}

@(test)
test_connection_peek_does_not_consume :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	defer connection_destroy(client)

	server, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(server)

	msg := []u8{'p', 'e', 'e', 'k'}
	testing.expect_value(t, connection_write(client, msg), TransportError.None)
	buf: [16]u8
	n, perr := connection_peek(server, buf[:])
	testing.expect_value(t, perr, TransportError.None)
	testing.expect_value(t, n, len(msg))
	testing.expect_value(t, string(buf[:n]), "peek")
	got, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.None)
	testing.expect_value(t, got, len(msg))
	testing.expect_value(t, string(buf[:got]), "peek")
}

@(test)
test_connection_refcount_acquire_keeps_alive_until_release :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)

	server, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(server)

	testing.expect_value(t, sync.atomic_load(&client.refs), 1)
	testing.expect(t, connection_acquire(client))
	testing.expect_value(t, sync.atomic_load(&client.refs), 2)
	connection_destroy(client)
	testing.expect_value(t, sync.atomic_load(&client.refs), 1)
	testing.expect(t, client.closed)
	connection_release(client)
}
