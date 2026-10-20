// Package connect is the thirp-connect command body. It lives outside
// package main so `odin test . -all-packages` can drive the real flag
// parsing, broker login, listener and bridges in-process.
package connect

import auth "../../auth"
import cl "../../caller"
import log "../../logging"
import proto "../../protocol"
import trans "../../transport"
import ver "../../version"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

LOCAL_READ_BUF :: 16 * 1024
ACCEPT_POLL :: 50 * time.Millisecond
// After the peer ends a stream early (e.g. a 403 while the client is still
// sending), keep draining the client's request bytes this long so closing
// the socket does not RST away the response it has not read yet.
LOCAL_LINGER :: 2 * time.Second
// Local reads poll this often so a bridge can be stopped without relying on
// shutdown() from another thread waking a blocked recv (not promised on
// Windows).
LOCAL_POLL :: 100 * time.Millisecond
// Concurrent local connections. One thread pair each; the broker's default
// streams-per-session limit is the same.
MAX_BRIDGES :: 256
// After an accept failure, how long bridges get to finish before the
// process exits without tearing the session down under them.
STOP_GRACE :: 2 * time.Second

// Test hook. Production passes nil and the accept loop runs until it fails.
RunControl :: struct {
	stop:                 bool, // atomic: end the accept loop
	ready:                bool, // atomic: listening and logged in
	bound:                net.Endpoint,
	live_bridges:         int, // atomic
	// Overrides --stream-stall-timeout when non-zero; negative = never.
	stream_stall_timeout: time.Duration,
	// Overrides --max-stream-buffer-mib when non-zero (bytes).
	max_stream_buffer:    int,
}

usage :: proc() {
	fmt.eprintf(
		"usage: thirp-connect [--version] --broker HOST:PORT (--token TOKEN | --token-file PATH) --service SERVICE_ID --listen HOST:PORT\n" +
		"       [--tls-ca PATH] [--tls-server-name NAME | --insecure]\n" +
		"       [--stream-stall-timeout SECONDS]   (default 30; 0 = never; bounds writes to a local client)\n" +
		"       [--max-stream-buffer-mib N]        (1..1048576, default 8; a download further behind is reset)\n",
	)
}

Run :: struct {
	c:          cl.Caller,
	service_id: proto.ServiceId,
	ctl:        ^RunControl,
	mutex:      sync.Mutex,
	bridges:    [dynamic]^BridgeArg,
	live:       int, // atomic; bridges not yet finished (also counted in ctl)
	stall:      time.Duration, // per-stream no-progress limit; 0 = never
}

connect_main :: proc(args: []string, ctl: ^RunControl = nil) -> int {
	broker := ""
	token := ""
	token_file := ""
	service := ""
	listen := ""
	insecure := false
	tls_ca := ""
	tls_server_name := ""
	stall_secs := int(cl.DEFAULT_STREAM_STALL_TIMEOUT / time.Second)
	buffer_mib := 0 // 0 = library default (8 MiB)

	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--insecure":
			insecure = true
		case "--tls-ca":
			if i + 1 >= len(args) {
				fmt.eprintf("--tls-ca requires PATH\n")
				usage()
				return 1
			}
			i += 1
			tls_ca = args[i]
		case "--tls-server-name":
			if i + 1 >= len(args) {
				fmt.eprintf("--tls-server-name requires NAME\n")
				usage()
				return 1
			}
			i += 1
			tls_server_name = args[i]
		case "--broker":
			if i + 1 >= len(args) {
				fmt.eprintf("--broker requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			broker = args[i]
		case "--token":
			if i + 1 >= len(args) {
				fmt.eprintf("--token requires TOKEN\n")
				usage()
				return 1
			}
			i += 1
			token = args[i]
		case "--token-file":
			if i + 1 >= len(args) {
				fmt.eprintf("--token-file requires PATH\n")
				usage()
				return 1
			}
			i += 1
			token_file = args[i]
		case "--service":
			if i + 1 >= len(args) {
				fmt.eprintf("--service requires SERVICE_ID\n")
				usage()
				return 1
			}
			i += 1
			service = args[i]
		case "--listen":
			if i + 1 >= len(args) {
				fmt.eprintf("--listen requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			listen = args[i]
		case "--stream-stall-timeout":
			if i + 1 >= len(args) {
				fmt.eprintf("--stream-stall-timeout requires SECONDS\n")
				usage()
				return 1
			}
			i += 1
			v, vok := strconv.parse_int(args[i], 10)
			if !vok || v < 0 || v > 86400 {
				fmt.eprintf("--stream-stall-timeout must be 0..86400 seconds\n")
				return 1
			}
			stall_secs = v
		case "--max-stream-buffer-mib":
			if i + 1 >= len(args) {
				fmt.eprintf("--max-stream-buffer-mib requires N\n")
				usage()
				return 1
			}
			i += 1
			v, vok := strconv.parse_int(args[i], 10)
			if !vok || v < 1 || v > 1 << 20 {
				fmt.eprintf("--max-stream-buffer-mib must be an integer in 1..1048576\n")
				return 1
			}
			buffer_mib = v
		case "--version":
			line := ver.version_line("thirp-connect")
			fmt.printf("%s\n", line)
			delete(line)
			return 0
		case "-h", "--help":
			usage()
			return 0
		case:
			fmt.eprintf("unknown flag: %s\n", args[i])
			usage()
			return 1
		}
	}

	if insecure && (len(tls_ca) > 0 || len(tls_server_name) > 0) {
		fmt.eprintf("--insecure cannot be combined with --tls-ca or --tls-server-name\n")
		return 1
	}
	if len(broker) == 0 || len(service) == 0 || len(listen) == 0 {
		fmt.eprintf("--broker, --service, and --listen are required\n")
		usage()
		return 1
	}
	if (len(token) == 0) == (len(token_file) == 0) {
		fmt.eprintf("exactly one of --token or --token-file is required\n")
		usage()
		return 1
	}
	// The file token must outlive caller_init's handshake. It used to be
	// freed by a `defer delete` scoped to the `if` block below, so the
	// broker received freed bytes and rejected the login.
	file_token := ""
	defer if len(file_token) > 0 {
		delete(file_token)
	}
	if len(token_file) > 0 {
		if auth.file_group_or_world_readable(token_file) {
			fmt.eprintf("WARNING: token file is group- or world-readable; prefer mode 0600\n")
		}
		secret, serr := auth.read_secret_file(token_file)
		if serr != .None {
			fmt.eprintf("failed to read --token-file\n")
			return 1
		}
		file_token = secret
		token = file_token
	}

	service_id, sid_err := proto.make_service_id(service)
	if sid_err != .None {
		fmt.eprintf("invalid service id\n")
		return 1
	}

	broker_ep, berr := trans.resolve_endpoint(broker)
	if berr != .None {
		fmt.eprintf("invalid --broker address\n")
		return 1
	}
	if !insecure && len(tls_server_name) == 0 {
		if host, hok := trans.endpoint_host(broker); hok {
			tls_server_name = host
		}
	}
	listen_ep, lerr := trans.parse_endpoint(listen)
	if lerr != .None {
		fmt.eprintf("invalid --listen address\n")
		return 1
	}
	if !endpoint_is_loopback(listen_ep) {
		fmt.eprintf("WARNING: --listen is not loopback; any host that can reach this address can use the bridge\n")
	}

	// Bind before logging in: a busy port fails fast with no broker
	// session (and no session teardown) behind it.
	ln, lmsg, lok := listen_local(listen_ep)
	if !lok {
		fmt.eprintf("listen failed on %s: %s\n", listen, lmsg)
		return 1
	}
	defer trans.listener_close(&ln)

	logger: log.Logger
	log.logger_init(&logger, .Info)

	impl := ver.version_line("thirp-connect")
	defer delete(impl)
	run := new(Run)
	defer free(run)
	run.service_id = service_id
	run.ctl = ctl
	run.bridges = make([dynamic]^BridgeArg)
	defer delete(run.bridges)
	// How long a write to the local client may take no bytes. 0 = never.
	// The session reader never waits: a download whose backlog would pass
	// the per-stream buffer is reset at once.
	run.stall = time.Duration(stall_secs) * time.Second
	if ctl != nil && ctl.stream_stall_timeout != 0 {
		run.stall = max(ctl.stream_stall_timeout, 0)
	}
	stream_buffer := buffer_mib * 1024 * 1024
	if ctl != nil && ctl.max_stream_buffer != 0 {
		stream_buffer = ctl.max_stream_buffer
	}
	cerr := cl.caller_init(
		&run.c,
		cl.CallerConfig {
			broker               = broker_ep,
			token                = token,
			insecure             = insecure,
			tls_ca               = tls_ca,
			tls_server_name      = tls_server_name,
			implementation       = impl,
			logger               = &logger,
			max_stream_buffer    = stream_buffer,
		},
	)
	if cerr != .None {
		fmt.eprintf("broker dial failed\n")
		return 1
	}
	defer cl.caller_destroy(&run.c)

	bound, _ := trans.listener_endpoint(ln)
	fmt.printf("thirp-connect listening on %s for %s\n", net.endpoint_to_string(bound), service)
	if ctl != nil {
		ctl.bound = bound
		_ = trans.listener_set_recv_timeout(&ln, ACCEPT_POLL)
		sync.atomic_store(&ctl.ready, true)
	}

	for {
		if ctl != nil && sync.atomic_load(&ctl.stop) {
			_ = run_stop_bridges(run, 0)
			return 0
		}
		// The stop flag must be seen on every OS: Windows ignores SO_RCVTIMEO
		// on accept(), so poll for a pending connection first.
		if ctl != nil && trans.listener_wait_acceptable(&ln, ACCEPT_POLL) == .Timeout {
			continue
		}
		local, aerr := trans.listener_accept(&ln)
		if aerr == .Timeout {
			continue
		}
		if aerr != .None {
			fmt.eprintf("accept failed on %s\n", listen)
			// A bridge still waiting on CONNECT_OK must not keep the process
			// alive (the release exited at once here). If one is still
			// running after the grace, exit now: every defer here (session,
			// run, listener) would free state that bridge still uses.
			grace := STOP_GRACE if ctl == nil else 0
			if !run_stop_bridges(run, grace) {
				os.exit(1)
			}
			return 1
		}
		if sync.atomic_load(&run.live) >= MAX_BRIDGES {
			fmt.eprintf("thirp-connect: %d connections open; refusing another\n", MAX_BRIDGES)
			trans.connection_destroy(local)
			continue
		}
		// Dial on the bridge thread. Dialing here let one unanswered
		// CONNECT stop the accept loop; later clients then sat in the
		// listen backlog until they gave up (CLOSE-WAIT).
		arg, nerr := new(BridgeArg)
		if nerr != .None {
			trans.connection_destroy(local)
			continue
		}
		// Accepted sockets inherit the listener's poll timeout on Linux.
		_ = trans.connection_set_recv_timeout(local, 0)
		// Bound stream->client writes the same way the session bounds a
		// stalled stream: a write fails only after the client took no bytes
		// for the stall timeout (0 = never), so a client that stops reading
		// ends its own bridge instead of pinning it.
		_ = trans.connection_set_send_timeout(local, run.stall)
		arg.run = run
		arg.local = local
		run_track(run, arg)
		if thread.create_and_start_with_poly_data(arg, bridge_local, self_cleanup = true) == nil {
			run_untrack(run, arg)
			trans.connection_destroy(local)
			free(arg)
			run_bridge_done(run)
		}
	}
}

listen_local :: proc(ep: net.Endpoint) -> (trans.Listener, string, bool) {
	sock, err := net.listen_tcp(ep)
	if err == nil {
		return trans.Listener{socket = sock}, "", true
	}
	if be, is_bind := err.(net.Bind_Error); is_bind {
		#partial switch be {
		case .Address_In_Use:
			return {}, "address already in use", false
		case .Insufficient_Permissions_For_Address:
			return {}, "permission denied", false
		case .Invalid_Argument:
			return {}, "invalid address", false
		}
	}
	return {}, "cannot bind", false
}

run_track :: proc(run: ^Run, b: ^BridgeArg) {
	sync.mutex_lock(&run.mutex)
	append(&run.bridges, b)
	sync.mutex_unlock(&run.mutex)
	sync.atomic_add(&run.live, 1)
	if run.ctl != nil {
		sync.atomic_add(&run.ctl.live_bridges, 1)
	}
}

run_untrack :: proc(run: ^Run, b: ^BridgeArg) {
	sync.mutex_lock(&run.mutex)
	for i := 0; i < len(run.bridges); i += 1 {
		if run.bridges[i] == b {
			unordered_remove(&run.bridges, i)
			break
		}
	}
	sync.mutex_unlock(&run.mutex)
}

run_bridge_done :: proc(run: ^Run) {
	if run.ctl != nil {
		sync.atomic_sub(&run.ctl.live_bridges, 1)
	}
	sync.atomic_sub(&run.live, 1)
}

// Ask every bridge to stop, then wait for them before caller_destroy frees
// the session they use. The stop flag is what ends a bridge: its local
// reads poll it every LOCAL_POLL. shutdown() is only a faster wake where
// the OS honours it. The kick also ends the bridge's stream, so a pump
// waiting on a reply (after the client half-closed) wakes too. grace <= 0
// waits for all; otherwise returns false if some bridge (e.g. one still
// dialing) has not finished in time.
run_stop_bridges :: proc(run: ^Run, grace: time.Duration) -> (all_done: bool) {
	sync.mutex_lock(&run.mutex)
	for b in run.bridges {
		bridge_kick(b)
	}
	sync.mutex_unlock(&run.mutex)
	start := time.now()
	for sync.atomic_load(&run.live) != 0 {
		if grace > 0 && time.since(start) >= grace {
			return false
		}
		time.sleep(1 * time.Millisecond)
	}
	return true
}

BridgeArg :: struct {
	run:    ^Run,
	local:  ^trans.Connection,
	kick:   bool, // atomic: stop this bridge
	// Set and cleared under run.mutex, while the bridge owns the stream
	// (from dial until just before conn_destroy).
	stream: ^cl.Conn,
}

// Stops a bridge: flags it, wakes its local reads, and ends its stream so a
// pump in conn_read (waiting on a reply after the client's half-close)
// returns as well. conn_close is a no-op on a stream that already ended.
// Callers hold run.mutex, or are the bridge's own pump (which runs only
// while the stream is set).
bridge_kick :: proc(b: ^BridgeArg) {
	sync.atomic_store(&b.kick, true)
	trans.connection_shutdown_both(b.local)
	if b.stream != nil {
		cl.conn_close(b.stream)
	}
}

// Hands the dialed stream to the bridge so a kick can end it. False if the
// bridge was kicked first (the caller then destroys the stream itself).
bridge_set_stream :: proc(b: ^BridgeArg, stream: ^cl.Conn) -> bool {
	sync.mutex_lock(&b.run.mutex)
	defer sync.mutex_unlock(&b.run.mutex)
	if sync.atomic_load(&b.kick) {
		return false
	}
	b.stream = stream
	return true
}

bridge_clear_stream :: proc(b: ^BridgeArg) {
	sync.mutex_lock(&b.run.mutex)
	b.stream = nil
	sync.mutex_unlock(&b.run.mutex)
}

BridgePump :: struct {
	bridge:    ^BridgeArg,
	local:     ^trans.Connection,
	stream:    ^cl.Conn,
	main_done: sync.Sema, // posted when the client->stream side has stopped
	linger:    time.Duration,
}

// Reads from the local client, polling the bridge's stop flag. Returns
// .Closed on EOF, like connection_read.
bridge_read_local :: proc(b: ^BridgeArg, buf: []u8) -> (int, trans.TransportError) {
	for {
		if sync.atomic_load(&b.kick) {
			return 0, .Network
		}
		werr := trans.connection_wait_readable(b.local, LOCAL_POLL)
		if sync.atomic_load(&b.kick) {
			return 0, .Network
		}
		if werr == .Timeout {
			continue
		}
		if werr != .None {
			return 0, werr
		}
		return trans.connection_read(b.local, buf)
	}
}

// One local client. The stream ends when both directions are done (local
// EOF sent as HALF_CLOSE and the peer's HALF_CLOSE received), or at once on
// the peer's CLOSE/RESET or any error. Every end closes the local socket.
bridge_local :: proc(arg: ^BridgeArg) {
	run := arg.run
	local := arg.local
	defer {
		run_untrack(run, arg)
		trans.connection_shutdown_both(local)
		trans.connection_destroy(local)
		free(arg)
		run_bridge_done(run)
	}
	stream, derr := cl.dial(&run.c, run.service_id)
	if derr != .None {
		fmt.eprintf("connect failed\n")
		return
	}
	if !bridge_set_stream(arg, stream) {
		cl.conn_destroy(stream)
		return
	}
	pump: BridgePump
	pump.bridge = arg
	pump.local = local
	pump.stream = stream
	pump.linger = LOCAL_LINGER
	th := thread.create_and_start_with_poly_data(&pump, bridge_conn_to_local)
	if th == nil {
		// Nothing would drain the stream: end it now.
		fmt.eprintf("thirp-connect: cannot start bridge thread\n")
		bridge_clear_stream(arg)
		cl.conn_destroy(stream)
		return
	}
	buf: [LOCAL_READ_BUF]u8
	local_eof := false
	draining := false
	for {
		n, err := bridge_read_local(arg, buf[:])
		if err == .Closed {
			local_eof = true
			break
		}
		if err != .None {
			break
		}
		if draining {
			continue
		}
		_, werr := cl.conn_write(stream, buf[:n])
		if werr != .None {
			if cl.conn_finished(stream) {
				// Peer answered and ended the stream while the client is
				// still sending. Discard the rest; the pump bounds this.
				draining = true
				continue
			}
			break
		}
	}
	sync.sema_post(&pump.main_done)
	if local_eof && !cl.conn_finished(stream) {
		// Client finished sending. Keep the response direction open.
		cl.conn_half_close(stream)
	} else {
		cl.conn_close(stream)
	}
	thread.join(th)
	thread.destroy(th)
	bridge_clear_stream(arg)
	cl.conn_destroy(stream)
}

bridge_conn_to_local :: proc(p: ^BridgePump) {
	buf: [LOCAL_READ_BUF]u8
	for {
		n, err := cl.conn_read(p.stream, buf[:])
		if err != .None {
			break
		}
		if trans.connection_write(p.local, buf[:n]) != .None {
			// Client is gone: end the stream and wake the reader side.
			cl.conn_close(p.stream)
			bridge_kick(p.bridge)
			return
		}
	}
	if !cl.conn_finished(p.stream) {
		// Peer HALF_CLOSE: pass EOF to the client, then wait for the
		// stream to end (peer CLOSE/RESET, or our own half-close).
		_ = trans.connection_shutdown_write(p.local)
		if !cl.conn_wait_done(p.stream) {
			// Both directions half-closed: the stream is complete, and the
			// broker already ended it on the second HALF_CLOSE. A CLOSE
			// now would only earn a StreamNotFound RESET.
			cl.conn_end_local(p.stream)
			return
		}
	}
	// Peer CLOSE/RESET (or closed locally). Send EOF after what was
	// delivered, give the client side a bounded linger to finish, then
	// tear the local socket down in both directions so the reader side
	// can never sit on a half-open client.
	_ = trans.connection_shutdown_write(p.local)
	if !sync.sema_wait_with_timeout(&p.main_done, p.linger) {
		bridge_kick(p.bridge)
	}
}

endpoint_is_loopback :: proc(ep: net.Endpoint) -> bool {
	switch a in ep.address {
	case net.IP4_Address:
		return a[0] == 127
	case net.IP6_Address:
		return a == net.IP6_Loopback
	}
	return false
}
