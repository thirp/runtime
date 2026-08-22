package web_ingress

import trans "../transport"
import "core:net"
import "core:testing"
import "core:time"

@(test)
test_acquire_release_slot_cleans_ip_map :: proc(t: ^testing.T) {
	server: IngressServer
	server.config.limits.max_connections = 2
	server.config.limits.max_connections_per_ip = 2
	server.ip_conns = make(map[IngressIpKey]int)
	defer delete(server.ip_conns)

	conn: trans.Connection
	conn.remote = net.Endpoint{address = net.IP4_Loopback, port = 1}
	testing.expect_value(t, ingress_acquire_connection_slot(&server, &conn), IngressSlotResult.Ok)
	testing.expect_value(t, server.slot_count, 1)
	key := ingress_ip_key_from_endpoint(conn.remote)
	testing.expect_value(t, server.ip_conns[key], 1)
	ingress_release_connection_slot(&server, key)
	testing.expect_value(t, server.slot_count, 0)
	_, exists := server.ip_conns[key]
	testing.expect(t, !exists)
}

@(test)
test_acquire_rejects_global_and_per_ip_limits :: proc(t: ^testing.T) {
	server: IngressServer
	server.config.limits.max_connections = 1
	server.config.limits.max_connections_per_ip = 1
	server.ip_conns = make(map[IngressIpKey]int)
	defer delete(server.ip_conns)

	a: trans.Connection
	a.remote = net.Endpoint{address = net.IP4_Loopback, port = 1}
	testing.expect_value(t, ingress_acquire_connection_slot(&server, &a), IngressSlotResult.Ok)
	b: trans.Connection
	b.remote = net.Endpoint{address = net.IP4_Loopback, port = 2}
	testing.expect_value(t, ingress_acquire_connection_slot(&server, &b), IngressSlotResult.Connections)

	ingress_release_connection_slot(&server, ingress_ip_key_from_endpoint(a.remote))
	server.config.limits.max_connections = 8
	testing.expect_value(t, ingress_acquire_connection_slot(&server, &a), IngressSlotResult.Ok)
	testing.expect_value(t, ingress_acquire_connection_slot(&server, &b), IngressSlotResult.ConnectionsPerIp)
}

@(test)
test_handshake_failure_releases_slot :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress(
		t,
		&server,
		&stub,
		cert_path,
		key_path,
		IngressLimits{max_connections = 1, max_connections_per_ip = 1, client_hello_timeout = 200 * time.Millisecond},
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	raw, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	testing.expect_value(t, trans.connection_write(raw, []u8{0x16, 0x03, 0x01, 0x00, 0x20}), trans.TransportError.None)
	time.sleep(400 * time.Millisecond)
	trans.connection_destroy(raw)

	start := time.now()
	for time.since(start) < 1 * time.Second {
		if server.slot_count == 0 && server.active_conns == 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, server.slot_count, 0)
	testing.expect_value(t, server.active_conns, 0)
	testing.expect_value(t, stub.calls, 0)
	testing.expect(t, server.metrics.limit_exceeds[.Connections] == 0)
}

@(test)
test_connection_flood_per_ip_does_not_dial :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	stub: StubDial
	server: IngressServer
	_ = start_stub_ingress(
		t,
		&server,
		&stub,
		cert_path,
		key_path,
		IngressLimits{max_connections = 8, max_connections_per_ip = 1, client_hello_timeout = 300 * time.Millisecond},
	)
	defer stop_stub_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	held, herr := trans.connection_dial(ep)
	testing.expect_value(t, herr, trans.TransportError.None)
	defer trans.connection_destroy(held)
	time.sleep(50 * time.Millisecond)

	second, serr := trans.connection_dial(ep)
	testing.expect_value(t, serr, trans.TransportError.None)
	defer trans.connection_destroy(second)
	_ = trans.connection_set_recv_timeout(second, 200 * time.Millisecond)
	buf: [16]u8
	_, rerr := trans.connection_read(second, buf[:])
	testing.expect(t, rerr == .Closed || rerr == .Timeout || rerr == .Tls)
	testing.expect_value(t, stub.calls, 0)
	testing.expect(t, server.metrics.limit_exceeds[.ConnectionsPerIp] >= 1)
}
