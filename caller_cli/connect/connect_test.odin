package connect

import ag "../../agent"
import auth "../../auth"
import brk "../../broker"
import cl "../../caller"
import log "../../logging"
import proto "../../protocol"
import trans "../../transport"
import "core:bytes"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

T_TOKEN_HOST :: "connect-host-test-token"
T_TOKEN_CALLER :: "connect-caller-test-token"
T_SERVICE :: "demo/connect"

// Same SAN as transport/testdata (IP:127.0.0.1). Test only.
CONNECT_TEST_CERT :: string(#load("../../transport/testdata/test_server.crt"))
CONNECT_TEST_KEY :: string(#load("../../transport/testdata/test_server.key"))

Fixture :: struct {
	reg:      brk.Registry,
	store:    auth.StaticTokenAuth,
	server:   brk.Server,
	up:       Upstream,
	agent:    ag.Agent,
	agent_th: ^thread.Thread,
	broker:   string,
	tls_cert: string,
	tls_key:  string,
}

// Upstream modes, picked by the first byte:
//   'E' echo
//   'P' early answer: read the request head, send a 403 and close without
//       reading the body (what an API does on a refused POST)
//   'H' read to EOF, then answer "got N" and close
//   'B' read to EOF, then write HALF_CLOSE_BODY bytes and half-close
//   'F' flood: write until the peer stops taking bytes, never read
//   'S' slow sink: "S<N>\n" then N bytes, read at SLOW_CHUNK per SLOW_TICK
//       (~320 KB/s, the field upload repro), then answer "got N"
//   'C' closes first: answer "bye", shut its write side, read to EOF, then
//       probe until the agent's socket is gone (counts closed_seen)
//   'W' read to EOF, then hold the socket with no reply until release is set
//       (or X_HOLD passes); counts waiting once it saw EOF
Upstream :: struct {
	ln:          trans.Listener,
	th:          ^thread.Thread,
	live:        int,
	stopped:     bool, // atomic: accept loop has returned
	closed_seen: int, // atomic
	waiting:     int, // atomic
	release:     bool, // atomic
	drop:        bool, // atomic: 'X' closes early
}

// Every bulk test writer fills its buffers with its own byte, so bytes that
// reach the wrong stream (or arrive as zeros) name their source in a failure.
// Echo payloads are ASCII; the fills are not, except FILL_EARLY.
FILL_HALF_CLOSE :: u8(0xA1) // half-close client body ('H')
FILL_HALF_CLOSE_BODY :: u8(0xA5) // full response after client half-close ('B')
HALF_CLOSE_BODY :: 32 * 1024
FILL_EARLY :: u8('a')       // early-answer client body ('P')
FILL_SLOW_UPLOAD :: u8(0xA3) // slow-upload client body ('S')
FILL_CAP_UPLOAD :: u8(0xA4)  // stream-cap upload body ('S')
FILL_NEVER_READ :: u8(0xB0)  // never-read uploads ('X'): 0xB0 + writer index
FILL_FLOOD :: u8(0xF1)       // upstream flood download ('F')

fill_source :: proc(b: u8) -> string {
	switch b {
	case 0:
		return "zeros (no test writer sends zeros)"
	case FILL_HALF_CLOSE:
		return "half-close client body"
	case FILL_HALF_CLOSE_BODY:
		return "half-close response body"
	case FILL_EARLY:
		return "early-answer client body"
	case FILL_SLOW_UPLOAD:
		return "slow-upload client body"
	case FILL_CAP_UPLOAD:
		return "stream-cap upload body"
	case FILL_FLOOD:
		return "upstream flood (paused/stuck download)"
	case FILL_NEVER_READ ..= FILL_NEVER_READ + 15:
		return "never-read upload body"
	}
	return "not a test fill byte"
}

fill_bytes :: proc(buf: []u8, b: u8) {
	for i in 0 ..< len(buf) {
		buf[i] = b
	}
}

SLOW_CHUNK :: 16 * 1024
// Field POST body. Sequential storms of this size are what stuck the caller
// bridge and the agent origin socket.
POST_BODY :: 46 * 1024
POST_STORM_N :: 2000
X_HOLD :: 12 * time.Second
SLOW_TICK :: 50 * time.Millisecond
// Upload size for the slow-sink replay. The default (8 MB, ~25 s) is past
// what loopback socket buffers absorb, so the release fails it; the field
// repro is -define:THIRP_REPLAY_UPLOAD_MB=50 (~160 s).
REPLAY_UPLOAD_MB :: #config(THIRP_REPLAY_UPLOAD_MB, 8)

RESPONSE_403 :: "HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\nConnection: close\r\n\r\nforbidden"

fixture_start :: proc(t: ^testing.T, fx: ^Fixture, agent_cfg: ag.AgentConfig = {}, use_tls := false) -> bool {
	testing.expect_value(t, brk.registry_init(&fx.reg), brk.RegistryError.None)
	testing.expect_value(t, auth.auth_init(&fx.store), auth.AuthError.None)
	testing.expect_value(t, auth.auth_add_token(&fx.store, T_TOKEN_HOST, "host-a"), auth.AuthError.None)
	testing.expect_value(t, auth.auth_add_token(&fx.store, T_TOKEN_CALLER, "client-a"), auth.AuthError.None)
	brk.server_init(&fx.server, &fx.reg, auth.static_token_authenticator(&fx.store))
	brk.server_disable_test_hardening(&fx.server)
	if use_tls && !fixture_enable_tls(t, fx) {
		brk.server_destroy(&fx.server)
		auth.auth_destroy(&fx.store)
		brk.registry_destroy(&fx.reg)
		if len(fx.tls_cert) > 0 {
			_ = os.remove(fx.tls_cert)
			delete(fx.tls_cert)
		}
		if len(fx.tls_key) > 0 {
			_ = os.remove(fx.tls_key)
			delete(fx.tls_key)
		}
		return false
	}
	// Heartbeat well inside the session timeout, as in production (15 s /
	// 45 s). Equal values let an idle caller session expire before its ping
	// went out, which the long slow-upload replay hits.
	fx.server.heartbeat_interval = 5 * time.Second
	fx.server.session_timeout = 30 * time.Second
	if brk.server_listen(&fx.server, trans.loopback_endpoint(0)) != .None {
		testing.expect(t, false, "broker listen")
		brk.server_destroy(&fx.server)
		auth.auth_destroy(&fx.store)
		brk.registry_destroy(&fx.reg)
		if len(fx.tls_cert) > 0 {
			_ = os.remove(fx.tls_cert)
			delete(fx.tls_cert)
		}
		if len(fx.tls_key) > 0 {
			_ = os.remove(fx.tls_key)
			delete(fx.tls_key)
		}
		return false
	}
	brk.server_start(&fx.server)
	bep, _ := brk.server_endpoint(&fx.server)
	fx.broker = strings.clone(net.endpoint_to_string(bep, context.temp_allocator))

	lerr: trans.TransportError
	fx.up.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	_ = trans.listener_set_recv_timeout(&fx.up.ln, 50 * time.Millisecond)
	// Small upstream receive buffers (inherited by accepted sockets) so the
	// slow-sink replay is not absorbed by loopback socket buffering. Not on
	// Windows: there an explicit small SO_RCVBUF on a loopback receiver lets
	// the sender's blocking send() take everything (300 MiB in 0.3 s in the
	// lab), so the agent queue never fills; the default buffers already hold
	// back after ~0.6 MiB.
	when ODIN_OS != .Windows {
		_ = net.set_option(fx.up.ln.socket, .Receive_Buffer_Size, 32 * 1024)
	}
	uep, _ := trans.listener_endpoint(fx.up.ln)
	fx.up.th = thread.create_and_start_with_poly_data(&fx.up, upstream_accept)

	sid, _ := proto.make_service_id(T_SERVICE)
	testing.expect_value(
		t,
		ag.agent_init(&fx.agent, fixture_agent_config(agent_cfg, bep, fx.tls_cert)),
		ag.AgentError.None,
	)
	testing.expect_value(t, ag.register_service(&fx.agent, sid, ag.LocalTarget{address = uep}), ag.AgentError.None)
	fx.agent_th = thread.create_and_start_with_poly_data(&fx.agent, agent_run)
	start := time.now()
	for !ag.agent_is_connected(&fx.agent) {
		if time.since(start) > 3 * time.Second {
			testing.expect(t, false, "agent connect")
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

fixture_agent_config :: proc(base: ag.AgentConfig, bep: net.Endpoint, tls_ca: string) -> ag.AgentConfig {
	cfg := base
	cfg.broker = bep
	cfg.token = T_TOKEN_HOST
	if len(tls_ca) == 0 {
		cfg.insecure = true
	} else {
		cfg.insecure = false
		cfg.tls_ca = tls_ca
		cfg.tls_server_name = "127.0.0.1"
	}
	return cfg
}

connect_tls_temp_seq: int

connect_write_temp_pem :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&connect_tls_temp_seq, 1)
	// Pid as well as the counter: parallel test processes share /tmp and
	// would otherwise overwrite cert-1.pem.
	path = fmt.aprintf("/tmp/thirp-connect-tls-%d-%s-%d.pem", os.get_pid(), label, n)
	err := os.write_entire_file(path, transmute([]u8)contents)
	if err != nil {
		delete(path)
		return "", false
	}
	return path, true
}

fixture_enable_tls :: proc(t: ^testing.T, fx: ^Fixture) -> bool {
	cert_ok: bool
	fx.tls_cert, cert_ok = connect_write_temp_pem("cert", CONNECT_TEST_CERT)
	testing.expect(t, cert_ok, "tls cert")
	key_ok: bool
	fx.tls_key, key_ok = connect_write_temp_pem("key", CONNECT_TEST_KEY)
	testing.expect(t, key_ok, "tls key")
	if !cert_ok || !key_ok {
		return false
	}
	ctx, cerr := trans.tls_server_context_init(fx.tls_cert, fx.tls_key)
	testing.expect_value(t, cerr, trans.TransportError.None)
	if cerr != .None || ctx == nil {
		return false
	}
	fx.server.tls_ctx = ctx
	return true
}

agent_run :: proc(a: ^ag.Agent) {
	_ = ag.agent_run(a)
}

fixture_stop :: proc(fx: ^Fixture) {
	ag.agent_stop(&fx.agent)
	if fx.agent_th != nil {
		thread.join(fx.agent_th)
		thread.destroy(fx.agent_th)
	}
	ag.agent_destroy(&fx.agent)
	trans.listener_close(&fx.up.ln)
	if fx.up.th != nil {
		thread.join(fx.up.th)
		thread.destroy(fx.up.th)
	}
	for sync.atomic_load(&fx.up.live) != 0 {
		time.sleep(1 * time.Millisecond)
	}
	brk.server_stop(&fx.server)
	_ = brk.server_wait_idle(&fx.server, 2 * time.Second)
	brk.server_destroy(&fx.server)
	auth.auth_destroy(&fx.store)
	brk.registry_destroy(&fx.reg)
	delete(fx.broker)
	if len(fx.tls_cert) > 0 {
		_ = os.remove(fx.tls_cert)
		delete(fx.tls_cert)
		fx.tls_cert = ""
	}
	if len(fx.tls_key) > 0 {
		_ = os.remove(fx.tls_key)
		delete(fx.tls_key)
		fx.tls_key = ""
	}
}

UpConnArg :: struct {
	up:   ^Upstream,
	conn: ^trans.Connection,
}

upstream_accept :: proc(up: ^Upstream) {
	defer sync.atomic_store(&up.stopped, true)
	for {
		conn, err := trans.listener_accept(&up.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		_ = trans.connection_set_recv_timeout(conn, 0)
		arg := new(UpConnArg)
		arg.up = up
		arg.conn = conn
		sync.atomic_add(&up.live, 1)
		thread.run_with_poly_data(arg, upstream_conn)
	}
}

upstream_conn :: proc(arg: ^UpConnArg) {
	up := arg.up
	conn := arg.conn
	free(arg)
	defer {
		trans.connection_destroy(conn)
		sync.atomic_sub(&up.live, 1)
	}
	buf: [4096]u8
	n, err := trans.connection_read(conn, buf[:1])
	if err != .None || n != 1 {
		return
	}
	switch buf[0] {
	case 'E':
		for {
			m, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				return
			}
			if trans.connection_write(conn, buf[:m]) != .None {
				return
			}
		}
	case 'P':
		head := make([dynamic]u8)
		defer delete(head)
		for !strings.contains(string(head[:]), "\r\n\r\n") {
			m, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				return
			}
			append(&head, ..buf[:m])
		}
		_ = trans.connection_write(conn, transmute([]u8)string(RESPONSE_403))
	// Close with the body unread (the deferred destroy).
	case 'F':
		chunk := make([]u8, 64 * 1024)
		defer delete(chunk)
		fill_bytes(chunk, FILL_FLOOD)
		_ = trans.connection_set_send_timeout(conn, 20 * time.Second)
		for trans.connection_write(conn, chunk) == .None {
		}
	case 'S':
		want := 0
		for {
			m, rerr := trans.connection_read(conn, buf[:1])
			if rerr != .None || m != 1 {
				return
			}
			if buf[0] == '\n' {
				break
			}
			want = want * 10 + int(buf[0] - '0')
		}
		total := 0
		for total < want {
			m, rerr := trans.connection_read(conn, buf[:min(len(buf), want - total)])
			if rerr != .None {
				return
			}
			total += m
			if total % SLOW_CHUNK < m {
				time.sleep(SLOW_TICK)
			}
		}
		reply := fmt.tprintf("got %d", total)
		_ = trans.connection_write(conn, transmute([]u8)reply)
	case 'C':
		_ = trans.connection_write(conn, transmute([]u8)string("bye"))
		_ = trans.connection_shutdown_write(conn)
		for {
			_, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				break
			}
		}
		// EOF only means the agent shut its write side. Once the agent
		// really closes the socket, a write here gets RST / EPIPE. Before
		// the fix it stayed open in CLOSE-WAIT and these writes kept
		// succeeding.
		probe_start := time.now()
		for time.since(probe_start) < 3 * time.Second {
			if trans.connection_write(conn, []u8{'.'}) != .None {
				sync.atomic_add(&up.closed_seen, 1)
				return
			}
			time.sleep(20 * time.Millisecond)
		}
	case 'X':
		// Never reads; holds the socket X_HOLD, or until drop is set.
		hold := time.now()
		for !sync.atomic_load(&up.drop) && time.since(hold) < X_HOLD {
			time.sleep(10 * time.Millisecond)
		}
	case 'W':
		for {
			_, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				break
			}
		}
		sync.atomic_add(&up.waiting, 1)
		hold := time.now()
		for !sync.atomic_load(&up.release) && time.since(hold) < X_HOLD {
			time.sleep(10 * time.Millisecond)
		}
	case 'H':
		total := 0
		for {
			m, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				break
			}
			total += m
		}
		reply := fmt.tprintf("got %d", total)
		_ = trans.connection_write(conn, transmute([]u8)reply)
	case 'B':
		for {
			_, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				break
			}
		}
		body := make([]u8, HALF_CLOSE_BODY)
		fill_bytes(body, FILL_HALF_CLOSE_BODY)
		_ = trans.connection_write(conn, body)
		delete(body)
		_ = trans.connection_shutdown_write(conn)
	case 'Q':
		// Field POST: read a fixed body, answer, close. The caller then
		// half-closes or resets. Both orders have to drop the origin fd
		// and the caller bridge.
		total := 0
		for total < POST_BODY {
			m, rerr := trans.connection_read(conn, buf[:min(len(buf), POST_BODY - total)])
			if rerr != .None {
				return
			}
			total += m
		}
		_ = trans.connection_write(conn, transmute([]u8)string("OK"))
	}
}

RunArg :: struct {
	args: []string,
	ctl:  ^RunControl,
	rc:   int,
	done: bool,
}

run_proc :: proc(r: ^RunArg) {
	r.rc = connect_main(r.args, r.ctl)
	sync.atomic_store(&r.done, true)
}

// Starts thirp-connect in-process. Returns false if it exited before ready.
start_connect :: proc(t: ^testing.T, r: ^RunArg) -> ^thread.Thread {
	th := thread.create_and_start_with_poly_data(r, run_proc)
	start := time.now()
	for !sync.atomic_load(&r.ctl.ready) && !sync.atomic_load(&r.done) {
		if time.since(start) > 5 * time.Second {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	return th
}

stop_connect :: proc(r: ^RunArg, th: ^thread.Thread) {
	sync.atomic_store(&r.ctl.stop, true)
	thread.join(th)
	thread.destroy(th)
}

local_dial :: proc(t: ^testing.T, ctl: ^RunControl, loc := #caller_location) -> ^trans.Connection {
	conn, err := trans.connection_dial(ctl.bound)
	testing.expect_value(t, err, trans.TransportError.None, loc)
	if conn != nil {
		_ = trans.connection_set_recv_timeout(conn, 5 * time.Second)
	}
	return conn
}

read_all :: proc(conn: ^trans.Connection, out: ^[dynamic]u8) -> trans.TransportError {
	buf: [4096]u8
	for {
		n, err := trans.connection_read(conn, buf[:])
		if n > 0 {
			append(out, ..buf[:n])
		}
		if err != .None {
			return err
		}
	}
}

expect_echo :: proc(t: ^testing.T, ctl: ^RunControl, msg: string, loc := #caller_location) {
	conn := local_dial(t, ctl, loc)
	if conn == nil {
		return
	}
	defer trans.connection_destroy(conn)
	payload := fmt.tprintf("E%s", msg)
	testing.expect_value(t, trans.connection_write(conn, transmute([]u8)payload), trans.TransportError.None, loc)
	got := make([dynamic]u8)
	defer delete(got)
	buf: [256]u8
	for len(got) < len(msg) {
		n, err := trans.connection_read(conn, buf[:])
		if err != .None {
			break
		}
		append(&got, ..buf[:n])
	}
	if string(got[:]) != msg {
		report_stray(fmt.tprintf("echo %q", msg), len(msg), got[:])
	}
	testing.expect_value(t, string(got[:]), msg, loc)
}

wait_bridges_zero :: proc(ctl: ^RunControl, limit: time.Duration) -> bool {
	start := time.now()
	for sync.atomic_load(&ctl.live_bridges) != 0 {
		if time.since(start) > limit {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

temp_path :: proc(label: string) -> string {
	dir := os.get_env("TMPDIR", context.temp_allocator)
	when ODIN_OS == .Windows {
		if len(dir) == 0 {
			dir = os.get_env("TEMP", context.temp_allocator)
		}
	}
	if len(dir) == 0 {
		dir = "/tmp"
	}
	return fmt.aprintf("%s/thirp-connect-test-%s-%d", dir, label, os.get_pid())
}

// Bug 1: --token-file freed the token before the broker login. Base:
// connect_main returns 1 ("broker dial failed"); ready never set.
@(test)
test_connect_token_file_logs_in :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)

	path := temp_path("token")
	defer delete(path)
	contents := T_TOKEN_CALLER + "\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string(contents)) == nil)
	defer os.remove(path)
	when ODIN_OS != .Windows {
		_ = os.chmod(path, {.Read_User, .Write_User})
	}

	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token-file", path, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	ready := sync.atomic_load(&ctl.ready)
	testing.expect(t, ready, "thirp-connect --token-file did not log in")
	if ready {
		expect_echo(t, &ctl, "token-file-ok")
	}
	stop_connect(&r, th)
	if ready {
		testing.expect_value(t, r.rc, 0)
	}
}

// Bug 2: a busy --listen port must fail cleanly: non-zero, no broker session.
@(test)
test_connect_listen_port_in_use_fails_cleanly :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)

	busy, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	defer trans.listener_close(&busy)
	bep, _ := trans.listener_endpoint(busy)
	listen := net.endpoint_to_string(bep, context.temp_allocator)

	for _ in 0 ..< 5 {
		ctl: RunControl
		args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", listen}
		rc := connect_main(args, &ctl)
		testing.expect_value(t, rc, 1)
		testing.expect(t, !sync.atomic_load(&ctl.ready))
	}
	// listen_local names the cause.
	_, msg, ok := listen_local(bep)
	testing.expect(t, !ok)
	testing.expect_value(t, msg, "address already in use")
}

// Bug 3a: the client half-closes after its request. Base turned local EOF
// into a full CLOSE right away. Now EOF goes out as HALF_CLOSE, the bridge
// waits for the peer's side, then ends and closes the local socket. The
// broker keeps frames already accepted across that second HALF_CLOSE, so
// the reply is not dropped.
@(test)
test_connect_client_half_close_tears_down :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	for _ in 0 ..< 3 {
		conn := local_dial(t, &ctl)
		if conn == nil {
			return
		}
		body := make([]u8, 100_000)
		fill_bytes(body, FILL_HALF_CLOSE)
		body[0] = 'H'
		testing.expect_value(t, trans.connection_write(conn, body), trans.TransportError.None)
		delete(body)
		testing.expect_value(t, trans.connection_shutdown_write(conn), trans.TransportError.None)
		got := make([dynamic]u8)
		rerr := read_all(conn, &got)
		testing.expect(t, rerr != .Timeout, "half-closed client never got EOF")
		testing.expect_value(t, string(got[:]), "got 99999")
		delete(got)
		trans.connection_destroy(conn)
		testing.expect(t, wait_bridges_zero(&ctl, 3 * time.Second), "bridge left open after half-close")
	}
	expect_echo(t, &ctl, "after-half-close")
}

// Client writes a request and half-closes. The origin answers with a fixed
// body. The local client must read that body byte for byte, then EOF.
@(test)
test_connect_half_close_delivers_full_response :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	conn := local_dial(t, &ctl)
	if conn == nil {
		return
	}
	defer trans.connection_destroy(conn)
	testing.expect_value(t, trans.connection_write(conn, []u8{'B'}), trans.TransportError.None)
	testing.expect_value(t, trans.connection_shutdown_write(conn), trans.TransportError.None)
	got := make([dynamic]u8)
	defer delete(got)
	rerr := read_all(conn, &got)
	testing.expect(t, rerr != .Timeout, "half-closed client never got EOF")
	want := make([]u8, HALF_CLOSE_BODY)
	defer delete(want)
	fill_bytes(want, FILL_HALF_CLOSE_BODY)
	testing.expect(t, bytes.equal(got[:], want), "half-close response was not the full body")
	testing.expect(t, wait_bridges_zero(&ctl, 3 * time.Second), "bridge left open after half-close")
}

REAL_AGENT_HALF_CLOSE_N :: 10_000

kept_ids :: proc(server: ^brk.Server, role: proto.PeerRole) -> int {
	sync.mutex_lock(&server.handlers_mutex)
	defer sync.mutex_unlock(&server.handlers_mutex)
	for h in server.handlers {
		if h != nil && h.role == role && h.state == .Authenticated {
			return brk.half_close_finished_len(&h.half_close_finished)
		}
	}
	return -1
}

// Caller half-closes, the origin answers and closes, and this repo's agent
// sends HALF_CLOSE and no CLOSE. The broker ring on that long-lived agent
// connection must stay at its cap. A late CLOSE inside the window is
// test_half_close_finished_ring_stays_bounded: the agent owns this socket,
// so the wire test sends that CLOSE on the same caller-first sequence.
@(test)
test_real_agent_half_close_ring_stays_bounded :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	for _ in 0 ..< REAL_AGENT_HALF_CLOSE_N {
		if testing.failed(t) {
			return
		}
		conn := local_dial(t, &ctl)
		if conn == nil {
			return
		}
		testing.expect_value(t, trans.connection_write(conn, []u8{'H'}), trans.TransportError.None)
		testing.expect_value(t, trans.connection_shutdown_write(conn), trans.TransportError.None)
		got := make([dynamic]u8)
		rerr := read_all(conn, &got)
		testing.expect(t, rerr != .Timeout, "half-closed client never got EOF")
		testing.expect_value(t, string(got[:]), "got 0")
		delete(got)
		trans.connection_destroy(conn)
		start := time.now()
		for sync.atomic_load(&ctl.live_bridges) != 0 {
			if time.since(start) > 3 * time.Second {
				testing.expect(t, false, "bridge left open after half-close")
				return
			}
			time.sleep(100 * time.Microsecond)
		}
	}

	agent_kept := kept_ids(&fx.server, .Agent)
	caller_kept := kept_ids(&fx.server, .Caller)
	fmt.printfln(
		"real agent half_close ring: agent_kept=%d caller_kept=%d cap=%d after %d requests",
		agent_kept,
		caller_kept,
		brk.HALF_CLOSE_FINISHED_CAP,
		REAL_AGENT_HALF_CLOSE_N,
	)
	testing.expect_value(t, agent_kept, brk.HALF_CLOSE_FINISHED_CAP)
	testing.expect(t, caller_kept >= 0 && caller_kept <= brk.HALF_CLOSE_FINISHED_CAP, "caller ring unbounded")
}

EarlyWriter :: struct {
	conn: ^trans.Connection,
	size: int,
}

early_writer :: proc(w: ^EarlyWriter) {
	head := fmt.tprintf("PPOST /api2/json/x HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n", w.size)
	if trans.connection_write(w.conn, transmute([]u8)head) != .None {
		return
	}
	chunk := make([]u8, 64 * 1024)
	defer delete(chunk)
	fill_bytes(chunk, FILL_EARLY)
	sent := 0
	for sent < w.size {
		if trans.connection_write(w.conn, chunk) != .None {
			return
		}
		sent += len(chunk)
	}
}

// Bug 3b (field shape): server answers 403 and closes while the client is
// still sending a large urlencoded body. The request must end promptly, the
// local socket must be closed by thirp-connect (no CLOSE-WAIT bridge), and
// the next request must work.
@(test)
test_connect_early_answer_while_client_sending :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	for round in 0 ..< 3 {
		conn := local_dial(t, &ctl)
		if conn == nil {
			return
		}
		_ = trans.connection_set_send_timeout(conn, 10 * time.Second)
		w := EarlyWriter{conn = conn, size = 8 * 1024 * 1024}
		wth := thread.create_and_start_with_poly_data(&w, early_writer)
		start := time.now()
		got := make([dynamic]u8)
		rerr := read_all(conn, &got)
		elapsed := time.since(start)
		// Ends with EOF or reset, never the 5 s client read timeout.
		testing.expectf(t, rerr != .Timeout, "round %d: request hung (%v)", round, elapsed)
		if len(got) > 0 {
			testing.expect(t, strings.has_prefix(string(got[:]), "HTTP/1.1 403"))
		}
		delete(got)
		trans.connection_shutdown_both(conn)
		thread.join(wth)
		thread.destroy(wth)
		trans.connection_destroy(conn)
		testing.expectf(t, wait_bridges_zero(&ctl, 4 * time.Second), "round %d: bridge still open", round)
		expect_echo(t, &ctl, "after-403")
	}
}

// Bug 3c: one stuck stream must not block new accepts or other streams.
// Client A connects to an upstream that floods and never reads A; A never
// reads either. Base: the session reader blocked on A forever and the accept
// loop sat in dial, so B hung and later clients queued in the backlog.
@(test)
test_connect_stuck_stream_does_not_block_accepts :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	ctl.stream_stall_timeout = 500 * time.Millisecond
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	a := local_dial(t, &ctl)
	if a == nil {
		return
	}
	defer trans.connection_destroy(a)
	// The upstream floods A; A never reads. A's inbound fills and the session
	// reader used to wait on it forever.
	testing.expect_value(t, trans.connection_write(a, []u8{'F'}), trans.TransportError.None)
	time.sleep(300 * time.Millisecond)

	start := time.now()
	for i in 0 ..< 3 {
		expect_echo(t, &ctl, fmt.tprintf("b-%d", i))
	}
	testing.expect(t, time.since(start) < 6 * time.Second)

	// A was reset, and thirp-connect closed A's socket on its own: its
	// bounded local write gave up, so the bridge ended without A closing.
	testing.expect(t, wait_bridges_zero(&ctl, 4 * time.Second), "stuck bridge never torn down")
}

// Theo's review: the upstream closes first (answers, then shuts its side).
// The agent used to send HALF_CLOSE and return from the pump; the broker's
// HALF_CLOSE then only shut the agent's write side, so its socket to the
// upstream stayed in CLOSE-WAIT for good. Now the agent closes it once both
// sides are done. Base: closed_seen stays 0.
@(test)
test_connect_upstream_closes_first_agent_closes_socket :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}
	for round in 1 ..= 3 {
		conn := local_dial(t, &ctl)
		if conn == nil {
			return
		}
		testing.expect_value(t, trans.connection_write(conn, []u8{'C'}), trans.TransportError.None)
		got := make([dynamic]u8)
		buf: [16]u8
		for len(got) < 3 {
			n, rerr := trans.connection_read(conn, buf[:])
			if rerr != .None {
				break
			}
			append(&got, ..buf[:n])
		}
		testing.expect_value(t, string(got[:]), "bye")
		delete(got)
		// Let the upstream's EOF (the first HALF_CLOSE) reach the bridge,
		// then end the client side too: the second HALF_CLOSE. (Reading the
		// EOF here would mark conn closed and skip the shutdown.)
		time.sleep(200 * time.Millisecond)
		testing.expect_value(t, trans.connection_shutdown_write(conn), trans.TransportError.None)
		start := time.now()
		for sync.atomic_load(&fx.up.closed_seen) < round && time.since(start) < 4 * time.Second {
			time.sleep(10 * time.Millisecond)
		}
		testing.expectf(t, sync.atomic_load(&fx.up.closed_seen) == round, "round %d: agent socket to upstream left open (CLOSE-WAIT)", round)
		trans.connection_destroy(conn)
		testing.expect(t, wait_bridges_zero(&ctl, 3 * time.Second), "bridge left open")
	}
}

SlowUpload :: struct {
	conn: ^trans.Connection,
	size: int,
	err:  trans.TransportError,
}

slow_upload_writer :: proc(u: ^SlowUpload) {
	head := fmt.tprintf("S%d\n", u.size)
	if u.err = trans.connection_write(u.conn, transmute([]u8)head); u.err != .None {
		return
	}
	chunk := make([]u8, 64 * 1024)
	defer delete(chunk)
	fill_bytes(chunk, FILL_SLOW_UPLOAD)
	sent := 0
	for sent < u.size {
		n := min(len(chunk), u.size - sent)
		if u.err = trans.connection_write(u.conn, chunk[:n]); u.err != .None {
			return
		}
		sent += n
	}
}

ParallelEcho :: struct {
	t:       ^testing.T,
	ctl:     ^RunControl,
	idx:     int,
	ok:      bool,
	elapsed: time.Duration,
}

parallel_echo :: proc(p: ^ParallelEcho) {
	start := time.now()
	conn, err := trans.connection_dial(p.ctl.bound)
	if err != .None {
		return
	}
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_recv_timeout(conn, 10 * time.Second)
	msg := fmt.aprintf("parallel-%d", p.idx)
	defer delete(msg)
	payload := fmt.aprintf("E%s", msg)
	defer delete(payload)
	if trans.connection_write(conn, transmute([]u8)payload) != .None {
		return
	}
	got := make([dynamic]u8)
	defer delete(got)
	buf: [256]u8
	for len(got) < len(msg) {
		n, rerr := trans.connection_read(conn, buf[:])
		if rerr != .None {
			break
		}
		append(&got, ..buf[:n])
	}
	p.elapsed = time.since(start)
	p.ok = string(got[:]) == msg
	if !p.ok {
		report_stray(fmt.tprintf("parallel echo %d", p.idx), len(msg), got[:])
	}
}

// Names the writer behind a wrong echo by its fill byte (see FILL_*).
report_stray :: proc(who: string, want: int, got: []u8) {
	if len(got) == 0 {
		fmt.eprintf("%s: want %d bytes, got none\n", who, want)
		return
	}
	fmt.eprintf("%s: want %d bytes, got %d; first byte 0x%02x = %s\n", who, want, len(got), got[0], fill_source(got[0]))
}

// Theo's replay: a large upload to a server reading ~320 KB/s used to hold
// the agent's one relay reader in a blocking local write (and the broker's
// caller-session reader at conn.odin:1119 behind it), so three requests
// started during the upload got nothing. Now each stream has its own queue:
// the three requests finish promptly and the upload still completes, with
// the default 30 s no-progress stall (a slow but steady reader survives).
@(test)
test_connect_slow_upload_does_not_block_other_streams :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	size := REPLAY_UPLOAD_MB * 1000 * 1000
	rate := f64(SLOW_CHUNK) / time.duration_seconds(SLOW_TICK)
	expected := time.Duration(f64(size) / rate * f64(time.Second))
	conn := local_dial(t, &ctl)
	if conn == nil {
		return
	}
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_send_timeout(conn, 0)
	_ = trans.connection_set_recv_timeout(conn, expected * 2 + 30 * time.Second)
	up := SlowUpload{conn = conn, size = size}
	upload_start := time.now()
	wth := thread.create_and_start_with_poly_data(&up, slow_upload_writer)

	// Let the upload get ahead of the slow server first.
	time.sleep(1 * time.Second)
	echoes: [3]ParallelEcho
	ths: [3]^thread.Thread
	for i in 0 ..< 3 {
		echoes[i] = ParallelEcho{t = t, ctl = &ctl, idx = i}
		ths[i] = thread.create_and_start_with_poly_data(&echoes[i], parallel_echo)
	}
	for i in 0 ..< 3 {
		thread.join(ths[i])
		thread.destroy(ths[i])
		testing.expectf(t, echoes[i].ok, "parallel request %d got no answer during the upload", i)
		testing.expectf(t, echoes[i].elapsed < 3 * time.Second, "parallel request %d took %v", i, echoes[i].elapsed)
		fmt.printf("replay: parallel request %d answered in %v\n", i, echoes[i].elapsed)
	}

	got := make([dynamic]u8)
	defer delete(got)
	buf: [64]u8
	want := fmt.tprintf("got %d", size)
	for len(got) < len(want) {
		n, rerr := trans.connection_read(conn, buf[:])
		if rerr != .None {
			break
		}
		append(&got, ..buf[:n])
	}
	thread.join(wth)
	thread.destroy(wth)
	testing.expect_value(t, up.err, trans.TransportError.None)
	testing.expect_value(t, string(got[:]), want)
	fmt.printf("replay: %d MB upload at ~%.0f KB/s finished in %v (ideal %v)\n", REPLAY_UPLOAD_MB, rate / 1000, time.since(upload_start), expected)
}

@(test)
test_connect_stream_stall_timeout_flag_validates :: proc(t: ^testing.T) {
	for bad in ([]string{"x", "-1", "86401", ""}) {
		ctl: RunControl
		args := []string{"--broker", "127.0.0.1:1", "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0", "--stream-stall-timeout", bad}
		testing.expect_value(t, connect_main(args, &ctl), 1)
		testing.expect(t, !sync.atomic_load(&ctl.ready))
	}
	ctl: RunControl
	args := []string{"--stream-stall-timeout"}
	testing.expect_value(t, connect_main(args, &ctl), 1)
}

@(test)
test_connect_max_stream_buffer_flag_validates :: proc(t: ^testing.T) {
	for bad in ([]string{"x", "0", "-1", "1048577", "1.5", ""}) {
		ctl: RunControl
		args := []string{"--broker", "127.0.0.1:1", "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0", "--max-stream-buffer-mib", bad}
		testing.expect_value(t, connect_main(args, &ctl), 1)
		testing.expect(t, !sync.atomic_load(&ctl.ready))
	}
	ctl: RunControl
	args := []string{"--max-stream-buffer-mib"}
	testing.expect_value(t, connect_main(args, &ctl), 1)
}

// ---- Round 3 replays (Theo @ e1467d90): never wait at a cap -------------

// Upload of size bytes after a one-byte mode; records how it ended.
CapUpload :: struct {
	conn:  ^trans.Connection,
	mode:  u8,
	fill:  u8,
	size:  int,
	sent:  int, // atomic
	err:   trans.TransportError,
	done:  bool, // atomic
}

cap_upload_writer :: proc(u: ^CapUpload) {
	defer sync.atomic_store(&u.done, true)
	head: []u8
	if u.mode == 'S' {
		head = transmute([]u8)fmt.tprintf("S%d\n", u.size)
	} else {
		head = []u8{u.mode}
	}
	if u.err = trans.connection_write(u.conn, head); u.err != .None {
		return
	}
	chunk := make([]u8, 64 * 1024)
	defer delete(chunk)
	fill_bytes(chunk, u.fill)
	for sync.atomic_load(&u.sent) < u.size {
		n := min(len(chunk), u.size - sync.atomic_load(&u.sent))
		if u.err = trans.connection_write(u.conn, chunk[:n]); u.err != .None {
			return
		}
		sync.atomic_add(&u.sent, n)
	}
}

// Three requests in parallel; returns the slowest, and whether all answered.
three_echoes :: proc(ctl: ^RunControl, tag: int) -> (slowest: time.Duration, all_ok: bool) {
	echoes: [3]ParallelEcho
	ths: [3]^thread.Thread
	for i in 0 ..< 3 {
		echoes[i] = ParallelEcho{ctl = ctl, idx = tag * 10 + i}
		ths[i] = thread.create_and_start_with_poly_data(&echoes[i], parallel_echo, init_context = context)
	}
	all_ok = true
	for i in 0 ..< 3 {
		thread.join(ths[i])
		thread.destroy(ths[i])
		all_ok = all_ok && echoes[i].ok
		slowest = max(slowest, echoes[i].elapsed)
	}
	return
}

// The agent thinks it is connected AND the broker still has its session
// (Theo's probe: the broker had dropped it while agent_is_connected was true).
session_up :: proc(fx: ^Fixture) -> bool {
	services, sessions, _ := brk.registry_metrics(&fx.reg)
	return ag.agent_is_connected(&fx.agent) && services == 1 && sessions >= 1
}

proc_threads :: proc() -> int {
	when ODIN_OS == .Linux {
		fd, err := os.open("/proc/self/status")
		if err != nil {
			return -1
		}
		defer os.close(fd)
		buf: [8192]u8
		n, _ := os.read(fd, buf[:])
		text := string(buf[:n])
		if i := strings.index(text, "Threads:"); i >= 0 {
			rest := strings.trim_left_space(text[i + len("Threads:"):])
			v := 0
			for c in transmute([]u8)rest {
				if c < '0' || c > '9' {
					break
				}
				v = v * 10 + int(c - '0')
			}
			return v
		}
	}
	return -1
}

// Observation window after the cap resets. Theo's session drop came ~30 s
// in (fixture session timeout); the full replay uses
// -define:THIRP_REPLAY_OBSERVE_S=40.
REPLAY_OBSERVE :: time.Duration(#config(THIRP_REPLAY_OBSERVE_S, 6)) * time.Second
REPLAY_BIG_MB :: #config(THIRP_REPLAY_BIG_MB, 200)

// (a) Upload far past the 64 MiB per-stream cap to a ~328 KB/s reader. The
// agent RESETs that stream as soon as its backlog would pass the cap; the
// shared reader never waits, so three requests during and after answer
// promptly and the agent session stays up on both sides. Base (e1467d90):
// requests waited ~30 s, then the broker dropped the agent's session while
// the agent still reported itself connected.
@(test)
test_connect_upload_past_stream_cap_is_reset_others_unaffected :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}
	conn := local_dial(t, &ctl)
	if conn == nil {
		return
	}
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_send_timeout(conn, 20 * time.Second)
	u := CapUpload{conn = conn, mode = 'S', fill = FILL_CAP_UPLOAD, size = REPLAY_BIG_MB * 1000 * 1000}
	start := time.now()
	wth := thread.create_and_start_with_poly_data(&u, cap_upload_writer, init_context = context)

	time.sleep(500 * time.Millisecond)
	d1, ok1 := three_echoes(&ctl, 1)
	testing.expectf(t, ok1 && d1 < 3 * time.Second, "requests during the upload: ok=%v slowest=%v", ok1, d1)

	// The upload must end (reset), not complete: 200 MB would take ~10 min.
	for !sync.atomic_load(&u.done) && time.since(start) < 20 * time.Second {
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, sync.atomic_load(&u.done), "upload never ended")
	sent := sync.atomic_load(&u.sent)
	// After the RESET thirp-connect drains the rest of the client's bytes
	// (bounded linger) and closes; the server's "got N" never comes.
	_ = trans.connection_set_recv_timeout(conn, 10 * time.Second)
	reply := make([dynamic]u8)
	rerr := read_all(conn, &reply)
	ended := time.since(start)
	testing.expectf(t, rerr != .Timeout, "upload stream was not ended (no reset at the cap)")
	testing.expectf(t, !strings.has_prefix(string(reply[:]), "got"), "upload completed instead of being reset: %s", string(reply[:]))
	delete(reply)
	trans.connection_shutdown_both(conn)
	thread.join(wth)
	thread.destroy(wth)

	peak := sync.atomic_load(&fx.agent.buffered_peak)
	in_flight_echo_bytes := 3 * len("Eparallel-10")
	testing.expectf(t, peak <= ag.DEFAULT_AGENT_STREAM_BUFFER + in_flight_echo_bytes, "agent queued %d > per-stream cap %d + in-flight echoes %d", peak, ag.DEFAULT_AGENT_STREAM_BUFFER, in_flight_echo_bytes)

	obs := time.now()
	worst: time.Duration
	all := true
	rounds := 0
	for time.since(obs) < REPLAY_OBSERVE {
		d, ok := three_echoes(&ctl, 2 + rounds)
		worst = max(worst, d)
		all = all && ok
		testing.expect(t, session_up(&fx), "agent session lost (agent or broker side)")
		rounds += 1
		time.sleep(1 * time.Second)
	}
	testing.expectf(t, all && worst < 3 * time.Second, "requests after the reset: ok=%v slowest=%v", all, worst)
	testing.expect(t, session_up(&fx), "agent session lost at the end")
	fmt.printf("replay-a: %d MB upload reset after %v with %d MB sent; agent peak queue %.1f MiB; during: slowest %v; after: %d rounds over %v, slowest %v; session up=%v\n",
		REPLAY_BIG_MB, ended, sent / 1000000, f64(peak) / (1024 * 1024), d1, rounds, REPLAY_OBSERVE, worst, session_up(&fx))
}

// (b) Theo's memory probe: 12 uploads to a service that never reads. The
// agent-wide cap holds the queued bytes (the largest streams are reset),
// threads stay bounded, the other requests answer and the session stays up.
// Base (e1467d90): 618 MiB RSS and +72 threads in 1 s, held for 30 s.
@(test)
test_connect_never_read_uploads_hit_agent_caps :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}
	N :: 12
	base_threads := proc_threads()
	ups: [N]CapUpload
	conns: [N]^trans.Connection
	ths: [N]^thread.Thread
	for i in 0 ..< N {
		conns[i] = local_dial(t, &ctl)
		if conns[i] == nil {
			return
		}
		_ = trans.connection_set_send_timeout(conns[i], 15 * time.Second)
		ups[i] = CapUpload{conn = conns[i], mode = 'X', fill = FILL_NEVER_READ + u8(i), size = 100 * 1000 * 1000}
		ths[i] = thread.create_and_start_with_poly_data(&ups[i], cap_upload_writer, init_context = context)
	}
	peak_threads := 0
	start := time.now()
	for time.since(start) < 1500 * time.Millisecond {
		peak_threads = max(peak_threads, proc_threads())
		time.sleep(50 * time.Millisecond)
	}
	d, ok := three_echoes(&ctl, 1)
	testing.expectf(t, ok && d < 3 * time.Second, "requests during the uploads: ok=%v slowest=%v", ok, d)
	testing.expect(t, session_up(&fx), "agent session lost")
	for time.since(start) < 4 * time.Second {
		peak_threads = max(peak_threads, proc_threads())
		time.sleep(50 * time.Millisecond)
	}
	d2, ok2 := three_echoes(&ctl, 2)
	testing.expectf(t, ok2 && d2 < 3 * time.Second, "requests later: ok=%v slowest=%v", ok2, d2)
	testing.expect(t, session_up(&fx), "agent session lost")

	peak := sync.atomic_load(&fx.agent.buffered_peak)
	testing.expectf(t, peak <= ag.DEFAULT_AGENT_BUFFERED_BYTES, "agent queued %d > agent-wide cap", peak)
	// Streams the caps reset: thirp-connect closed the client's socket.
	closed := 0
	for i in 0 ..< N {
		_ = trans.connection_set_recv_timeout(conns[i], 200 * time.Millisecond)
		b: [16]u8
		if _, e := trans.connection_read(conns[i], b[:]); e != .Timeout {
			closed += 1
		}
	}
	for i in 0 ..< N {
		trans.connection_shutdown_both(conns[i])
		thread.join(ths[i])
		thread.destroy(ths[i])
		trans.connection_destroy(conns[i])
	}
	reset := 0
	for i in 0 ..< N {
		if sync.atomic_load(&ups[i].done) {
			reset += 1
		}
	}
	fmt.printf("replay-b: %d never-read uploads; agent peak queue %.1f MiB (cap %d MiB); process threads %d -> peak %d (test, broker, connect and agent in one process); requests slowest %v / %v; session up=%v; streams reset by the caps %d/%d (writers done %d)\n",
		N, f64(peak) / (1024 * 1024), ag.DEFAULT_AGENT_BUFFERED_BYTES / (1024 * 1024), base_threads, peak_threads, d, d2, session_up(&fx), closed, N, reset)
}

// Stream cap: OPENs past max_streams are refused (OPEN_FAILED
// QuotaExceeded) without touching the open streams or the session.
@(test)
test_connect_agent_stream_cap_refuses_new_streams_only :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx, ag.AgentConfig{max_streams = 2}) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}
	held: [2]^trans.Connection
	for i in 0 ..< 2 {
		held[i] = local_dial(t, &ctl)
		if held[i] == nil {
			return
		}
		testing.expect_value(t, trans.connection_write(held[i], []u8{'E', 'h'}), trans.TransportError.None)
		buf: [8]u8
		n, rerr := trans.connection_read(held[i], buf[:])
		testing.expect(t, rerr == .None && n == 1, "held stream did not echo")
	}
	// Third stream: refused, the client sees its socket closed with no data.
	extra := local_dial(t, &ctl)
	if extra == nil {
		return
	}
	_ = trans.connection_write(extra, []u8{'E', 'z'})
	got := make([dynamic]u8)
	rerr := read_all(extra, &got)
	testing.expect(t, rerr != .Timeout, "refused stream was not closed")
	testing.expect_value(t, len(got), 0)
	delete(got)
	trans.connection_destroy(extra)
	// The held streams still work, and the session is up.
	for i in 0 ..< 2 {
		testing.expect_value(t, trans.connection_write(held[i], []u8{'k'}), trans.TransportError.None)
		buf: [8]u8
		n, rerr2 := trans.connection_read(held[i], buf[:])
		testing.expect(t, rerr2 == .None && n == 1 && buf[0] == 'k', "held stream broken by the refusal")
		trans.connection_destroy(held[i])
	}
	testing.expect(t, session_up(&fx), "agent session lost")
	testing.expect(t, wait_bridges_zero(&ctl, 3 * time.Second))
	expect_echo(t, &ctl, "after-cap")
}

// Theo's round-3 case. A client of thirp-connect A asks for a large download
// and stops reading (a paused pager); it reopens a paused download every
// 1.5 s. A second thirp-connect B, another caller of the same agent, keeps
// answering promptly. Before: A's session reader waited up to 30 s at the
// 8 MiB cap, the broker's queue for that stream filled, the broker stopped
// reading the agent session (outbox_wait_stream_space), and B's requests
// took ~29 s. Now A's stream is reset at the cap with no wait.
@(test)
test_connect_paused_client_does_not_freeze_other_callers :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	ctl_a, ctl_b: RunControl
	ra := RunArg{args = args, ctl = &ctl_a}
	rb := RunArg{args = args, ctl = &ctl_b}
	tha := start_connect(t, &ra)
	defer stop_connect(&ra, tha)
	thb := start_connect(t, &rb)
	defer stop_connect(&rb, thb)
	if !sync.atomic_load(&ctl_a.ready) || !sync.atomic_load(&ctl_b.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	paused := make([dynamic]^trans.Connection)
	defer {
		for p in paused {
			trans.connection_destroy(p)
		}
		delete(paused)
	}
	slowest: time.Duration
	rounds, failed := 0, 0
	start := time.now()
	next_pause := start
	for time.since(start) < 6 * time.Second {
		if len(paused) < 4 && time.since(next_pause) >= 0 {
			p := local_dial(t, &ctl_a)
			if p == nil {
				return
			}
			append(&paused, p)
			testing.expect_value(t, trans.connection_write(p, []u8{'F'}), trans.TransportError.None)
			next_pause = time.time_add(time.now(), 1500 * time.Millisecond)
			time.sleep(300 * time.Millisecond) // let A's backlog reach the cap
		}
		s, ok := three_echoes(&ctl_b, rounds)
		slowest = max(slowest, s)
		rounds += 1
		if !ok {
			failed += 1
		}
		time.sleep(200 * time.Millisecond)
	}
	up := session_up(&fx)
	fmt.printf(
		"paused-client: %d paused downloads on A; B: %d rounds of 3, slowest %v, failed %d; session up=%v\n",
		len(paused), rounds, slowest, failed, up,
	)
	testing.expect_value(t, failed, 0)
	testing.expect(t, slowest < 2 * time.Second, "B waited on A's paused client")
	testing.expect(t, up, "agent session dropped")
}

StopArg :: struct {
	r:    ^RunArg,
	th:   ^thread.Thread,
	done: bool, // atomic
}

stop_proc :: proc(a: ^StopArg) {
	stop_connect(a.r, a.th)
	sync.atomic_store(&a.done, true)
}

// Teardown with a reply pending. The client sends and half-closes; the
// upstream reads to EOF and then holds the stream with no answer, so the
// bridge's pump sits in conn_read. Stopping thirp-connect must still return
// at once: the kick ends the stream. Before, stop_connect waited until the
// upstream answered or closed; on Windows, after the cap test failed, that
// was forever (F5 in the lab run).
@(test)
test_connect_stop_with_reply_pending_returns :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	defer sync.atomic_store(&fx.up.release, true)
	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		stop_connect(&r, th)
		return
	}
	conn := local_dial(t, &ctl)
	if conn == nil {
		stop_connect(&r, th)
		return
	}
	defer trans.connection_destroy(conn)
	testing.expect_value(t, trans.connection_write(conn, []u8{'W', 'q'}), trans.TransportError.None)
	testing.expect_value(t, trans.connection_shutdown_write(conn), trans.TransportError.None)
	wait := time.now()
	for sync.atomic_load(&fx.up.waiting) == 0 && time.since(wait) < 3 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&fx.up.waiting) == 1, "upstream never saw the half-close")
	testing.expect(t, sync.atomic_load(&ctl.live_bridges) == 1, "bridge not open while the reply is pending")

	sa := StopArg{r = &r, th = th}
	start := time.now()
	sth := thread.create_and_start_with_poly_data(&sa, stop_proc, init_context = context)
	for !sync.atomic_load(&sa.done) && time.since(start) < 3 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	elapsed := time.since(start)
	stopped := sync.atomic_load(&sa.done)
	// Unblock a regressed teardown so the test fails instead of hanging.
	sync.atomic_store(&fx.up.release, true)
	thread.join(sth)
	thread.destroy(sth)
	testing.expectf(t, stopped, "stop_connect still waiting after %v with a reply pending", elapsed)
	fmt.printf("stop-with-reply-pending: stop_connect returned in %v (stopped=%v)\n", elapsed, stopped)
}

DialLogs :: struct {
	mu:   sync.Mutex,
	text: [dynamic]u8,
}

dial_logs: DialLogs

dial_log_sink :: proc(text: string) {
	sync.mutex_lock(&dial_logs.mu)
	defer sync.mutex_unlock(&dial_logs.mu)
	append(&dial_logs.text, ..transmute([]u8)text)
}

dial_log_text :: proc() -> string {
	sync.mutex_lock(&dial_logs.mu)
	defer sync.mutex_unlock(&dial_logs.mu)
	return strings.clone(string(dial_logs.text[:]))
}

// Sockets this process holds whose local or remote TCP port is `port`.
// CLOSE-WAIT still has an fd; TIME_WAIT does not. -1 off Linux.
tcp_port_socket_count :: proc(port: int) -> int {
	when ODIN_OS != .Linux {
		return -1
	}
	inodes := self_socket_inodes()
	defer delete(inodes)
	return tcp_table_port_count("/proc/net/tcp", port, &inodes) + tcp_table_port_count("/proc/net/tcp6", port, &inodes)
}

self_socket_inodes :: proc() -> map[int]struct{} {
	inodes := make(map[int]struct{})
	when ODIN_OS != .Linux {
		return inodes
	}
	dir, err := os.open("/proc/self/fd")
	if err != nil {
		return inodes
	}
	defer os.close(dir)
	infos, rerr := os.read_directory(dir, -1, context.allocator)
	if rerr != nil {
		return inodes
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	for info in infos {
		path := fmt.tprintf("/proc/self/fd/%s", info.name)
		link, lerr := os.read_link(path, context.temp_allocator)
		if lerr != nil {
			continue
		}
		prefix := "socket:["
		if !strings.has_prefix(link, prefix) || !strings.has_suffix(link, "]") {
			continue
		}
		num := link[len(prefix) : len(link) - 1]
		inode, ok := strconv.parse_int(num)
		if ok && inode > 0 {
			inodes[inode] = {}
		}
	}
	return inodes
}

tcp_table_port_count :: proc(path: string, port: int, inodes: ^map[int]struct{}) -> int {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return 0
	}
	defer delete(data)
	n := 0
	rest := string(data)
	header := true
	for len(rest) > 0 {
		line := rest
		if i := strings.index(rest, "\n"); i >= 0 {
			line = rest[:i]
			rest = rest[i + 1 :]
		} else {
			rest = ""
		}
		if header {
			header = false
			continue
		}
		fields: [12]string
		nf := 0
		i := 0
		for i < len(line) && nf < len(fields) {
			for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
				i += 1
			}
			if i >= len(line) {
				break
			}
			start := i
			for i < len(line) && line[i] != ' ' && line[i] != '\t' {
				i += 1
			}
			fields[nf] = line[start:i]
			nf += 1
		}
		if nf < 10 {
			continue
		}
		inode, iok := strconv.parse_int(fields[9])
		if !iok {
			continue
		}
		if _, ours := inodes[inode]; !ours {
			continue
		}
		if hex_port(fields[1]) == port || hex_port(fields[2]) == port {
			n += 1
		}
	}
	return n
}

hex_port :: proc(addr: string) -> int {
	colon := strings.last_index(addr, ":")
	if colon < 0 || colon + 1 >= len(addr) {
		return -1
	}
	v, ok := strconv.parse_uint(addr[colon + 1 :], 16)
	if !ok {
		return -1
	}
	return int(v)
}

storm_read_ok :: proc(t: ^testing.T, conn: ^trans.Connection, loc := #caller_location) -> bool {
	got := make([dynamic]u8, 0, 8)
	defer delete(got)
	buf: [64]u8
	for !strings.contains(string(got[:]), "OK") {
		n, rerr := trans.connection_read(conn, buf[:])
		if n > 0 {
			append(&got, ..buf[:n])
		}
		if rerr != .None {
			if strings.contains(string(got[:]), "OK") {
				return true
			}
			testing.expectf(t, false, "POST response missing (%v, got %s)", rerr, string(got[:]), loc = loc)
			return false
		}
		if len(got) > 64 {
			testing.expect(t, false, "POST response too long", loc = loc)
			return false
		}
	}
	return true
}

// Sequential ~46 KB POSTs through thirp-connect, plus resets and a
// client-half-close-first pass. Afterwards the agent stream table, the
// caller stream table, bridge count, and the sockets on the origin and
// listen ports are back to the baseline, and another dial works. A refused
// origin dial logs one line and the local client sees the socket close
// instead of sitting open with no error.
@(test)
test_post_storm_fds_and_streams_return_to_baseline :: proc(t: ^testing.T) {
	clear(&dial_logs.text)
	dial_logs.text = make([dynamic]u8)
	defer delete(dial_logs.text)

	logger: log.Logger
	log.logger_init(&logger, .Warn, dial_log_sink)

	fx: Fixture
	if !fixture_start(t, &fx, ag.AgentConfig{max_streams = -1, logger = &logger}) {
		return
	}
	defer fixture_stop(&fx)
	// The storm is one active session the whole time. Production's 45s
	// session timeout is shorter than this test; the heartbeat still runs.
	fx.server.session_timeout = 180 * time.Second

	up_ep, uerr := trans.listener_endpoint(fx.up.ln)
	testing.expect_value(t, uerr, trans.TransportError.None)
	up_port := up_ep.port

	ctl: RunControl
	args := []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}
	listen_port := ctl.bound.port
	base_up := tcp_port_socket_count(up_port)
	base_listen := tcp_port_socket_count(listen_port)
	base_resets := brk.metrics_snapshot(&fx.server).resets[.StreamNotFound]

	body := make([]u8, 1 + POST_BODY)
	defer delete(body)
	body[0] = 'Q'
	for i in 1 ..< len(body) {
		body[i] = 0x51
	}

	for i in 0 ..< POST_STORM_N {
		conn := storm_dial(t, &ctl)
		if conn == nil {
			return
		}
		kind := i % 7
		if kind == 0 {
			// Reset while the body is still going out.
			testing.expect_value(t, trans.connection_write(conn, body[:1024]), trans.TransportError.None)
			trans.connection_destroy(conn)
			continue
		}
		testing.expect_value(t, trans.connection_write(conn, body), trans.TransportError.None)
		if kind == 1 {
			// Client finishes the upload before the response. This is the
			// order that used to drop the queued reply and the peer EOF.
			testing.expect_value(t, trans.connection_shutdown_write(conn), trans.TransportError.None)
		}
		if !storm_read_ok(t, conn) {
			trans.connection_destroy(conn)
			return
		}
		trans.connection_destroy(conn)
	}

	streams, pumps, caller_streams, bridges, up_live, up_fds, listen_fds: int
	start := time.now()
	for {
		streams, pumps, caller_streams, bridges, up_live, up_fds, listen_fds = storm_load(&fx, &ctl, up_port, listen_port)
		// Off Linux the fd helper returns -1 on both sides, so the compare holds.
		quiet := streams == 0 && pumps == 0 && caller_streams == 0 && bridges == 0 && up_live == 0 && up_fds == base_up && listen_fds == base_listen
		if quiet || time.since(start) >= 3 * time.Second {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expectf(
		t,
		streams == 0 && pumps == 0 && caller_streams == 0 && bridges == 0 && up_live == 0,
		"after %d POSTs: agent streams %d pumps %d caller streams %d bridges %d upstream conns %d",
		POST_STORM_N,
		streams,
		pumps,
		caller_streams,
		bridges,
		up_live,
	)
	when ODIN_OS == .Linux {
		testing.expectf(
			t,
			up_fds == base_up && listen_fds == base_listen,
			"fds not back to baseline: origin %d (base %d) listen %d (base %d)",
			up_fds,
			base_up,
			listen_fds,
			base_listen,
		)
	}
	got_resets := brk.metrics_snapshot(&fx.server).resets[.StreamNotFound]
	testing.expectf(t, got_resets == base_resets, "stream_not_found %d -> %d", base_resets, got_resets)

	// A dial after the storm still completes. This is the hang that showed
	// up as a client timeout with no error frame.
	again := storm_dial(t, &ctl)
	if again == nil {
		return
	}
	testing.expect_value(t, trans.connection_write(again, body), trans.TransportError.None)
	ok := storm_read_ok(t, again)
	trans.connection_destroy(again)
	testing.expect(t, ok, "dial after the storm did not complete")

	// Origin is gone. The next dial must fail in the agent, log the target
	// and the error class, and close the local socket. A stuck bridge would
	// leave this read on its timeout. Wait until the accept thread has
	// left, so a connection cannot still land in its in-flight accept.
	trans.listener_close(&fx.up.ln)
	stopped_at := time.now()
	for !sync.atomic_load(&fx.up.stopped) {
		if time.since(stopped_at) > 2 * time.Second {
			testing.expect(t, false, "upstream accept did not stop")
			return
		}
		time.sleep(1 * time.Millisecond)
	}
	target := net.endpoint_to_string(up_ep, context.temp_allocator)
	refused := storm_dial(t, &ctl)
	if refused == nil {
		return
	}
	_ = trans.connection_set_recv_timeout(refused, 2 * time.Second)
	_ = trans.connection_write(refused, body[:1])
	buf: [32]u8
	_, rerr := trans.connection_read(refused, buf[:])
	trans.connection_destroy(refused)
	testing.expectf(t, rerr != .Timeout, "refused origin left the local client open (%v)", rerr)

	logged := dial_log_text()
	defer delete(logged)
	want_event := fmt.tprintf("\"event\":\"%s\"", ag.LOG_EVENT_LOCAL_DIAL_FAILED)
	want_class := fmt.tprintf("\"error_code\":\"%s\"", ag.ERROR_CLASS_NETWORK)
	testing.expect(t, strings.contains(logged, want_event), "no local_dial_failed log")
	testing.expect(t, strings.contains(logged, want_class), "dial log missing error class")
	testing.expect(t, strings.contains(logged, target), "dial log missing target")
	testing.expect(t, strings.contains(logged, "\"stream_id\":"), "dial log missing stream id")
	fmt.printf(
		"post-storm: baseline origin fds %d listen fds %d; after %d POSTs agent streams %d pumps %d caller streams %d bridges %d upstream %d origin fds %d listen fds %d; stream_not_found %d -> %d\n",
		base_up,
		base_listen,
		POST_STORM_N,
		streams,
		pumps,
		caller_streams,
		bridges,
		up_live,
		up_fds,
		listen_fds,
		base_resets,
		got_resets,
	)
}

// F1: the agent session dies (or a stream is reset and then the session
// dies) while thirp-connect has a live stream. New local clients must get
// a CONNECT once the agent is back, or a clean socket close while it is
// down. They must not sit accepted and unread (CLOSE-WAIT, Recv-Q holding
// the ClientHello) and the bridges must finish.
@(test)
test_connect_dials_after_agent_session_dies :: proc(t: ^testing.T) {
	connect_agent_death_case(t, false, false)
}

@(test)
test_connect_dials_after_stream_reset_then_agent_session_dies :: proc(t: ^testing.T) {
	connect_agent_death_case(t, true, false)
}

// Same recovery on TLS. The socket is the broker session; a fresh handshake
// does not by itself unblock a CONNECT queued behind a stuck DATA write.
@(test)
test_connect_dials_after_agent_session_dies_tls :: proc(t: ^testing.T) {
	connect_agent_death_case(t, false, true)
}

@(test)
test_connect_dials_after_stream_reset_then_agent_session_dies_tls :: proc(t: ^testing.T) {
	connect_agent_death_case(t, true, true)
}

// Writes 'X' plus a body the origin will not read, so the upload stalls in
// the broker once the agent window is full.
Upload :: struct {
	conn: ^trans.Connection,
	done: bool, // atomic
	sent: int, // atomic
	err:   trans.TransportError,
	limit: int,
}

upload_body :: proc(u: ^Upload) {
	// 16 KiB frames, not one multi-megabyte allocation (that failed under
	// parallel load and the upload looked finished before the agent was cut).
	chunk := make([]u8, 16 * 1024)
	defer delete(chunk)
	chunk[0] = 'X'
	limit := u.limit
	if limit <= 0 {
		limit = upload_block_cap()
	}
	for sync.atomic_load(&u.sent) < limit {
		u.err = trans.connection_write(u.conn, chunk)
		if u.err != .None {
			break
		}
		sync.atomic_add(&u.sent, len(chunk))
	}
	sync.atomic_store(&u.done, true)
}

// tcp_rmem / tcp_wmem autotune ceilings. A blocked upload has to be larger
// than both socket buffers or the write finishes into the kernel and the
// test never reaches the agent cut.
proc_mem_max :: proc(path: string) -> int {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil || len(data) == 0 {
		return 0
	}
	s := string(data)
	end := len(s)
	for end > 0 && (s[end - 1] == '\n' || s[end - 1] == '\r' || s[end - 1] == ' ' || s[end - 1] == '\t') {
		end -= 1
	}
	start := end
	for start > 0 && s[start - 1] >= '0' && s[start - 1] <= '9' {
		start -= 1
	}
	if start == end {
		return 0
	}
	n, pok := strconv.parse_int(s[start:end])
	if !pok || n <= 0 {
		return 0
	}
	return n
}

// Two socket pairs (local client to the bridge, caller to the broker), each
// able to hold tcp_wmem max + tcp_rmem max, plus the broker's userspace cap.
upload_block_cap :: proc() -> int {
	r := proc_mem_max("/proc/sys/net/ipv4/tcp_rmem")
	w := proc_mem_max("/proc/sys/net/ipv4/tcp_wmem")
	if r <= 0 {
		r = 16 * 1024 * 1024
	}
	if w <= 0 {
		w = 16 * 1024 * 1024
	}
	return 2 * (r + w) + 1024 * 1024
}

connect_agent_death_case :: proc(t: ^testing.T, reset_first: bool, use_tls: bool) {
	fx: Fixture
	// A 16 KiB DATA frame is over this cap, so the first frame the agent
	// actually receives resets the stream instead of being absorbed.
	agent_buf := 0
	if reset_first {
		agent_buf = 4 * 1024
	}
	if !fixture_start(t, &fx, ag.AgentConfig{max_stream_buffer = agent_buf}, use_tls) {
		return
	}
	defer fixture_stop(&fx)
	// Above one LOCAL_READ_BUF frame (a larger frame resets at once) and
	// small enough that the broker stops reading once the outbox writer
	// is held. Stopping the agent relay does not: the broker keeps
	// filling the agent's TCP window, and a few megabytes fit there.
	fx.server.max_stream_buffer = 32 * 1024

	ctl: RunControl
	args: []string
	if use_tls {
		args = []string{
			"--broker", fx.broker,
			"--tls-ca", fx.tls_cert,
			"--tls-server-name", "127.0.0.1",
			"--token", T_TOKEN_CALLER,
			"--service", T_SERVICE,
			"--listen", "127.0.0.1:0",
		}
	} else {
		args = []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	}
	r := RunArg{args = args, ctl = &ctl}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}
	base_listen := wait_port_fds_at_least(ctl.bound.port, 1, 500 * time.Millisecond)

	box := connect_agent_outbox(&fx.server)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer brk.outbox_release(box)

	held := local_dial(t, &ctl)
	if held == nil {
		return
	}
	held_open := true
	defer if held_open {
		trans.connection_destroy(held)
	}
	stream_up := false
	up_start := time.now()
	for time.since(up_start) < 2 * time.Second {
		if ctl.caller != nil && cl.caller_stream_load(ctl.caller) >= 1 {
			stream_up = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, stream_up, "stream was not up before the upload")
	if !stream_up {
		return
	}

	// Hold only after CONNECT_OK. Holding earlier queues OPEN behind the
	// writer and the dial itself never returns.
	brk.outbox_set_writer_hold(box, true)
	if ctl.caller != nil && ctl.caller.conn != nil {
		_ = net.set_option(ctl.caller.conn.socket, .Send_Buffer_Size, 16 * 1024)
	}
	_ = net.set_option(held.socket, .Send_Buffer_Size, 16 * 1024)
	// Backstop so a wedge fails the assertion instead of hanging the
	// process. The pass condition is the write finishing after the agent
	// session dies, not this timeout.
	_ = trans.connection_set_send_timeout(held, 20 * time.Second)
	up := Upload {
		conn  = held,
		limit = upload_block_cap(),
	}
	uth := thread.create_and_start_with_poly_data(&up, upload_body)
	testing.expect(t, uth != nil, "upload thread")
	if uth == nil {
		brk.outbox_set_writer_hold(box, false)
		return
	}
	defer {
		thread.join(uth)
		thread.destroy(uth)
	}
	defer brk.outbox_set_writer_hold(box, false)
	blocked := wait_upload_stalled(&up, 2 * time.Second)
	testing.expectf(
		t,
		blocked,
		"upload finished before the agent was cut (err=%v sent=%d)",
		up.err,
		sync.atomic_load(&up.sent),
	)
	if !blocked {
		sync.atomic_store(&fx.up.drop, true)
		return
	}

	if reset_first {
		// The queued frames are larger than the agent cap, so the agent
		// resets this stream once the writer is allowed to run. Then the
		// session dies.
		brk.outbox_set_writer_hold(box, false)
		reset := false
		reset_start := time.now()
		for time.since(reset_start) < 2 * time.Second {
			streams := 1
			if ctl.caller != nil {
				streams = cl.caller_stream_load(ctl.caller)
			}
			if streams == 0 || (sync.atomic_load(&up.done) && up.err != .None) {
				reset = true
				break
			}
			time.sleep(5 * time.Millisecond)
		}
		testing.expect(t, reset, "stream was not reset before the agent was cut")
		if !reset {
			sync.atomic_store(&fx.up.drop, true)
			return
		}
	}

	ag.agent_cut_broker(&fx.agent)
	sync.atomic_store(&fx.up.drop, true)

	testing.expect(t, wait_agent_down(&fx, 3 * time.Second), "agent session did not drop")
	testing.expect(t, wait_upload_finished(&up, 1 * time.Second), "caller DATA write still blocked after agent session died")
	// While the agent is down, a new client must not hang. Reconnect is
	// fast on loopback, so either a clean close or a completed echo is
	// acceptable; a read/write timeout is the field wedge.
	testing.expect(t, connect_probe(&ctl, 2 * time.Second, false), "probe hung while agent session was down")
	testing.expect(t, wait_agent_connected(&fx, 5 * time.Second), "agent did not re-register")
	testing.expect(t, connect_probe(&ctl, 2 * time.Second, true), "probe did not complete after agent re-registered")

	if held_open {
		trans.connection_destroy(held)
		held_open = false
	}
	testing.expect(t, wait_bridges_zero(&ctl, 3 * time.Second), "bridge left open after agent restart")
	streams, pumps := ag.agent_stream_load(&fx.agent)
	caller_streams := -1
	if ctl.caller != nil {
		caller_streams = cl.caller_stream_load(ctl.caller)
	}
	testing.expect_value(t, streams, 0)
	testing.expect_value(t, pumps, 0)
	testing.expect_value(t, caller_streams, 0)
	listen_fds := wait_port_fds(ctl.bound.port, base_listen, 1 * time.Second)
	testing.expectf(
		t,
		listen_fds == base_listen,
		"listen fds %d, baseline %d (accepted sockets still open)",
		listen_fds,
		base_listen,
	)
}

// DATA holds the session writer. CONNECT is the next frame after the one
// already on the socket, and the dial bound abandons that CONNECT without
// shutting the session down. The accepted local socket is closed when the
// dial returns; a later client gets a CONNECT.
@(test)
test_connect_blocked_upload_does_not_hold_connect :: proc(t: ^testing.T) {
	fx: Fixture
	if !fixture_start(t, &fx) {
		return
	}
	defer fixture_stop(&fx)
	fx.server.max_stream_buffer = 32 * 1024

	ctl: RunControl
	ctl.dial_timeout = 500 * time.Millisecond
	r := RunArg {
		args = []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"},
		ctl  = &ctl,
	}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}

	held := local_dial(t, &ctl)
	if held == nil {
		return
	}
	held_open := true
	defer if held_open {
		trans.connection_destroy(held)
	}
	_ = trans.connection_set_recv_timeout(held, 5 * time.Second)
	ping := transmute([]u8)string("Eping")
	testing.expect_value(t, trans.connection_write(held, ping), trans.TransportError.None)
	echo: [4]u8
	got := 0
	for got < 4 {
		n, rerr := trans.connection_read(held, echo[got:])
		got += n
		if rerr != .None {
			testing.expectf(t, false, "setup echo failed %v", rerr)
			return
		}
	}
	testing.expect(t, string(echo[:]) == "ping", "setup echo")

	// Hold the agent's outbox writer so the broker stops reading the caller
	// once the stream cap is full. A relay sleep does not fill a loopback
	// window before a few hundred KiB have already been accepted.
	box := connect_agent_outbox(&fx.server)
	testing.expect(t, box != nil, "agent outbox")
	if box == nil {
		return
	}
	defer brk.outbox_release(box)
	brk.outbox_set_writer_hold(box, true)
	if ctl.caller != nil && ctl.caller.conn != nil {
		_ = net.set_option(ctl.caller.conn.socket, .Send_Buffer_Size, 16 * 1024)
	}
	_ = net.set_option(held.socket, .Send_Buffer_Size, 16 * 1024)
	_ = trans.connection_set_send_timeout(held, 8 * time.Second)

	up := Upload {
		conn  = held,
		limit = upload_block_cap(),
	}
	uth := thread.create_and_start_with_poly_data(&up, upload_body)
	testing.expect(t, uth != nil, "upload thread")
	if uth == nil {
		return
	}
	defer {
		brk.outbox_set_writer_hold(box, false)
		thread.join(uth)
		thread.destroy(uth)
	}
	blocked := wait_upload_stalled(&up, 2 * time.Second)
	testing.expectf(
		t,
		blocked,
		"upload did not block (done=%v sent=%d err=%v)",
		sync.atomic_load(&up.done),
		sync.atomic_load(&up.sent),
		up.err,
	)
	if !blocked {
		return
	}

	// Old dial blocks in the CONNECT write until the DATA send returns.
	// The dial bound returns while that DATA write is still outstanding.
	testing.expect(t, connect_probe(&ctl, 2 * time.Second, false), "probe hung behind the blocked upload")

	brk.outbox_set_writer_hold(box, false)
	if ctl.caller != nil {
		ctl.caller.config.dial_timeout = 3 * time.Second
	}
	ag.agent_cut_broker(&fx.agent)
	testing.expect(t, wait_agent_down(&fx, 3 * time.Second), "agent session did not drop")
	testing.expect(t, wait_agent_connected(&fx, 5 * time.Second), "agent did not re-register")
	testing.expect(t, connect_probe(&ctl, 3 * time.Second, true), "no CONNECT after caller re-authenticated")
}

connect_agent_outbox :: proc(server: ^brk.Server) -> ^brk.ConnOutbox {
	if server == nil {
		return nil
	}
	sync.mutex_lock(&server.routing_mutex)
	conn: ^trans.Connection
	for _, c in server.agent_conns {
		conn = c
		break
	}
	sync.mutex_unlock(&server.routing_mutex)
	if conn == nil {
		return nil
	}
	return brk.server_lookup_outbox(server, conn)
}

wait_upload_blocked :: proc(u: ^Upload, limit: time.Duration) -> bool {
	start := time.now()
	for !sync.atomic_load(&u.done) {
		if time.since(start) > limit {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// True when the upload is still in progress and its byte count has stopped
// moving. A finished upload is not "blocked".
wait_upload_stalled :: proc(u: ^Upload, limit: time.Duration) -> bool {
	start := time.now()
	last := -1
	changed := time.now()
	for time.since(start) < limit {
		if sync.atomic_load(&u.done) {
			return false
		}
		sent := sync.atomic_load(&u.sent)
		if sent != last {
			last = sent
			changed = time.now()
		} else if time.since(changed) >= 200 * time.Millisecond {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return !sync.atomic_load(&u.done)
}

// tcp_port_socket_count reads /proc once. A parallel test or a close that
// has not shown up yet makes a single sample lie (listen fds 1, baseline 0).
wait_port_fds_at_least :: proc(port: int, n: int, limit: time.Duration) -> int {
	start := time.now()
	last := tcp_port_socket_count(port)
	for last < n && time.since(start) < limit {
		time.sleep(5 * time.Millisecond)
		last = tcp_port_socket_count(port)
	}
	return last
}

wait_port_fds :: proc(port: int, want: int, limit: time.Duration) -> int {
	start := time.now()
	last := tcp_port_socket_count(port)
	for last != want && time.since(start) < limit {
		time.sleep(10 * time.Millisecond)
		last = tcp_port_socket_count(port)
	}
	return last
}

wait_upload_finished :: proc(u: ^Upload, limit: time.Duration) -> bool {
	start := time.now()
	for !sync.atomic_load(&u.done) {
		if time.since(start) > limit {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

wait_agent_down :: proc(fx: ^Fixture, limit: time.Duration) -> bool {
	start := time.now()
	for ag.agent_is_connected(&fx.agent) {
		if time.since(start) > limit {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

wait_agent_connected :: proc(fx: ^Fixture, limit: time.Duration) -> bool {
	start := time.now()
	for !ag.agent_is_connected(&fx.agent) {
		if time.since(start) > limit {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

wait_upstream_live :: proc(fx: ^Fixture, n: int, limit: time.Duration) -> bool {
	start := time.now()
	for sync.atomic_load(&fx.up.live) < n {
		if time.since(start) > limit {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return true
}

// One local client. While the agent is down, a clean socket close counts:
// the bridge accepted the client and finished the dial with a failure.
// After the agent is back, the echo itself has to arrive. A read or write
// timeout means the bridge accepted the socket and never finished the dial.
connect_probe :: proc(ctl: ^RunControl, limit: time.Duration, need_echo: bool) -> bool {
	conn, err := trans.connection_dial(ctl.bound)
	if err != .None || conn == nil {
		return false
	}
	defer trans.connection_destroy(conn)
	_ = trans.connection_set_send_timeout(conn, limit)
	_ = trans.connection_set_recv_timeout(conn, limit)
	payload := transmute([]u8)string("Eping")
	werr := trans.connection_write(conn, payload)
	if werr == .Timeout {
		return false
	}
	if werr != .None {
		return !need_echo
	}
	buf: [16]u8
	got := 0
	for got < 4 {
		n, rerr := trans.connection_read(conn, buf[got:])
		got += n
		if rerr == .Timeout {
			return false
		}
		if rerr != .None {
			return !need_echo
		}
	}
	return string(buf[:4]) == "ping"
}

storm_dial :: proc(t: ^testing.T, ctl: ^RunControl, loc := #caller_location) -> ^trans.Connection {
	conn, err := trans.connection_dial(ctl.bound)
	testing.expect_value(t, err, trans.TransportError.None, loc)
	if conn != nil {
		_ = trans.connection_set_recv_timeout(conn, 2 * time.Second)
	}
	return conn
}

storm_load :: proc(
	fx: ^Fixture,
	ctl: ^RunControl,
	up_port, listen_port: int,
) -> (
	streams, pumps, caller_streams, bridges, up_live, up_fds, listen_fds: int,
) {
	streams, pumps = ag.agent_stream_load(&fx.agent)
	if ctl.caller != nil {
		caller_streams = cl.caller_stream_load(ctl.caller)
	} else {
		caller_streams = -1
	}
	bridges = sync.atomic_load(&ctl.live_bridges)
	up_live = sync.atomic_load(&fx.up.live)
	up_fds = tcp_port_socket_count(up_port)
	listen_fds = tcp_port_socket_count(listen_port)
	return
}

// Cut the caller's broker-side TCP socket, leaving the agent and listener
// running. A new accepted socket must wait for the replacement session.
@(test)
test_connect_new_local_socket_after_broker_session_loss :: proc(t: ^testing.T) {
	connect_broker_session_loss_case(t, false)
}

@(test)
test_connect_new_local_socket_after_broker_session_loss_tls :: proc(t: ^testing.T) {
	connect_broker_session_loss_case(t, true)
}

connect_broker_session_loss_case :: proc(t: ^testing.T, use_tls: bool) {
	fx: Fixture
	if !fixture_start(t, &fx, {}, use_tls) {
		return
	}
	defer fixture_stop(&fx)
	ctl: RunControl
	r := RunArg {
		args = []string{"--broker", fx.broker, "--insecure", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"},
		ctl = &ctl,
	}
	if use_tls {
		r.args = []string{"--broker", fx.broker, "--tls-ca", fx.tls_cert, "--tls-server-name", "127.0.0.1", "--token", T_TOKEN_CALLER, "--service", T_SERVICE, "--listen", "127.0.0.1:0"}
	}
	th := start_connect(t, &r)
	defer stop_connect(&r, th)
	if !sync.atomic_load(&ctl.ready) {
		testing.expect(t, false, "not ready")
		return
	}
	testing.expect(t, connect_probe(&ctl, 3 * time.Second, true), "initial echo failed")
	sync.mutex_lock(&ctl.caller.mutex)
	gen := ctl.caller.conn_gen
	sync.mutex_unlock(&ctl.caller.mutex)
	cut := false
	sync.mutex_lock(&fx.server.handlers_mutex)
	for h in fx.server.handlers {
		if h.role == .Caller {
			trans.connection_shutdown_both(h.conn)
			cut = true
		}
	}
	sync.mutex_unlock(&fx.server.handlers_mutex)
	testing.expect(t, cut, "no broker-side caller socket")
	if !cut {
		return
	}
	// Observe the loss before probing, so the new socket is accepted
	// during reconnect rather than on the old session before its FIN.
	lost := false
	start := time.now()
	for time.since(start) < 3 * time.Second {
		sync.mutex_lock(&ctl.caller.mutex)
		lost = !ctl.caller.connected
		sync.mutex_unlock(&ctl.caller.mutex)
		if lost {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, lost, "caller did not observe session loss")
	testing.expect(t, connect_probe(&ctl, 3 * time.Second, true), "new socket failed during reconnect")
	sync.mutex_lock(&ctl.caller.mutex)
	replaced := ctl.caller.connected && ctl.caller.conn_gen != gen
	sync.mutex_unlock(&ctl.caller.mutex)
	testing.expect(t, replaced, "caller did not install a live replacement")
	testing.expect(t, connect_probe(&ctl, 3 * time.Second, true), "new socket failed after reconnect")
}
