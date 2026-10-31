package caller

import proto "../protocol"
import trans "../transport"
import "core:bytes"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Blocks the first write on a connection until the test releases it, so
// later jobs sit in the queue. Later writes pass straight through.
QHold :: struct {
	mu:      sync.Mutex,
	cond:    sync.Cond,
	entered: bool,
	release: bool,
}

@(private)
qhold_mu: sync.Mutex

@(private)
qholds: map[^trans.Connection]^QHold

qhold_hook :: proc(conn: ^trans.Connection) {
	sync.mutex_lock(&qhold_mu)
	g := qholds[conn]
	sync.mutex_unlock(&qhold_mu)
	if g == nil {
		return
	}
	sync.mutex_lock(&g.mu)
	defer sync.mutex_unlock(&g.mu)
	if g.release {
		return
	}
	g.entered = true
	sync.cond_broadcast(&g.cond)
	for !g.release {
		sync.cond_wait(&g.cond, &g.mu)
	}
}

QWrite :: struct {
	conn:    ^trans.Connection,
	payload: []u8,
	ok:      bool,
}

qwrite_proc :: proc(w: ^QWrite) {
	w.ok = caller_write(w.conn, .Data, w.payload, 7)
}

bytes_of :: proc(s: string) -> []u8 {
	return ([^]u8)(raw_data(s))[:len(s)]
}

// Jobs queued for socket A must not be written after that generation is
// gone, even when the next session is the same address.
@(test)
test_queued_write_does_not_follow_reused_socket :: proc(t: ^testing.T) {
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	if lerr != .None {
		return
	}
	defer trans.listener_close(&ln)
	ep, eerr := trans.listener_endpoint(ln)
	testing.expect_value(t, eerr, trans.TransportError.None)
	if eerr != .None {
		return
	}
	client, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	if derr != .None {
		return
	}
	server, aerr := trans.listener_accept(&ln)
	testing.expect_value(t, aerr, trans.TransportError.None)
	defer trans.connection_destroy(client)
	defer trans.connection_destroy(server)
	if aerr != .None || server == nil {
		return
	}

	c: Caller
	c.conn = client
	c.conn_gen = 4
	c.streams = make(map[proto.StreamId]^Conn)
	defer delete(c.streams)
	caller_bind_session(&c, client)
	defer caller_unbind_session(client)
	defer caller_delete_queues(&c)

	hold: QHold
	sync.mutex_lock(&qhold_mu)
	if qholds == nil {
		qholds = make(map[^trans.Connection]^QHold)
	}
	qholds[client] = &hold
	sync.mutex_unlock(&qhold_mu)

	ta, tb, tc: ^thread.Thread
	defer {
		sync.mutex_lock(&hold.mu)
		hold.release = true
		sync.cond_broadcast(&hold.cond)
		sync.mutex_unlock(&hold.mu)
		if ta != nil {
			thread.join(ta)
			thread.destroy(ta)
		}
		if tb != nil {
			thread.join(tb)
			thread.destroy(tb)
		}
		if tc != nil {
			thread.join(tc)
			thread.destroy(tc)
		}
		sync.mutex_lock(&qhold_mu)
		if qholds != nil {
			delete_key(&qholds, client)
			if len(qholds) == 0 {
				delete(qholds)
				qholds = nil
			}
		}
		sync.mutex_unlock(&qhold_mu)
	}
	sync.atomic_store(&client.write_hook, rawptr(qhold_hook))

	mark_a := "QUEUE-A-MAY-APPEAR"
	mark_b := "QUEUE-B-MUST-NOT"
	mark_c := "QUEUE-C-MUST-NOT"
	fa := QWrite{conn = client, payload = bytes_of(mark_a)}
	fb := QWrite{conn = client, payload = bytes_of(mark_b)}
	fc := QWrite{conn = client, payload = bytes_of(mark_c)}
	ta = thread.create_and_start_with_poly_data(&fa, qwrite_proc)
	testing.expect(t, ta != nil, "writer")
	if ta == nil {
		return
	}
	sync.mutex_lock(&hold.mu)
	for !hold.entered {
		sync.cond_wait(&hold.cond, &hold.mu)
	}
	sync.mutex_unlock(&hold.mu)

	tb = thread.create_and_start_with_poly_data(&fb, qwrite_proc)
	tc = thread.create_and_start_with_poly_data(&fc, qwrite_proc)
	testing.expect(t, tb != nil && tc != nil, "queued writers")
	if tb == nil || tc == nil {
		return
	}
	sync.mutex_lock(&c.write_mu)
	for len(c.data_q) < 2 {
		sync.cond_wait(&c.write_cond, &c.write_mu)
	}
	sync.mutex_unlock(&c.write_mu)

	// Same address, next generation. B is A reused.
	sync.mutex_lock(&c.mutex)
	c.conn_gen += 1
	sync.mutex_unlock(&c.mutex)

	sync.mutex_lock(&hold.mu)
	hold.release = true
	sync.cond_broadcast(&hold.cond)
	sync.mutex_unlock(&hold.mu)
	thread.join(ta)
	thread.destroy(ta)
	ta = nil
	thread.join(tb)
	thread.destroy(tb)
	tb = nil
	thread.join(tc)
	thread.destroy(tc)
	tc = nil

	_ = trans.connection_set_recv_timeout(server, 50 * time.Millisecond)
	got := make([dynamic]u8)
	defer delete(got)
	buf: [512]u8
	for {
		n, err := trans.connection_read(server, buf[:])
		if n > 0 {
			append(&got, ..buf[:n])
		}
		if err != .None {
			break
		}
	}
	testing.expect(t, fa.ok, "in-flight write")
	testing.expect(t, !fb.ok, "queued write survived a new generation")
	testing.expect(t, !fc.ok, "queued write survived a new generation")
	testing.expect(t, bytes.contains(got[:], bytes_of(mark_a)), "in-flight payload")
	testing.expect(t, !bytes.contains(got[:], bytes_of(mark_b)), "socket B got A's queued payload")
	testing.expect(t, !bytes.contains(got[:], bytes_of(mark_c)), "socket B got A's queued payload")
}
