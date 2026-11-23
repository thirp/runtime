package caller

import ag "../agent"
import auth "../auth"
import brk "../broker"
import log "../logging"
import trans "../transport"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Test-only PEMs. The new leaf requires an intermediate sent by the broker.
RELOAD_TEST_CHAIN :: string(#load("../transport/testdata/reload_chain.crt"))
RELOAD_TEST_KEY :: string(#load("../transport/testdata/reload_server.key"))
RELOAD_TEST_ROOT :: string(#load("../transport/testdata/reload_root.crt"))
RELOAD_TEST_BAD_CONSTRAINTS :: string(#load("../transport/testdata/reload_intermediate_bad_constraints.crt"))
RELOAD_TEST_TRAILING_DER :: string(#load("../transport/testdata/reload_intermediate_trailing_bytes.crt"))
RELOAD_TEST_NUL_BODY :: string(#load("../transport/testdata/reload_intermediate_nul.crt"))
RELOAD_TEST_BAD_NOT_BEFORE :: string(#load("../transport/testdata/reload_intermediate_bad_not_before.crt"))
RELOAD_TEST_BAD_NOT_AFTER :: string(#load("../transport/testdata/reload_intermediate_bad_not_after.crt"))
RELOAD_TEST_MISMATCHED_SIGNATURE :: string(#load("../transport/testdata/reload_intermediate_mismatched_signature.crt"))
RELOAD_TEST_INVERTED_INTERVAL :: string(#load("../transport/testdata/reload_inverted_interval_chain.crt"))
RELOAD_TEST_CLIENT_ISSUER :: string(#load("../transport/testdata/reload_client_issuer_chain.crt"))
RELOAD_TEST_INCONSISTENT_KEY :: string(#load("../transport/testdata/reload_inconsistent.key"))

reload_test_failures: int
reload_test_successes: int
reload_test_completed: sync.Sema

reload_test_log :: proc(text: string) {
	if strings.contains(text, "\"event\":\"" + brk.LOG_EVENT_TLS_RELOAD_FAILED + "\"") {
		sync.atomic_add(&reload_test_failures, 1)
		sync.sema_post(&reload_test_completed)
	} else if strings.contains(text, "\"event\":\"" + brk.LOG_EVENT_TLS_RELOADED + "\"") {
		sync.atomic_add(&reload_test_successes, 1)
		sync.sema_post(&reload_test_completed)
	}
}

reload_test_publish :: proc(t: ^testing.T, request, line: string, successes, failures: int, loc := #caller_location) -> bool {
	if !testing.expect(t, os.write_entire_file_from_string(request, line) == nil, loc = loc) {
		return false
	}
	if !testing.expect(t, sync.sema_wait_with_timeout(&reload_test_completed, 5 * time.Second),
	                   "running watcher did not handle the reload request", loc = loc) {
		return false
	}
	success_ok := testing.expect_value(t, sync.atomic_load(&reload_test_successes), successes, loc)
	failure_ok := testing.expect_value(t, sync.atomic_load(&reload_test_failures), failures, loc)
	return success_ok && failure_ok
}

reload_test_handshake :: proc(t: ^testing.T, ep: net.Endpoint, ca: string, expected: trans.TransportError, loc := #caller_location) {
	conn, err := trans.connection_dial_tls(ep, {ca_path = ca, server_name = "127.0.0.1"})
	defer trans.connection_destroy(conn)
	testing.expect_value(t, err, expected, loc)
}

reload_test_extend_pem :: proc(t: ^testing.T, path: string, loc := #caller_location) -> bool {
	file, err := os.open(path, os.O_RDWR)
	if !testing.expect(t, err == nil, loc = loc) {
		return false
	}
	err = os.truncate(file, trans.TLS_RELOAD_MAX_PEM_BYTES + 1)
	close_err := os.close(file)
	return testing.expect(t, err == nil && close_err == nil, loc = loc)
}

reload_test_echo :: proc(t: ^testing.T, stream: ^Conn, payload: u8, loc := #caller_location) {
	n, err := conn_write(stream, []u8{payload})
	if !testing.expect(t, n == 1 && err == .None, "send on relay stream", loc = loc) {
		return
	}
	start := time.now()
	sync.mutex_lock(&stream.mutex)
	for len(stream.inbound) == 0 && !stream.closed && !stream.reset && !stream.eof {
		left := 5 * time.Second - time.since(start)
		if left <= 0 || !sync.cond_wait_with_timeout(&stream.cond, &stream.mutex, left) {
			break
		}
	}
	ready := len(stream.inbound) > 0
	sync.mutex_unlock(&stream.mutex)
	if !testing.expect(t, ready, "receive echo on relay stream", loc = loc) {
		return
	}
	buf: [1]u8
	n, err = conn_read(stream, buf[:])
	testing.expect(t, n == 1 && err == .None && buf[0] == payload, "verify echoed data", loc = loc)
}

@(test)
test_tls_reload_live_stream_and_peer_reconnect :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-tls-reload-*", context.allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer delete(dir)
	defer os.remove_all(dir)
	cert := fmt.aprintf("%s%cbroker.crt", dir, os.Path_Separator)
	defer delete(cert)
	key := fmt.aprintf("%s%cbroker.key", dir, os.Path_Separator)
	defer delete(key)
	old_ca := fmt.aprintf("%s%cold-ca.crt", dir, os.Path_Separator)
	defer delete(old_ca)
	new_ca := fmt.aprintf("%s%cnew-ca.crt", dir, os.Path_Separator)
	defer delete(new_ca)
	peer_ca := fmt.aprintf("%s%cpeer-ca.crt", dir, os.Path_Separator)
	defer delete(peer_ca)
	for file in ([]struct {path, content: string}{
		{cert, CALLER_TEST_CERT},
		{key, CALLER_TEST_KEY},
		{old_ca, CALLER_TEST_CERT},
		{new_ca, RELOAD_TEST_ROOT},
		{peer_ca, CALLER_TEST_CERT + RELOAD_TEST_ROOT},
	}) {
		if !testing.expect(t, os.write_entire_file(file.path, transmute([]u8)file.content) == nil) {
			return
		}
	}

	ctx, terr := trans.tls_server_context_init(cert, key)
	if !testing.expect_value(t, terr, trans.TransportError.None) {
		return
	}
	sync.atomic_store(&reload_test_failures, 0)
	sync.atomic_store(&reload_test_successes, 0)
	reload_test_completed = {}
	logger: log.Logger
	log.logger_init(&logger, .Info, reload_test_log)
	fx: TestBroker
	start_test_broker(t, &fx, tls_ctx = ctx, logger = &logger)
	defer stop_test_broker(&fx)
	ep := broker_endpoint(t, &fx)
	if ep.port == 0 {
		return
	}
	watcher: brk.TlsReloadWatcher
	if !testing.expect(t, brk.tls_reload_watcher_init(&watcher, &fx.server, cert, key)) {
		return
	}
	defer brk.tls_reload_watcher_destroy(&watcher)
	if !testing.expect(t, brk.tls_reload_watcher_start(&watcher)) {
		return
	}
	request := fmt.aprintf("%s%s", cert, brk.TLS_RELOAD_SUFFIX)
	defer delete(request)
	reload_test_handshake(t, ep, old_ca, .None)
	reload_test_handshake(t, ep, new_ca, .Tls)

	echo: EchoFixture
	echo_ep := start_echo(t, &echo)
	defer stop_echo(&echo)
	service := must_service(t, TEST_SERVICE)
	agent: ag.Agent
	aerr := ag.agent_init(&agent, {
		broker = ep, token = TEST_TOKEN_HOST, tls_ca = peer_ca, tls_server_name = "127.0.0.1",
	})
	if !testing.expect_value(t, aerr, ag.AgentError.None) {
		return
	}
	run := AgentRunArg{agent = &agent}
	ath: ^thread.Thread
	defer {
		stop_agent(&agent, ath)
	}
	if !testing.expect_value(t, ag.register_service(&agent, service, {address = echo_ep}), ag.AgentError.None) {
		return
	}
	ath = thread.create_and_start_with_poly_data(&run, agent_run_proc)
	if !testing.expect(t, ath != nil) {
		return
	}
	wait_agent_connected(t, &agent)
	original, registered := brk.lookup_service_for_environment(&fx.reg, "", service, auth.DEFAULT_ORGANIZATION)
	if !testing.expect(t, registered) {
		return
	}

	c: Caller
	cerr := caller_init(&c, {
		broker = ep, token = TEST_TOKEN_CALLER, tls_ca = peer_ca, tls_server_name = "127.0.0.1",
		dial_timeout = 5 * time.Second,
	})
	if !testing.expect_value(t, cerr, CallerError.None) {
		return
	}
	defer caller_destroy(&c)
	generation := caller_conn_gen(&c)
	stream, derr := dial(&c, service)
	if !testing.expect_value(t, derr, CallerError.None) {
		return
	}
	defer conn_destroy(stream)
	reload_test_echo(t, stream, 'a')

	if !testing.expect(t, os.write_entire_file_from_string(cert, RELOAD_TEST_CHAIN) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(key, RELOAD_TEST_KEY) == nil) {
		return
	}
	reload_test_handshake(t, ep, old_ca, .None)
	if !reload_test_publish(t, request, "11111111111111111111111111111111\n", 1, 0) {
		return
	}
	reload_test_handshake(t, ep, new_ca, .None)
	reload_test_handshake(t, ep, old_ca, .Tls)
	reload_test_echo(t, stream, 'b')
	testing.expect_value(t, caller_conn_gen(&c), generation)

	// Leave the certificate in place with the wrong key, then restore the
	// key and corrupt the certificate. Each attempt must log exactly once.
	testing.expect(t, os.write_entire_file_from_string(key, CALLER_TEST_KEY) == nil)
	if !reload_test_publish(t, request, "22222222222222222222222222222222\n", 1, 1) {
		return
	}
	reload_test_handshake(t, ep, new_ca, .None)
	testing.expect(t, os.write_entire_file_from_string(key, RELOAD_TEST_KEY) == nil)
	testing.expect(t, os.write_entire_file_from_string(cert, "garbage") == nil)
	if !reload_test_publish(t, request, "33333333333333333333333333333333\n", 1, 2) {
		return
	}
	reload_test_handshake(t, ep, new_ca, .None)

	// These replacements share the active leaf's public key. Check that each
	// rejection leaves the active chain available to a root-only client.
	chain := RELOAD_TEST_CHAIN
	intermediate := strings.last_index(chain, "-----BEGIN CERTIFICATE-----")
	if !testing.expect(t, intermediate > 0) {
		return
	}
	leaf := chain[:intermediate]
	variants := []struct {prefix, pem, key, request_id: string}{
		{leaf, chain[intermediate + 1:], RELOAD_TEST_KEY, "44444444444444444444444444444444\n"},
		{leaf, RELOAD_TEST_BAD_CONSTRAINTS, RELOAD_TEST_KEY, "55555555555555555555555555555555\n"},
		{leaf, RELOAD_TEST_TRAILING_DER, RELOAD_TEST_KEY, "66666666666666666666666666666666\n"},
		{leaf, RELOAD_TEST_NUL_BODY, RELOAD_TEST_KEY, "77777777777777777777777777777777\n"},
		{"", RELOAD_TEST_CLIENT_ISSUER, RELOAD_TEST_KEY, "88888888888888888888888888888888\n"},
		{"", chain, RELOAD_TEST_INCONSISTENT_KEY, "99999999999999999999999999999999\n"},
		{leaf, RELOAD_TEST_BAD_NOT_BEFORE, RELOAD_TEST_KEY, "cccccccccccccccccccccccccccccccc\n"},
		{leaf, RELOAD_TEST_BAD_NOT_AFTER, RELOAD_TEST_KEY, "dddddddddddddddddddddddddddddddd\n"},
		{leaf, RELOAD_TEST_MISMATCHED_SIGNATURE, RELOAD_TEST_KEY, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n"},
		{"", RELOAD_TEST_INVERTED_INTERVAL, RELOAD_TEST_KEY, "ffffffffffffffffffffffffffffffff\n"},
	}
	for variant, i in variants {
		candidate, chain_err := strings.concatenate({variant.prefix, variant.pem})
		if !testing.expect(t, chain_err == .None) {
			return
		}
		defer delete(candidate)
		if !testing.expect(t, os.write_entire_file_from_string(cert, candidate) == nil) ||
		   !testing.expect(t, os.write_entire_file_from_string(key, variant.key) == nil) ||
		   !reload_test_publish(t, request, variant.request_id, 1, 3 + i) {
			return
		}
		reload_test_handshake(t, ep, new_ca, .None)
	}

	if !testing.expect(t, os.write_entire_file_from_string(cert, RELOAD_TEST_CHAIN) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(key, RELOAD_TEST_KEY) == nil) ||
	   !reload_test_extend_pem(t, cert) ||
	   !reload_test_publish(t, request, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", 1, 3 + len(variants)) {
		return
	}
	reload_test_handshake(t, ep, new_ca, .None)

	if !testing.expect(t, os.write_entire_file_from_string(cert, RELOAD_TEST_CHAIN) == nil) ||
	   !reload_test_extend_pem(t, key) ||
	   !reload_test_publish(t, request, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n", 1, 4 + len(variants)) {
		return
	}
	reload_test_handshake(t, ep, new_ca, .None)
	reload_test_echo(t, stream, 'c')

	// Force session loss without stopping the broker or changing either peer.
	brk.server_shutdown_handlers(&fx.server)
	start := time.now()
	reconnected := false
	for time.since(start) < 5 * time.Second {
		current, ok := brk.lookup_service_for_environment(&fx.reg, "", service, auth.DEFAULT_ORGANIZATION)
		if ok && current.agent_session != original.agent_session && ag.agent_is_connected(&agent) &&
		   caller_is_connected(&c) && caller_conn_gen(&c) != generation {
			reconnected = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !testing.expect(t, reconnected, "agent re-registered and caller reconnected") {
		return
	}
	next, next_err := dial(&c, service)
	if testing.expect_value(t, next_err, CallerError.None) {
		defer conn_destroy(next)
		reload_test_echo(t, next, 'd')
	}
	testing.expect_value(t, sync.atomic_load(&reload_test_failures), 4 + len(variants))
}
