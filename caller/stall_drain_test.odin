package caller

import ag "../agent"
import brk "../broker"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Upload on a retired stream into an agent that has stopped reading.
// The shared writer blocks on that drain socket. The stall timer must
// shut the drain down and leave the live session up, so a healthy
// service dials within its own timeout.
StallUp :: struct {
	conn: ^Conn,
	stop: bool,
	sent: int,
	err:  ConnError,
	done: bool,
}

stall_up_proc :: proc(u: ^StallUp) {
	chunk := make([]u8, 16 * 1024)
	defer delete(chunk)
	for !sync.atomic_load(&u.stop) {
		n, err := conn_write(u.conn, chunk)
		if err != .None {
			u.err = err
			break
		}
		sync.atomic_add(&u.sent, n)
	}
	sync.atomic_store(&u.done, true)
}

stall_echo :: proc(s: ^Conn, b: u8) -> bool {
	buf := [1]u8{b}
	n, werr := conn_write(s, buf[:])
	if werr != .None || n != 1 {
		return false
	}
	got: [1]u8
	rn, rerr := conn_read(s, got[:])
	return rerr == .None && rn == 1 && got[0] == b
}

@(test)
test_retired_drain_stall_does_not_drop_live_session :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: ag.Agent
	run: AgentRunArg
	ath := start_registered_agent(t, &fx, echo_ep, &agent, &run)
	defer stop_agent(&agent, ath)

	box := test_agent_outbox(&fx.server)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer brk.outbox_release(box)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 200 * time.Millisecond,
				send_stall_timeout = 3 * time.Second,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	s1, e1 := dial(&c, sid)
	testing.expect_value(t, e1, CallerError.None)
	if s1 == nil {
		return
	}
	up: StallUp
	uth: ^thread.Thread
	defer {
		brk.outbox_set_writer_hold(box, false)
		if uth != nil {
			sync.atomic_store(&up.stop, true)
			conn_close(s1)
			thread.join(uth)
			thread.destroy(uth)
		}
		conn_destroy(s1)
	}
	testing.expect(t, stall_echo(s1, 'a'), "stream did not echo before the hold")

	brk.outbox_set_writer_hold(box, true)
	miss, _ := dial(&c, sid)
	if miss != nil {
		conn_destroy(miss)
	}
	gen := caller_conn_gen(&c)
	armed := time.now()
	for caller_conn_gen(&c) == gen && time.since(armed) < 12 * time.Second {
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, caller_conn_gen(&c) != gen, "live stream did not retire")
	if caller_conn_gen(&c) == gen {
		return
	}
	for i := 0; i < 100; i += 1 {
		if caller_is_connected(&c) {
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, caller_is_connected(&c), "replacement session did not connect")

	echo2: EchoFixture
	echo2_ep := start_echo(t, &echo2)
	defer stop_echo(&echo2)
	agent2: ag.Agent
	run2: AgentRunArg
	ath2 := start_registered_agent(t, &fx, echo2_ep, &agent2, &run2, SVC_A)
	defer stop_agent(&agent2, ath2)
	sid2 := must_service(t, SVC_A)

	c.config.dial_timeout = 5 * time.Second
	pre, pe := dial(&c, sid2)
	testing.expect_value(t, pe, CallerError.None)
	if pre != nil {
		testing.expect(t, stall_echo(pre, 'p'), "control dial on the live session did not echo")
		conn_destroy(pre)
	}
	if pe != .None {
		return
	}

	up.conn = s1
	uth = thread.create_and_start_with_poly_data(&up, stall_up_proc)
	testing.expect(t, uth != nil, "upload thread")
	if uth == nil {
		return
	}
	last := -1
	for i := 0; i < 100; i += 1 {
		time.sleep(100 * time.Millisecond)
		n := sync.atomic_load(&up.sent)
		if n == last && n > 0 {
			break
		}
		last = n
	}
	testing.expect(t, sync.atomic_load(&up.sent) > 0, "retired upload never sent")

	// Above the 3s stall, under TCP_USER_TIMEOUT (20s). A stall that shuts
	// the live session leaves this dial blocked on the retired socket until
	// that abort, and moves conn_gen. Shutting the drain lets it finish.
	c.config.dial_timeout = 12 * time.Second
	gen_before := caller_conn_gen(&c)
	s2, e2 := dial(&c, sid2)
	echo_ok := false
	if s2 != nil {
		echo_ok = stall_echo(s2, 'h')
		conn_destroy(s2)
	}
	testing.expect(t, e2 == .None && echo_ok, "healthy dial failed while a drain write was blocked")
	testing.expect(t, caller_conn_gen(&c) == gen_before, "live session dropped while a drain write was blocked")
}
