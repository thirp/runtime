package broker

import trans "../transport"
import "core:mem"
import "core:net"
import "core:testing"
import "core:time"

when ODIN_TEST {
	@(test)
	test_server_accept_success_after_stop_is_freed :: proc(t: ^testing.T) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)

		server: Server
		server_init(&server, nil, {}, mem.tracking_allocator(&track))
		// Inject a successful accept using the transport's real connection allocator.
		server.test_accept_data = t
		server.test_accept = proc(server: ^Server, data: rawptr) -> (^trans.Connection, trans.TransportError) {
			server.stop = true
			conn, err := trans.connection_alloc(0, server.allocator)
			testing.expect_value((^testing.T)(data), err, trans.TransportError.None)
			return conn, err
		}
		server_serve(&server)
		testing.expect(t, server.stop, "accept did not run")
		server_stop(&server)
		server_destroy(&server)

		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}

	@(test)
	test_server_stop_with_pending_accept_closes_sockets :: proc(t: ^testing.T) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		alloc := mem.tracking_allocator(&track)

		for _ in 0..<20 {
			server: Server
			server_init(&server, nil, {}, alloc)
			defer server_destroy(&server)
			defer if server.listening {
				server_stop(&server)
			}
			if !testing.expect_value(t, server_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None) {
				return
			}
			ep, endpoint_err := server_endpoint(&server)
			if !testing.expect_value(t, endpoint_err, trans.TransportError.None) {
				return
			}
			client, dial_err := trans.connection_dial(ep, alloc)
			if !testing.expect_value(t, dial_err, trans.TransportError.None) {
				return
			}
			defer trans.connection_destroy(client)
			if !testing.expect_value(t, trans.connection_set_recv_timeout(client, time.Second), trans.TransportError.None) {
				return
			}

			// Hold a real accept result until server_stop has closed the listener.
			// Running the serve loop directly lets the fixture stop it here without a join.
			listener_socket := server.listener.socket
			accepted_socket: net.TCP_Socket
			server.test_accept_data = &accepted_socket
			server.test_accept = proc(server: ^Server, data: rawptr) -> (^trans.Connection, trans.TransportError) {
				conn, err := trans.listener_accept(&server.listener, server.allocator)
				if err == .None {
					(^net.TCP_Socket)(data)^ = conn.socket
				}
				server_stop(server)
				return conn, err
			}
			server_serve(&server)
			if !testing.expect(t, accepted_socket != 0, "loopback accept did not succeed") {
				return
			}
			// Another test may reuse a numeric socket value. Check its address too.
			bound, socket_err := net.bound_endpoint(listener_socket)
			testing.expect(t, socket_err != .None || bound != ep, "listener socket remained open")
			bound, socket_err = net.bound_endpoint(accepted_socket)
			testing.expect(t, socket_err != .None || bound != ep, "accepted socket remained open")
			buf: [1]u8
			_, read_err := trans.connection_read(client, buf[:])
			if !testing.expect_value(t, read_err, trans.TransportError.Closed) {
				return
			}
		}

		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
}
