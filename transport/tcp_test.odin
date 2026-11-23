package transport

import proto "../protocol"
import "core:mem"
import "core:net"
import "core:sync"
import "core:testing"
import "core:time"

when ODIN_TEST {
	@(test)
	test_keepalive_defers_when_readiness_poll_is_interrupted :: proc(t: ^testing.T) {
		conn := Connection{refs = 1, test_interrupt_poll = true}
		probe_budget := 50 * time.Millisecond
		delay, err := connection_write_if_idle(&conn, []u8{'p'}, 15 * time.Second, probe_budget)
		testing.expect_value(t, err, TransportError.WouldBlock)
		testing.expect_value(t, delay, time.Duration(0))
		testing.expect(t, !conn.closed && !conn.close_started, "interrupted probe closed the session")
		testing.expect(t, conn.last_write == {}, "interrupted probe recorded an outbound write")
		testing.expect_value(t, conn.io_inflight, 0)
		if testing.expect(t, sync.mutex_try_lock(&conn.write_mutex), "interrupted probe held the writer") {
			sync.mutex_unlock(&conn.write_mutex)
		}
		// An interruption during an ordinary TLS write must still be reported
		// as a failure since a partial frame may already be on the wire.
		conn.test_interrupt_poll = true
		testing.expect_value(t, tls_poll(&conn, true, probe_budget), TransportError.Network)
	}
}

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
	testing.expect_value(t, connection_close_cause(server), CloseCause.PeerEOF)
	testing.expect_value(t, connection_close_cause(client), CloseCause.LocalClose)
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
	for _ in 0 ..< 3 {
		n, rerr := connection_read(server, buf[:])
		testing.expect_value(t, rerr, TransportError.Timeout)
		testing.expect_value(t, n, 0)
	}
	testing.expect_value(t, connection_write(client, []u8{'p'}), TransportError.None)
	n, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.None)
	testing.expect_value(t, string(buf[:n]), "p")
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

// A peer FIN must stop a reader in one poll/read and must not mark the
// socket closed, so the reply can still be written. The same shape is what
// broker conn_run, agent_relay_loop, caller_read_session, and
// bridge_read_local do: Timeout is polled, any other error ends the loop,
// and connection_destroy frees the socket.
@(test)
test_peer_fin_on_idle_connection_does_not_spin_and_is_freed :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	client, derr := connection_dial(ep, alloc)
	testing.expect_value(t, derr, TransportError.None)
	server, aerr := listener_accept(&ln, alloc)
	testing.expect_value(t, aerr, TransportError.None)
	freed := false
	defer if !freed {
		connection_destroy(server)
		connection_destroy(client)
	}

	testing.expect_value(t, connection_shutdown_write(client), TransportError.None)

	buf: [8]u8
	polls := 0
	reads := 0
	stopped := false
	for {
		polls += 1
		if polls > 3 {
			break
		}
		werr := connection_wait_readable(server, 20 * time.Millisecond)
		if werr == .Timeout {
			continue
		}
		if werr == .None {
			reads += 1
			_, rerr := connection_read(server, buf[:])
			if rerr == .None {
				continue
			}
			testing.expect_value(t, rerr, TransportError.Closed)
			stopped = true
			break
		}
		testing.expect_value(t, werr, TransportError.Closed)
		stopped = true
		break
	}
	testing.expect(t, stopped, "idle FIN reader did not stop")
	testing.expect(t, polls == 1, "idle FIN poll spun")
	testing.expect(t, reads <= 1, "idle FIN read spun")
	testing.expect(t, !server.closed)
	testing.expect_value(t, connection_write(server, []u8{1}), TransportError.None)

	connection_destroy(server)
	connection_destroy(client)
	freed = true
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
