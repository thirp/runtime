package caller

import trans "../transport"
import proto "../protocol"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

SetupHang :: struct {
	listener: ^trans.Listener,
	mutex: sync.Mutex,
	cond: sync.Cond,
	stop: bool,
	accepted: bool,
	hello_delay: time.Duration,
	admit: bool,
}

setup_hang_peer :: proc(p: ^SetupHang) {
	// Bounded accept lets fixture cleanup work even if the client cannot dial.
	if trans.listener_wait_acceptable(p.listener, 2*time.Second) != .None {return}
	conn, err := trans.listener_accept(p.listener)
	if err != .None {return}
	defer trans.connection_destroy(conn)
	if p.hello_delay > 0 || p.admit {
		_ = trans.connection_set_recv_timeout(conn, time.Second)
		decoder: proto.FrameDecoder
		_ = proto.decoder_init(&decoder)
		defer proto.decoder_destroy(&decoder)
		hello, _, _ := trans.read_frame(conn, &decoder)
		proto.frame_destroy(&hello)
		if p.hello_delay > 0 {time.sleep(p.hello_delay)}
		payload, _ := proto.encode_hello_ack({major = proto.PROTOCOL_MAJOR, minor = proto.PROTOCOL_MINOR, implementation = "setup-fixture"})
		_, _ = trans.write_frame(conn, .HelloAck, payload)
		delete(payload)
		auth, _, _ := trans.read_frame(conn, &decoder)
		proto.frame_destroy(&auth)
		if p.admit {
			ok, _ := proto.encode_authenticate_ok({principal_id = "setup-fixture"})
			_, _ = trans.write_frame(conn, .AuthenticateOk, ok)
			delete(ok)
		}
	}
	sync.mutex_lock(&p.mutex)
	p.accepted = true
	for !p.stop {sync.cond_wait(&p.cond, &p.mutex)}
	sync.mutex_unlock(&p.mutex)
}

@(test)
test_broker_setup_accept_then_hang :: proc(t: ^testing.T) {
	for mode in 0..<3 {
		insecure := mode != 1
		ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
		testing.expect_value(t, lerr, trans.TransportError.None)
		if lerr != .None {return}
		ep, _ := trans.listener_endpoint(ln)
		p := SetupHang{listener = &ln}
		if mode == 2 {p.hello_delay = 300*time.Millisecond}
		th := thread.create_and_start_with_poly_data(&p, setup_hang_peer)
		testing.expect(t, th != nil)
		if th == nil {trans.listener_close(&ln); return}
		c: Caller
		start := time.now()
		err := caller_init(&c, {broker = ep, token = TEST_TOKEN_CALLER, insecure = insecure,
			tls_server_name = insecure ? "" : "localhost", dial_timeout = 500*time.Millisecond})
		elapsed := time.since(start)
		if err == .None {caller_destroy(&c)}
		sync.mutex_lock(&p.mutex)
		p.stop = true
		sync.cond_signal(&p.cond)
		sync.mutex_unlock(&p.mutex)
		thread.join(th); thread.destroy(th)
		trans.listener_close(&ln)
		testing.expect(t, p.accepted, "fixture accepted TCP")
		testing.expect_value(t, err, CallerError.Timeout)
		testing.expect(t, elapsed >= 450*time.Millisecond && elapsed < time.Second, "whole setup must respect 500ms deadline")
		if mode == 2 {testing.expect(t, elapsed < 700*time.Millisecond, "Hello and Authenticate share one deadline")}
	}
}

@(test)
test_broker_setup_honors_earlier_deadline :: proc(t: ^testing.T) {
	c: Caller
	err := caller_init(&c, {
		broker = trans.loopback_endpoint(1), token = TEST_TOKEN_CALLER, insecure = true,
		dial_timeout = DEFAULT_DIAL_TIMEOUT, setup_deadline = time.time_add(time.now(), -time.Millisecond),
	})
	if err == .None {caller_destroy(&c)}
	testing.expect_value(t, err, CallerError.Timeout)
}

SetupReconnect :: struct {caller: ^Caller, done, admitted: bool}

setup_reconnect_run :: proc(r: ^SetupReconnect) {
	attempt: int
	r.admitted = caller_reconnect(r.caller, &attempt)
	sync.atomic_store(&r.done, true)
}

@(test)
test_reconnect_setup_does_not_wait_for_session_writer :: proc(t: ^testing.T) {
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	if !testing.expect_value(t, lerr, trans.TransportError.None) {return}
	defer trans.listener_close(&ln)
	ep, _ := trans.listener_endpoint(ln)
	peer := SetupHang{listener = &ln, admit = true}
	peer_th := thread.create_and_start_with_poly_data(&peer, setup_hang_peer)
	if !testing.expect(t, peer_th != nil) {return}
	defer {
		sync.mutex_lock(&peer.mutex)
		peer.stop = true
		sync.cond_signal(&peer.cond)
		sync.mutex_unlock(&peer.mutex)
		thread.join(peer_th); thread.destroy(peer_th)
	}
	c := Caller{config = {broker = ep, token = strings.clone(TEST_TOKEN_CALLER), insecure = true, dial_timeout = time.Second}}
	defer caller_destroy(&c)
	// Model a writer still occupied by a retired session's DATA write.
	release: sync.Sema
	c.writer = thread.create_and_start_with_poly_data(&release, proc(s: ^sync.Sema) {sync.sema_wait(s)})
	if !testing.expect(t, c.writer != nil) {return}
	defer sync.sema_post(&release)
	r := SetupReconnect{caller = &c}
	th := thread.create_and_start_with_poly_data(&r, setup_reconnect_run)
	if !testing.expect(t, th != nil) {return}
	defer {
		sync.atomic_store(&c.stop, true)
		caller_fail_queued(&c)
		thread.join(th); thread.destroy(th)
	}
	start := time.tick_now()
	for !sync.atomic_load(&r.done) && time.tick_since(start) < 2*time.Second {time.sleep(5*time.Millisecond)}
	if testing.expect(t, sync.atomic_load(&r.done), "broker setup waited for the previous session writer") {
		testing.expect(t, r.admitted, "reconnect authenticated while the session writer was held")
	}
}

@(test)
test_broker_setup_tls_zero_and_cleared_deadline :: proc(t: ^testing.T) {
	cert, cok := caller_write_temp_pem("setup-cert", CALLER_TEST_CERT)
	key, kok := caller_write_temp_pem("setup-key", CALLER_TEST_KEY)
	testing.expect(t, cok && kok)
	if !cok || !kok {return}
	defer {os.remove(cert); os.remove(key); delete(cert); delete(key)}
	ctx, terr := trans.tls_server_context_init(cert, key)
	testing.expect_value(t, terr, trans.TransportError.None)
	if terr != .None {return}
	fx: TestBroker
	start_test_broker(t, &fx, tls_ctx = ctx)
	defer stop_test_broker(&fx)
	ep := broker_endpoint(t, &fx)
	if ep.port == 0 {return}
	for bound in ([]time.Duration{0, 500*time.Millisecond}) {
		c: Caller
		err := caller_init(&c, {broker = ep, token = TEST_TOKEN_CALLER, tls_ca = cert, tls_server_name = "127.0.0.1", dial_timeout = bound})
		testing.expect_value(t, err, CallerError.None)
		if err != .None {continue}
		gen := caller_conn_gen(&c)
		time.sleep(1500*time.Millisecond)
		testing.expect(t, caller_is_connected(&c))
		testing.expect_value(t, caller_conn_gen(&c), gen)
		sync.mutex_lock(&c.mutex)
		testing.expect(t, c.conn != nil)
		if c.conn != nil {testing.expect_value(t, c.conn.send_timeout, time.Duration(0))}
		sync.mutex_unlock(&c.mutex)
		caller_destroy(&c)
	}
}

@(test)
test_broker_setup_zero_and_cleared_deadline :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)
	ep := broker_endpoint(t, &fx)
	if ep.port == 0 {return}
	for bound in ([]time.Duration{0, 500*time.Millisecond}) {
		c: Caller
		err := caller_init(&c, {broker = ep, token = TEST_TOKEN_CALLER, insecure = true, dial_timeout = bound})
		testing.expect_value(t, err, CallerError.None)
		if err != .None {continue}
		gen := caller_conn_gen(&c)
		// Broker heartbeat is 30s. This exceeds the setup deadline by 3x
		// without any received frame that could conceal a lingering timer.
		time.sleep(1500*time.Millisecond)
		testing.expect(t, caller_is_connected(&c))
		testing.expect_value(t, caller_conn_gen(&c), gen)
		sync.mutex_lock(&c.mutex)
		testing.expect(t, c.conn != nil)
		if c.conn != nil {testing.expect_value(t, c.conn.send_timeout, time.Duration(0))}
		sync.mutex_unlock(&c.mutex)
		caller_destroy(&c)
	}
}
