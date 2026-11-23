package caller

import ag "../agent"
import brk "../broker"
import proto "../protocol"
import trans "../transport"
import "base:runtime"
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
	stream_id: proto.StreamId,
	ok:      bool,
}

qwrite_proc :: proc(w: ^QWrite) {
	w.ok = caller_write(w.conn, .Data, w.payload, w.stream_id)
}

bytes_of :: proc(s: string) -> []u8 {
	return ([^]u8)(raw_data(s))[:len(s)]
}

@(test)
test_caller_reads_through_blocked_control_writes :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	endpoint := broker_endpoint(t, &fx)
	if endpoint.port == 0 {
		return
	}
	echo: EchoFixture
	origin := start_echo(t, &echo)
	defer stop_echo(&echo)
	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin, &agent, &run)
	defer stop_agent(&agent, th)
	if th == nil {
		return
	}
	c: Caller
	deadline :: time.Second
	config := CallerConfig{broker = endpoint, token = TEST_TOKEN_CALLER, insecure = true, dial_timeout = 2 * time.Second}
	when ODIN_TEST {
		config.read_idle_timeout = deadline
		config.ping_interval = 75 * time.Millisecond
	}
	if !testing.expect_value(t, caller_init(&c, config), CallerError.None) {
		return
	}
	defer caller_destroy(&c)
	stream, err := dial(&c, must_service(t, TEST_SERVICE))
	if !testing.expect_value(t, err, CallerError.None) {
		return
	}
	defer conn_destroy(stream)
	stream_id := stream.stream_id
	relay, found := brk.relay_lookup_stream(&fx.server, stream_id)
	if !testing.expect(t, found, "broker stream missing") {
		return
	}
	box := brk.server_lookup_outbox(&fx.server, relay.caller_conn)
	if !testing.expect(t, box != nil, "caller outbox missing") {
		return
	}
	defer brk.outbox_release(box)
	sync.mutex_lock(&c.mutex)
	socket := c.conn
	gen := c.conn_gen
	held := trans.connection_acquire(socket)
	sync.mutex_unlock(&c.mutex)
	if !testing.expect(t, held, "caller session missing") {
		return
	}
	defer trans.connection_release(socket)
	hold: QHold
	sync.mutex_lock(&qhold_mu)
	if qholds == nil {
		qholds = make(map[^trans.Connection]^QHold, runtime.heap_allocator())
	}
	qholds[socket] = &hold
	sync.mutex_unlock(&qhold_mu)
	sync.atomic_store(&socket.write_hook, rawptr(qhold_hook))
	w := QWrite{conn = socket, stream_id = stream_id, payload = []u8{'w'}}
	writer := thread.create_and_start_with_poly_data(&w, qwrite_proc)
	defer {
		sync.mutex_lock(&hold.mu)
		hold.release = true
		sync.cond_broadcast(&hold.cond)
		sync.mutex_unlock(&hold.mu)
		if writer != nil {
			thread.join(writer)
			thread.destroy(writer)
		}
		caller_wait_conn_write(&c, socket)
		sync.atomic_store(&socket.write_hook, nil)
		sync.mutex_lock(&qhold_mu)
		delete_key(&qholds, socket)
		if len(qholds) == 0 {
			delete(qholds)
			qholds = nil
		}
		sync.mutex_unlock(&qhold_mu)
	}
	if !testing.expect(t, writer != nil, "could not start DATA writer") {
		return
	}
	started := time.tick_now()
	queued_ping := false
	for time.tick_since(started) < 500 * time.Millisecond {
		sync.mutex_lock(&hold.mu)
		data_blocked := hold.entered
		sync.mutex_unlock(&hold.mu)
		sync.mutex_lock(&c.write_mu)
		for job in c.control_q {
			queued_ping = queued_ping || (data_blocked && job.opcode == .Ping)
		}
		sync.mutex_unlock(&c.write_mu)
		if queued_ping {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !testing.expect(t, queued_ping, "caller did not queue a Ping behind the held DATA") {
		return
	}
	ping, _ := proto.encode_ping({nonce = 42})
	defer delete(ping)
	if !testing.expect_value(t, brk.outbox_enqueue(box, .Ping, proto.CONNECTION_STREAM_ID, ping), brk.OutboxEnqueueError.None) {
		return
	}
	// DATA must still be delivered after the broker Ping, while both
	// the caller's Ping and Pong wait behind the original DATA write.
	started = time.tick_now()
	for time.tick_since(started) <= deadline + 100 * time.Millisecond {
		if !testing.expect_value(t, brk.outbox_enqueue(box, .Data, stream_id, []u8{'r'}), brk.OutboxEnqueueError.None) {
			return
		}
		until := time.tick_add(time.tick_now(), 350 * time.Millisecond)
		sync.mutex_lock(&stream.mutex)
		for len(stream.inbound) == 0 && !stream.closed && !stream.reset {
			left := time.tick_diff(time.tick_now(), until)
			if left <= 0 {
				break
			}
			_ = sync.cond_wait_with_timeout(&stream.cond, &stream.mutex, left)
		}
		received := len(stream.inbound) == 1 && stream.inbound[0] == 'r'
		clear(&stream.inbound)
		sync.mutex_unlock(&stream.mutex)
		if !testing.expect(t, received, "reader stopped consuming frames behind a blocked writer") {
			return
		}
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, caller_is_connected(&c) && caller_conn_gen(&c) == gen, "watchdog replaced a live caller session")
	sync.mutex_lock(&c.write_mu)
	queued_pong := false
	for job in c.control_q {
		queued_pong = queued_pong || job.opcode == .Pong
	}
	sync.mutex_unlock(&c.write_mu)
	testing.expect(t, queued_pong, "broker Ping did not queue a Pong")
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
		qholds = make(map[^trans.Connection]^QHold, runtime.heap_allocator())
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
	fa := QWrite{conn = client, payload = bytes_of(mark_a), stream_id = 7}
	fb := QWrite{conn = client, payload = bytes_of(mark_b), stream_id = 7}
	fc := QWrite{conn = client, payload = bytes_of(mark_c), stream_id = 7}
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
