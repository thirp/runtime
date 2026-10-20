package transport

import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Regression tests for the close/IO fd-reuse race (RACE-1020). A thread
// passes the closed check and picks the socket; another thread closes the
// connection; a new socket reuses the number; the first thread then does its
// send/recv. Before the fix the bytes crossed into the unrelated connection.
// The seams (write_hook/read_hook) hold that window open deterministically.

@(private = "file")
Race_Gate :: struct {
	in_window: sync.Sema,
	proceed:   sync.Sema,
}

@(private = "file")
write_gate: Race_Gate

@(private = "file")
read_gate: Race_Gate

@(private = "file")
race_write_hook :: proc(conn: ^Connection) {
	sync.atomic_store(&conn.write_hook, nil) // fire once
	sync.sema_post(&write_gate.in_window)
	sync.sema_wait(&write_gate.proceed)
}

@(private = "file")
race_read_hook :: proc(conn: ^Connection) {
	sync.atomic_store(&conn.read_hook, nil)
	sync.sema_post(&read_gate.in_window)
	sync.sema_wait(&read_gate.proceed)
}

@(private = "file")
Race_Pair :: struct {
	client: ^Connection,
	server: ^Connection,
}

@(private = "file")
RACE_FILL :: u8(0xC7)

@(private = "file")
RACE_BYSTANDERS :: 16

// While the other thread is still inside its IO, the fd number must still
// name the victim's own socket. Before the fix close released it at once, so
// it is either invalid or (reused) some other socket.
@(private = "file")
fd_still_victim :: proc(fd: i64, victim_local: net.Endpoint) -> bool {
	ep, err := net.bound_endpoint(net.TCP_Socket(fd))
	return err == .None && ep == victim_local
}

// Open bystander pairs until one end lands on fd (or the limit). Returns
// whether the number was reused while the original IO was still in flight.
@(private = "file")
open_bystanders :: proc(
	t: ^testing.T,
	ln: ^Listener,
	ep: net.Endpoint,
	fd: i64,
	pairs: ^[dynamic]Race_Pair,
) -> (
	reused: bool,
) {
	for _ in 0 ..< RACE_BYSTANDERS {
		c, derr := connection_dial(ep)
		if derr != .None {
			testing.fail_now(t, "bystander dial failed")
		}
		s, aerr := listener_accept(ln)
		if aerr != .None {
			connection_destroy(c)
			testing.fail_now(t, "bystander accept failed")
		}
		append(pairs, Race_Pair{c, s})
		if i64(c.socket) == fd || i64(s.socket) == fd {
			return true
		}
	}
	return false
}

@(private = "file")
Write_Arg :: struct {
	conn: ^Connection,
	err:  TransportError,
}

@(test)
test_close_during_write_never_reaches_reused_fd :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	ep, _ := listener_endpoint(ln)

	victim, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	victim_peer, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(victim_peer)
	old_fd := i64(victim.socket)
	victim_local, _ := net.bound_endpoint(victim.socket)

	sync.atomic_store(&victim.write_hook, rawptr(race_write_hook))
	arg := Write_Arg{conn = victim}
	writer := thread.create_and_start_with_poly_data(&arg, proc(a: ^Write_Arg) {
		payload: [256]u8
		for &b in payload {
			b = RACE_FILL
		}
		a.err = connection_write(a.conn, payload[:])
	})

	if !sync.sema_wait_with_timeout(&write_gate.in_window, 5 * time.Second) {
		testing.fail_now(t, "writer never reached the write window")
	}
	// The writer has passed its closed check and chosen its socket.
	connection_close(victim)
	pairs: [dynamic]Race_Pair
	defer {
		for p in pairs {
			connection_destroy(p.client)
			connection_destroy(p.server)
		}
		delete(pairs)
	}
	reused := open_bystanders(t, &ln, ep, old_fd, &pairs)
	held := fd_still_victim(old_fd, victim_local)
	sync.sema_post(&write_gate.proceed)
	thread.join(writer)
	thread.destroy(writer)
	connection_destroy(victim)

	testing.expectf(t, held, "fd %d was released while a write on it was in flight", old_fd)
	testing.expectf(t, !reused, "fd %d was reused while a write on it was in flight", old_fd)
	testing.expect(t, arg.err != .None, "write after close reported success")
	stray := 0
	buf: [512]u8
	for p in pairs {
		for end in ([2]^Connection{p.client, p.server}) {
			_ = connection_set_recv_timeout(end, 20 * time.Millisecond)
			n, _ := connection_read(end, buf[:])
			stray += n
		}
	}
	testing.expectf(t, stray == 0, "%d bytes of the closed connection's write reached a bystander", stray)
}

@(private = "file")
Read_Arg :: struct {
	conn: ^Connection,
	n:    int,
	err:  TransportError,
	buf:  [64]u8,
}

@(test)
test_close_during_read_never_reads_reused_fd :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	ep, _ := listener_endpoint(ln)

	victim, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	victim_peer, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(victim_peer)
	old_fd := i64(victim.socket)
	victim_local, _ := net.bound_endpoint(victim.socket)
	_ = connection_set_recv_timeout(victim, 2 * time.Second)

	sync.atomic_store(&victim.read_hook, rawptr(race_read_hook))
	arg := Read_Arg{conn = victim}
	reader := thread.create_and_start_with_poly_data(&arg, proc(a: ^Read_Arg) {
		a.n, a.err = connection_read(a.conn, a.buf[:])
	})

	if !sync.sema_wait_with_timeout(&read_gate.in_window, 5 * time.Second) {
		testing.fail_now(t, "reader never reached the read window")
	}
	connection_close(victim)
	pairs: [dynamic]Race_Pair
	defer {
		for p in pairs {
			connection_destroy(p.client)
			connection_destroy(p.server)
		}
		delete(pairs)
	}
	reused := open_bystanders(t, &ln, ep, old_fd, &pairs)
	held := fd_still_victim(old_fd, victim_local)
	// Every bystander peer sends a byte toward each end before the reader runs.
	one := []u8{RACE_FILL}
	for p in pairs {
		_ = connection_write(p.client, one)
		_ = connection_write(p.server, one)
	}
	sync.sema_post(&read_gate.proceed)
	thread.join(reader)
	thread.destroy(reader)
	connection_destroy(victim)

	testing.expectf(t, held, "fd %d was released while a read on it was in flight", old_fd)
	testing.expectf(t, !reused, "fd %d was reused while a read on it was in flight", old_fd)
	testing.expectf(t, arg.n == 0, "closed connection read %d bytes from another connection", arg.n)
}

@(private = "file")
destroy_gate: Race_Gate

@(private = "file")
destroy_read_hook :: proc(conn: ^Connection) {
	sync.atomic_store(&conn.read_hook, nil)
	sync.sema_post(&destroy_gate.in_window)
	sync.sema_wait(&destroy_gate.proceed)
}

// The owner destroys (drops the last reference) while another thread is
// inside a read. The Connection must stay allocated until that read leaves:
// the reader then still touches it (io_inflight, fd release). Before the
// in-flight reference this freed it under the reader (Windows page heap: AV
// in conn_io_exit; full suite crashed 7 of 12 runs).
@(test)
test_destroy_during_read_keeps_connection_alive :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	ep, _ := listener_endpoint(ln)

	victim, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	victim_peer, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	defer connection_destroy(victim_peer)
	_ = connection_set_recv_timeout(victim, 2 * time.Second)

	sync.atomic_store(&victim.read_hook, rawptr(destroy_read_hook))
	arg := Read_Arg{conn = victim}
	reader := thread.create_and_start_with_poly_data(&arg, proc(a: ^Read_Arg) {
		a.n, a.err = connection_read(a.conn, a.buf[:])
	})
	if !sync.sema_wait_with_timeout(&destroy_gate.in_window, 5 * time.Second) {
		testing.fail_now(t, "reader never reached the read window")
	}
	connection_destroy(victim) // owner's reference; the reader holds the other
	refs := sync.atomic_load(&victim.refs)
	released := sync.atomic_load(&victim.fd_released)
	sync.sema_post(&destroy_gate.proceed)
	thread.join(reader)
	thread.destroy(reader)

	testing.expectf(t, refs == 1, "after destroy with a read in flight refs = %d, want 1 (the reader's)", refs)
	testing.expect(t, !released, "fd released while a read was in flight")
	testing.expect_value(t, arg.n, 0)
}
