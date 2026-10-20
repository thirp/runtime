package caller

import ag "../agent"
import auth "../auth"
import brk "../broker"
import trans "../transport"
import "core:fmt"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Test-only self-signed PEMs (CN/SAN 127.0.0.1). Not for production.
CALLER_TEST_CERT :: string(#load("../transport/testdata/test_server.crt"))
CALLER_TEST_KEY :: string(#load("../transport/testdata/test_server.key"))

FLOOD_CHUNK :: 64 * 1024
STALL_TEST_TIMEOUT :: 2 * time.Second // bound on a request beside a stuck stream

// Upstream for the stall tests. First byte picks the mode:
//   'F' flood: write until the peer stops taking bytes, never read again.
//   'E' echo.
ModeUpstream :: struct {
	ln:   trans.Listener,
	th:   ^thread.Thread,
	live: int,
}

mode_upstream_start :: proc(t: ^testing.T, up: ^ModeUpstream, loc := #caller_location) -> net.Endpoint {
	lerr: trans.TransportError
	up.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	_ = trans.listener_set_recv_timeout(&up.ln, 50 * time.Millisecond)
	ep, _ := trans.listener_endpoint(up.ln)
	up.th = thread.create_and_start_with_poly_data(up, mode_upstream_accept)
	return ep
}

mode_upstream_stop :: proc(up: ^ModeUpstream) {
	trans.listener_close(&up.ln)
	if up.th != nil {
		thread.join(up.th)
		thread.destroy(up.th)
	}
	for sync.atomic_load(&up.live) != 0 {
		time.sleep(1 * time.Millisecond)
	}
}

ModeConnArg :: struct {
	up:   ^ModeUpstream,
	conn: ^trans.Connection,
}

mode_upstream_accept :: proc(up: ^ModeUpstream) {
	for {
		conn, err := trans.listener_accept(&up.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		_ = trans.connection_set_recv_timeout(conn, 0)
		_ = trans.connection_set_send_timeout(conn, 20 * time.Second)
		arg := new(ModeConnArg)
		arg.up = up
		arg.conn = conn
		sync.atomic_add(&up.live, 1)
		thread.run_with_poly_data(arg, mode_upstream_conn)
	}
}

mode_upstream_conn :: proc(arg: ^ModeConnArg) {
	up := arg.up
	conn := arg.conn
	free(arg)
	defer {
		trans.connection_destroy(conn)
		sync.atomic_sub(&up.live, 1)
	}
	first: [1]u8
	n, err := trans.connection_read(conn, first[:])
	if err != .None || n != 1 {
		return
	}
	switch first[0] {
	case 'F':
		chunk := make([]u8, FLOOD_CHUNK)
		defer delete(chunk)
		// Its own fill byte (not zeros), so flood bytes on another stream are
		// recognizable; the connect tests use 0xA1-0xBF and 0xF1.
		for i in 0 ..< len(chunk) {
			chunk[i] = 0xC1
		}
		for trans.connection_write(conn, chunk) == .None {
		}
	case 'E':
		buf: [4096]u8
		for {
			m, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				return
			}
			if trans.connection_write(conn, buf[:m]) != .None {
				return
			}
		}
	}
}

// Field (lab, 2026-10-19): one stuck request froze thirp-connect until a
// restart. Root cause: the one session reader blocked in conn_push_inbound
// while a stream's consumer was not draining, so no frame for any other
// stream (CONNECT_OK included) was handled. Base: dial B times out.
@(test)
test_caller_stalled_stream_does_not_block_other_streams :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	up: ModeUpstream
	up_ep := mode_upstream_start(t, &up)
	defer mode_upstream_stop(&up)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, up_ep, &agent, &run)
	defer stop_agent(&agent, th)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 15 * time.Second,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	sid := must_service(t, TEST_SERVICE)
	a, aerr := dial(&c, sid)
	testing.expect_value(t, aerr, CallerError.None)
	if aerr != .None {
		return
	}
	defer conn_destroy(a)
	_, werr := conn_write(a, []u8{'F'})
	testing.expect_value(t, werr, ConnError.None)
	// Never read a: its backlog reaches CONN_INBOUND_CAP and the stream is
	// reset at once; the reader never waits on it.
	time.sleep(300 * time.Millisecond)

	start := time.now()
	b, berr := dial(&c, sid)
	testing.expect_value(t, berr, CallerError.None)
	if berr != .None {
		return
	}
	defer conn_destroy(b)
	msg := "Ehello"
	_, bwerr := conn_write(b, transmute([]u8)msg)
	testing.expect_value(t, bwerr, ConnError.None)
	got := make([dynamic]u8)
	defer delete(got)
	buf: [64]u8
	for len(got) < len(msg) - 1 {
		n, rerr := conn_read(b, buf[:])
		if rerr != .None {
			break
		}
		append(&got, ..buf[:n])
	}
	testing.expect_value(t, string(got[:]), "hello")
	// Not held up by the stuck stream at all.
	testing.expect(t, time.since(start) < STALL_TEST_TIMEOUT)

	// The stuck stream was reset, not left half-alive.
	drain: [FLOOD_CHUNK]u8
	for {
		_, rerr := conn_read(a, drain[:])
		if rerr != .None {
			testing.expect_value(t, rerr, ConnError.Reset)
			break
		}
	}
}

caller_tls_temp_seq: int

caller_write_temp_pem :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&caller_tls_temp_seq, 1)
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if len(dir) == 0 {
		dir = os.get_env("TEMP", context.temp_allocator)
	}
	when ODIN_OS == .Windows {
		if len(dir) == 0 {
			dir = "C:\\Windows\\Temp"
		}
	} else {
		if len(dir) == 0 {
			dir = "/tmp"
		}
	}
	path = fmt.aprintf("%s%cthirp-caller-tls-%s-%d-%d.pem", dir, os.Path_Separator, label, os.get_pid(), n)
	if os.write_entire_file(path, transmute([]u8)contents) != nil {
		delete(path)
		return "", false
	}
	return path, true
}

// Field: thirp-connect SIGSEGV when --listen was busy (139 in ~1 of 5
// runs). caller_destroy freed conn.tls under the reader thread's SSL_read;
// the reader's mutex_unlock(&conn.tls.mutex) then dereferenced nil.
// Base: this crashes the test process within a few iterations.
@(test)
test_caller_destroy_tls_while_reader_polls :: proc(t: ^testing.T) {
	cert_path, cok := caller_write_temp_pem("cert", CALLER_TEST_CERT)
	testing.expect(t, cok)
	key_path, kok := caller_write_temp_pem("key", CALLER_TEST_KEY)
	testing.expect(t, kok)
	defer {
		_ = os.remove(cert_path)
		_ = os.remove(key_path)
		delete(cert_path)
		delete(key_path)
	}

	reg: brk.Registry
	store: auth.StaticTokenAuth
	server: brk.Server
	testing.expect_value(t, brk.registry_init(&reg), brk.RegistryError.None)
	testing.expect_value(t, auth.auth_init(&store), auth.AuthError.None)
	testing.expect_value(t, auth.auth_add_token(&store, TEST_TOKEN_CALLER, TEST_PRINCIPAL_CALLER), auth.AuthError.None)
	brk.server_init(&server, &reg, auth.static_token_authenticator(&store))
	brk.server_disable_test_hardening(&server)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
	ctx, cerr := trans.tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, cerr, trans.TransportError.None)
	server.tls_ctx = ctx
	testing.expect_value(t, brk.server_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	brk.server_start(&server)
	defer {
		brk.server_stop(&server)
		_ = brk.server_wait_idle(&server, 2 * time.Second)
		brk.server_destroy(&server)
		auth.auth_destroy(&store)
		brk.registry_destroy(&reg)
	}
	ep, _ := brk.server_endpoint(&server)

	for i in 0 ..< 100 {
		c: Caller
		err := caller_init(
			&c,
			CallerConfig {
				broker = ep,
				token = TEST_TOKEN_CALLER,
				tls_ca = cert_path,
				tls_server_name = "127.0.0.1",
			},
		)
		testing.expect_value(t, err, CallerError.None)
		if err != .None {
			return
		}
		// Vary where the reader is: just started, inside SSL_read, or in
		// its 50 ms poll.
		if i % 4 == 1 {
			thread.yield()
		} else if i % 4 == 2 {
			time.sleep(time.Duration(i % 7) * time.Millisecond)
		}
		caller_destroy(&c)
	}
}

// Fix 2, deterministic (Theo's review): hold the session reader inside
// tls_connection_read, between SSL_read and unlocking the TLS mutex, then
// destroy the caller. The release's caller_destroy called connection_close
// here, which freed conn.tls under the reader; the reader's unlock then
// dereferenced nil (SIGSEGV, thirp-connect exit with a busy listen port).
// Now caller_destroy only shuts the socket down to wake the reader, joins
// it, and frees TLS after.
destroy_hook_inside: sync.Sema
destroy_hook_fired: bool

destroy_hook :: proc(conn: ^trans.Connection) {
	if sync.atomic_exchange(&destroy_hook_fired, true) {
		return
	}
	sync.sema_post(&destroy_hook_inside)
	// caller_destroy runs on the test thread while we sit here.
	time.sleep(200 * time.Millisecond)
}

@(test)
test_caller_destroy_while_reader_inside_ssl_read :: proc(t: ^testing.T) {
	cert_path, cok := caller_write_temp_pem("cert", CALLER_TEST_CERT)
	testing.expect(t, cok)
	key_path, kok := caller_write_temp_pem("key", CALLER_TEST_KEY)
	testing.expect(t, kok)
	defer {
		_ = os.remove(cert_path)
		_ = os.remove(key_path)
		delete(cert_path)
		delete(key_path)
	}

	reg: brk.Registry
	store: auth.StaticTokenAuth
	server: brk.Server
	testing.expect_value(t, brk.registry_init(&reg), brk.RegistryError.None)
	testing.expect_value(t, auth.auth_init(&store), auth.AuthError.None)
	testing.expect_value(t, auth.auth_add_token(&store, TEST_TOKEN_CALLER, TEST_PRINCIPAL_CALLER), auth.AuthError.None)
	brk.server_init(&server, &reg, auth.static_token_authenticator(&store))
	brk.server_disable_test_hardening(&server)
	server.heartbeat_interval = 30 * time.Second
	server.session_timeout = 30 * time.Second
	ctx, cerr := trans.tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, cerr, trans.TransportError.None)
	server.tls_ctx = ctx
	testing.expect_value(t, brk.server_listen(&server, trans.loopback_endpoint(0)), trans.TransportError.None)
	brk.server_start(&server)
	defer {
		brk.server_stop(&server)
		_ = brk.server_wait_idle(&server, 2 * time.Second)
		brk.server_destroy(&server)
		auth.auth_destroy(&store)
		brk.registry_destroy(&reg)
	}
	ep, _ := brk.server_endpoint(&server)

	c: Caller
	err := caller_init(&c, CallerConfig{broker = ep, token = TEST_TOKEN_CALLER, tls_ca = cert_path, tls_server_name = "127.0.0.1"})
	testing.expect_value(t, err, CallerError.None)
	if err != .None {
		return
	}
	sync.atomic_store(&c.conn.tls_read_hook, rawptr(destroy_hook))
	// The reader polls every 50 ms, so it is inside SSL_read within that.
	inside := sync.sema_wait_with_timeout(&destroy_hook_inside, 2 * time.Second)
	testing.expect(t, inside, "reader never reached SSL_read")
	// With the old caller_destroy the reader faults in the TLS unlock and
	// the test runner then hangs; fail the run loudly instead.
	wd := Watchdog{limit = 10 * time.Second, what = "caller_destroy with the reader inside SSL_read"}
	wth := thread.create_and_start_with_poly_data(&wd, watchdog_proc)
	caller_destroy(&c)
	sync.atomic_store(&wd.done, true)
	thread.join(wth)
	thread.destroy(wth)
}

Watchdog :: struct {
	limit: time.Duration,
	what:  string,
	done:  bool, // atomic
}

watchdog_proc :: proc(w: ^Watchdog) {
	start := time.now()
	for !sync.atomic_load(&w.done) {
		if time.since(start) >= w.limit {
			fmt.eprintf("WATCHDOG: %s did not finish in %v; failing the run\n", w.what, w.limit)
			os.exit(1)
		}
		time.sleep(10 * time.Millisecond)
	}
}

// Theo round 2: caller_destroy finished streams but left them in the table.
// Owners then freed them (conn_close returns early once closed and never
// removes the entry) and the reader / post-join loop finished and released
// them again: 95-128 bad frees per run. Many live streams, owners reading,
// destroy underneath; the tracking allocator reports any double free.
DestroyOwner :: struct {
	stream: ^Conn,
}

destroy_owner_proc :: proc(o: ^DestroyOwner) {
	buf: [256]u8
	for {
		if _, err := conn_read(o.stream, buf[:]); err != .None {
			break
		}
	}
	conn_destroy(o.stream)
}

@(test)
test_caller_destroy_with_live_streams_no_double_free :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	up: ModeUpstream
	up_ep := mode_upstream_start(t, &up)
	defer mode_upstream_stop(&up)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, up_ep, &agent, &run)
	defer stop_agent(&agent, th)

	sid := must_service(t, TEST_SERVICE)
	for round in 0 ..< 10 {
		c: Caller
		err := caller_init(&c, CallerConfig{broker = broker_endpoint(t, &fx), token = TEST_TOKEN_CALLER, insecure = true, dial_timeout = 5 * time.Second})
		testing.expect_value(t, err, CallerError.None)
		if err != .None {
			return
		}
		owners: [8]DestroyOwner
		ths: [8]^thread.Thread
		n := 0
		for i in 0 ..< 8 {
			stream, derr := dial(&c, sid)
			if derr != .None {
				testing.expectf(t, false, "round %d dial %d: %v", round, i, derr)
				break
			}
			_, _ = conn_write(stream, []u8{'E', 'x'})
			owners[i] = DestroyOwner{stream = stream}
			ths[i] = thread.create_and_start_with_poly_data(&owners[i], destroy_owner_proc, init_context = context)
			n += 1
		}
		if round % 2 == 1 {
			time.sleep(time.Duration(round) * time.Millisecond)
		}
		caller_destroy(&c)
		for i in 0 ..< n {
			thread.join(ths[i])
			thread.destroy(ths[i])
		}
	}
}

// Trade-off (no per-stream flow control in protocol 1.0): a consumer that
// reads, but slower than the sender, is reset once its backlog would pass
// the per-stream buffer. The session reader never waits on it (round 3
// waited up to 30 s, which also stopped the broker reading the Agent).
// Another stream on the same Caller keeps answering.
@(test)
test_caller_slow_consumer_past_stream_cap_is_reset :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	up: ModeUpstream
	up_ep := mode_upstream_start(t, &up)
	defer mode_upstream_stop(&up)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, up_ep, &agent, &run)
	defer stop_agent(&agent, th)

	c: Caller
	testing.expect_value(
		t,
		caller_init(
			&c,
			CallerConfig {
				broker = broker_endpoint(t, &fx),
				token = TEST_TOKEN_CALLER,
				insecure = true,
				dial_timeout = 15 * time.Second,
				max_stream_buffer = 1024 * 1024,
			},
		),
		CallerError.None,
	)
	defer caller_destroy(&c)

	a, aerr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, aerr, CallerError.None)
	if aerr != .None {
		return
	}
	defer conn_destroy(a)
	_, werr := conn_write(a, []u8{'F'})
	testing.expect_value(t, werr, ConnError.None)
	// The flood passes the 1 MiB buffer within a few hundred ms while the
	// consumer reads ~640 KB/s: the stream is reset, not waited on.
	buf: [FLOOD_CHUNK]u8
	total := 0
	start := time.now()
	last := ConnError.None
	for time.since(start) < 10 * time.Second {
		n, rerr := conn_read(a, buf[:])
		if rerr != .None {
			last = rerr
			break
		}
		total += n
		time.sleep(100 * time.Millisecond)
	}
	testing.expect_value(t, last, ConnError.Reset)
	testing.expect(t, time.since(start) < 5 * time.Second)
	testing.expect(t, total > 0)

	// The session is unaffected: a new stream echoes at once.
	b_start := time.now()
	b, berr := dial(&c, must_service(t, TEST_SERVICE))
	testing.expect_value(t, berr, CallerError.None)
	if berr != .None {
		return
	}
	defer conn_destroy(b)
	msg := "Eafter"
	_, bwerr := conn_write(b, transmute([]u8)msg)
	testing.expect_value(t, bwerr, ConnError.None)
	got := make([dynamic]u8)
	defer delete(got)
	small: [64]u8
	for len(got) < len(msg) - 1 {
		n, rerr := conn_read(b, small[:])
		if rerr != .None {
			break
		}
		append(&got, ..small[:n])
	}
	testing.expect_value(t, string(got[:]), "after")
	testing.expect(t, time.since(b_start) < STALL_TEST_TIMEOUT)
}
