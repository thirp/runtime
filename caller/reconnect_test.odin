package caller

import ag "../agent"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_reconnect_backoff_doubles_until_cap :: proc(t: ^testing.T) {
	testing.expect_value(t, reconnect_backoff(0), 250 * time.Millisecond)
	testing.expect_value(t, reconnect_backoff(1), 500 * time.Millisecond)
	testing.expect_value(t, reconnect_backoff(2), 1 * time.Second)
	testing.expect_value(t, reconnect_backoff(3), 2 * time.Second)
	testing.expect_value(t, reconnect_backoff(4), 4 * time.Second)
	testing.expect_value(t, reconnect_backoff(5), 8 * time.Second)
	testing.expect_value(t, reconnect_backoff(6), 15 * time.Second)
	testing.expect_value(t, reconnect_backoff(7), 15 * time.Second)
	testing.expect_value(t, reconnect_backoff(20), 15 * time.Second)
}

@(test)
test_reconnect_delay_jitter_stays_in_range :: proc(t: ^testing.T) {
	base := reconnect_backoff(2)
	d0 := reconnect_delay(2, 0)
	d1 := reconnect_delay(2, 0xFFFFFFFFFFFFFFFF)
	testing.expect(t, d0 >= base / 2)
	testing.expect(t, d0 <= base)
	testing.expect(t, d1 >= base / 2)
	testing.expect(t, d1 <= base)
	testing.expect(t, d0 <= d1)
	testing.expect(t, reconnect_delay(6, 0) <= RECONNECT_MAX)
	testing.expect(t, reconnect_delay(6, 12345) <= RECONNECT_MAX)
}

@(test)
test_caller_init_rejects_unreadable_tls_ca :: proc(t: ^testing.T) {
	c: Caller
	err := caller_init(
		&c,
		CallerConfig {
			broker          = trans.loopback_endpoint(1),
			token           = TEST_TOKEN_CALLER,
			tls_ca          = "/no/such/thirp-ca-9f3a.pem",
			tls_server_name = "localhost",
		},
	)
	testing.expect_value(t, err, CallerError.InvalidConfig)
}

@(test)
test_caller_init_fails_when_broker_down :: proc(t: ^testing.T) {
	c: Caller
	err := caller_init(
		&c,
		CallerConfig{broker = trans.loopback_endpoint(1), token = TEST_TOKEN_CALLER, insecure = true},
	)
	testing.expect_value(t, err, CallerError.Transport)
}

@(test)
test_caller_reconnects_after_broker_session_loss :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, echo_ep, &agent, &run)
	defer stop_agent(&agent, th)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_CALLER, insecure = true},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	conn, derr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, derr, CallerError.None)
	testing.expect(t, conn != nil)

	_, werr := conn_write(conn, []u8{'h', 'i'})
	testing.expect_value(t, werr, ConnError.None)
	buf: [8]u8
	n, rerr := conn_read(conn, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:n]), "hi")

	close_caller_broker(&c)

	start := time.now()
	lost := false
	for time.since(start) < 2 * time.Second {
		_, rerr = conn_read(conn, buf[:])
		if rerr != .None {
			lost = true
			break
		}
	}
	testing.expect(t, lost)
	conn_destroy(conn)

	next, nerr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, nerr, CallerError.None)
	testing.expect(t, next != nil)
	defer conn_destroy(next)

	_, werr = conn_write(next, []u8{'o', 'k'})
	testing.expect_value(t, werr, ConnError.None)
	n, rerr = conn_read(next, buf[:])
	testing.expect_value(t, rerr, ConnError.None)
	testing.expect_value(t, string(buf[:n]), "ok")
}

@(test)
test_caller_two_dials_recover_after_session_loss :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, echo_ep, &agent, &run)
	defer stop_agent(&agent, th)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_CALLER, insecure = true},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	close_caller_broker(&c)
	wait_caller_disconnected(t, &c)

	a: DialEchoArg
	b: DialEchoArg
	a.caller = &c
	b.caller = &c
	a.service = must_service(t, TEST_SERVICE)
	b.service = must_service(t, TEST_SERVICE)
	a.payload = 'a'
	b.payload = 'b'
	tha := thread.create_and_start_with_poly_data(&a, dial_echo_proc)
	thb := thread.create_and_start_with_poly_data(&b, dial_echo_proc)
	thread.join(tha)
	thread.join(thb)
	thread.destroy(tha)
	thread.destroy(thb)

	testing.expect_value(t, a.err, CallerError.None)
	testing.expect_value(t, b.err, CallerError.None)
	testing.expect(t, a.echoed)
	testing.expect(t, b.echoed)
}

@(test)
test_caller_destroy_unblocks_dial_during_reconnect :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_CALLER, insecure = true},
		),
		CallerError.None,
	)

	close_caller_broker(&c)
	wait_caller_disconnected(t, &c)

	arg: DialWaitArg
	arg.caller = &c
	arg.service = must_service(t, TEST_SERVICE)
	th := thread.create_and_start_with_poly_data(&arg, dial_wait_proc)
	start := time.now()
	for time.since(start) < 200 * time.Millisecond {
		if sync.atomic_load(&arg.started) {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	caller_destroy(&c)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, arg.err, CallerError.Closed)
	testing.expect(t, arg.conn == nil)
}

DialWaitArg :: struct {
	caller:  ^Caller,
	service: proto.ServiceId,
	started: bool,
	conn:    ^Conn,
	err:     CallerError,
}

dial_wait_proc :: proc(arg: ^DialWaitArg) {
	sync.atomic_store(&arg.started, true)
	arg.conn, arg.err = dial(arg.caller, arg.service)
}

DialEchoArg :: struct {
	caller:  ^Caller,
	service: proto.ServiceId,
	payload: u8,
	err:     CallerError,
	echoed:  bool,
}

dial_echo_proc :: proc(arg: ^DialEchoArg) {
	conn, err := dial(arg.caller, arg.service)
	arg.err = err
	if err != .None || conn == nil {
		return
	}
	_, werr := conn_write(conn, []u8{arg.payload})
	buf: [8]u8
	n, rerr := conn_read(conn, buf[:])
	arg.echoed = werr == .None && rerr == .None && n == 1 && buf[0] == arg.payload
	conn_destroy(conn)
}

close_caller_broker :: proc(c: ^Caller) {
	sync.mutex_lock(&c.mutex)
	conn := c.conn
	sync.mutex_unlock(&c.mutex)
	if conn != nil {
		trans.connection_close(conn)
	}
}

wait_caller_disconnected :: proc(t: ^testing.T, c: ^Caller, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		sync.mutex_lock(&c.mutex)
		connected := c.connected
		sync.mutex_unlock(&c.mutex)
		if !connected {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, loc = loc)
}

when ODIN_TEST {
// Keep this case compatible with the 0.16.5 caller API so it can also be
// run against the tagged source, with the ByteProxy test helper copied over.
// FIN/RST alone do not reproduce this: the old socket must stay open and silent.
@(test)
test_reconnect_after_silent_peer :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	fx.server.session_timeout = 3 * time.Minute

	echo: EchoFixture
	ep := start_echo(t, &echo)
	defer stop_echo(&echo)
	agent: ag.Agent
	run: AgentRunArg
	ath := start_registered_agent(t, &fx, ep, &agent, &run)
	defer stop_agent(&agent, ath)

	proxy: ByteProxy
	byte_proxy_start(t, &proxy, broker_endpoint(t, &fx))
	defer byte_proxy_stop(&proxy)
	c: Caller
	err := caller_init(&c, CallerConfig {
		broker = proxy.ep,
		token = TEST_TOKEN_CALLER,
		insecure = true,
		dial_timeout = 5 * time.Second,
	})
	testing.expect_value(t, err, CallerError.None)
	if err != .None {
		return
	}
	defer caller_destroy(&c)
	sid := must_service(t, TEST_SERVICE)
	first, ferr := dial(&c, sid)
	testing.expect_value(t, ferr, CallerError.None)
	if first == nil {
		return
	}
	testing.expect(t, echo_one(first, 's'), "initial echo failed")
	conn_destroy(first)

	// Hold a reference so an allocator cannot reuse the old socket address.
	sync.mutex_lock(&c.mutex)
	old := c.conn
	trans.connection_acquire(old)
	sync.mutex_unlock(&c.mutex)
	defer trans.connection_release(old)
	byte_proxy_blackhole(&proxy)
	start := time.now()
	replaced := false
	for time.since(start) < 55 * time.Second {
		sync.mutex_lock(&c.mutex)
		replaced = c.connected && c.conn != nil && c.conn != old
		sync.mutex_unlock(&c.mutex)
		if replaced {
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, replaced, "silent peer never reconnected")
	if !replaced {
		return
	}
	again, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if again != nil {
		defer conn_destroy(again)
		testing.expect(t, echo_one(again, 'r'), "new stream after silent peer did not echo")
	}
}
}
