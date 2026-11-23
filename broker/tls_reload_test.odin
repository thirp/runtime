package broker

import log "../logging"
import trans "../transport"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

RELOAD_TEST_CERT :: string(#load("../transport/testdata/test_server.crt"))
RELOAD_TEST_KEY :: string(#load("../transport/testdata/test_server.key"))
RELOAD_TEST_CHAIN :: string(#load("../transport/testdata/reload_chain.crt"))
RELOAD_TEST_OTHER_KEY :: string(#load("../transport/testdata/reload_server.key"))
RELOAD_TEST_BAD_CONSTRAINTS :: string(#load("../transport/testdata/reload_intermediate_bad_constraints.crt"))
RELOAD_TEST_TRAILING_DER :: string(#load("../transport/testdata/reload_intermediate_trailing_bytes.crt"))
RELOAD_TEST_NUL_BODY :: string(#load("../transport/testdata/reload_intermediate_nul.crt"))
RELOAD_TEST_BAD_NOT_BEFORE :: string(#load("../transport/testdata/reload_intermediate_bad_not_before.crt"))
RELOAD_TEST_BAD_NOT_AFTER :: string(#load("../transport/testdata/reload_intermediate_bad_not_after.crt"))
RELOAD_TEST_MISMATCHED_SIGNATURE :: string(#load("../transport/testdata/reload_intermediate_mismatched_signature.crt"))
RELOAD_TEST_INVERTED_INTERVAL :: string(#load("../transport/testdata/reload_inverted_interval_chain.crt"))
RELOAD_TEST_CLIENT_ISSUER :: string(#load("../transport/testdata/reload_client_issuer_chain.crt"))
RELOAD_TEST_INCONSISTENT_KEY :: string(#load("../transport/testdata/reload_inconsistent.key"))

reload_errors: int
reload_successes: int
reload_succeeded: sync.Sema

reload_log_sink :: proc(line: string) {
	if strings.contains(line, "\"event\":\"" + LOG_EVENT_TLS_RELOAD_FAILED + "\"") {
		reload_errors += 1
	}
	if strings.contains(line, "\"event\":\"" + LOG_EVENT_TLS_RELOADED + "\"") {
		reload_successes += 1
		sync.sema_post(&reload_succeeded)
	}
}

@(test)
test_tls_reload_request_is_consumed_once :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-reload-request-*", context.allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer delete(dir)
	defer os.remove_all(dir)
	cert := fmt.aprintf("%s%ccert.pem", dir, os.Path_Separator)
	defer delete(cert)
	key := fmt.aprintf("%s%ckey.pem", dir, os.Path_Separator)
	defer delete(key)
	request := fmt.aprintf("%s%s", cert, TLS_RELOAD_SUFFIX)
	defer delete(request)
	if !testing.expect(t, os.write_entire_file_from_string(cert, RELOAD_TEST_CERT) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(key, RELOAD_TEST_KEY) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(request, "11111111111111111111111111111111\n") == nil) {
		return
	}

	ctx, terr := trans.tls_server_context_init(cert, key)
	if !testing.expect_value(t, terr, trans.TransportError.None) {
		return
	}
	reload_errors, reload_successes = 0, 0
	reload_succeeded = {}
	logger: log.Logger
	log.logger_init(&logger, .Info, reload_log_sink)
	server: Server
	server_init(&server, nil, {})
	defer server_destroy(&server)
	server.tls_ctx = ctx
	server.logger = &logger

	w: TlsReloadWatcher
	if !testing.expect(t, tls_reload_watcher_init(&w, &server, cert, key)) {
		return
	}
	defer tls_reload_watcher_destroy(&w)
	tls_reload_poll(&w)
	testing.expect_value(t, reload_successes, 0)
	testing.expect_value(t, reload_errors, 0)

	testing.expect(t, os.write_entire_file_from_string(key, RELOAD_TEST_OTHER_KEY) == nil)
	// Observe the truncate and partial write that can precede a complete request.
	testing.expect(t, os.write_entire_file_from_string(request, "") == nil)
	tls_reload_poll(&w)
	testing.expect_value(t, reload_errors, 0)
	testing.expect(t, os.write_entire_file_from_string(request, "22222222222222222222222222222222\r") == nil)
	tls_reload_poll(&w)
	testing.expect_value(t, reload_errors, 0)
	testing.expect(t, os.write_entire_file_from_string(request, "22222222222222222222222222222222\r\n") == nil)
	tls_reload_poll(&w)
	tls_reload_poll(&w)
	testing.expect_value(t, reload_errors, 1)
	testing.expect_value(t, reload_successes, 0)
	testing.expect(t, server.tls_ctx == ctx, "rejected reload changed the active TLS context")

	testing.expect(t, os.write_entire_file_from_string(cert, RELOAD_TEST_CHAIN) == nil)
	testing.expect(t, os.write_entire_file_from_string(key, RELOAD_TEST_OTHER_KEY) == nil)
	tls_reload_poll(&w)
	testing.expect_value(t, reload_successes, 0)

	chain := RELOAD_TEST_CHAIN
	intermediate := strings.last_index(chain, "-----BEGIN CERTIFICATE-----")
	if !testing.expect(t, intermediate > 0) {
		return
	}
	leaf := chain[:intermediate]
	variants := []struct {prefix, pem, key, request_id: string}{
		{leaf, RELOAD_TEST_BAD_CONSTRAINTS, RELOAD_TEST_OTHER_KEY, "33333333333333333333333333333333\r\n"},
		{leaf, RELOAD_TEST_TRAILING_DER, RELOAD_TEST_OTHER_KEY, "44444444444444444444444444444444\n"},
		{leaf, RELOAD_TEST_NUL_BODY, RELOAD_TEST_OTHER_KEY, "55555555555555555555555555555555\n"},
		{"", RELOAD_TEST_CLIENT_ISSUER, RELOAD_TEST_OTHER_KEY, "66666666666666666666666666666666\n"},
		{"", chain, RELOAD_TEST_INCONSISTENT_KEY, "77777777777777777777777777777777\n"},
		{leaf, RELOAD_TEST_BAD_NOT_BEFORE, RELOAD_TEST_OTHER_KEY, "99999999999999999999999999999999\n"},
		{leaf, RELOAD_TEST_BAD_NOT_AFTER, RELOAD_TEST_OTHER_KEY, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"},
		{leaf, RELOAD_TEST_MISMATCHED_SIGNATURE, RELOAD_TEST_OTHER_KEY, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"},
		{"", RELOAD_TEST_INVERTED_INTERVAL, RELOAD_TEST_OTHER_KEY, "cccccccccccccccccccccccccccccccc\n"},
	}
	for variant, i in variants {
		candidate, chain_err := strings.concatenate({variant.prefix, variant.pem})
		if !testing.expect(t, chain_err == .None) {
			return
		}
		defer delete(candidate)
		if !testing.expect(t, os.write_entire_file_from_string(cert, candidate) == nil) ||
		   !testing.expect(t, os.write_entire_file_from_string(key, variant.key) == nil) ||
		   !testing.expect(t, os.write_entire_file_from_string(request, variant.request_id) == nil) {
			return
		}
		tls_reload_poll(&w)
		rejected := testing.expect_value(t, reload_errors, 2 + i)
		tls_reload_poll(&w)
		deduplicated := testing.expect_value(t, reload_errors, 2 + i)
		no_success := testing.expect_value(t, reload_successes, 0)
		unchanged := testing.expect(t, server.tls_ctx == ctx, "rejected reload changed the active TLS context")
		if !rejected || !deduplicated || !no_success || !unchanged {
			return
		}
	}

	if !testing.expect(t, os.write_entire_file_from_string(cert, chain) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(key, RELOAD_TEST_OTHER_KEY) == nil) {
		return
	}
	if !testing.expect(t, tls_reload_watcher_start(&w)) ||
	   !testing.expect(t, os.write_entire_file_from_string(request, "88888888888888888888888888888888\n") == nil) ||
	   !testing.expect(t, sync.sema_wait_with_timeout(&reload_succeeded, 5 * time.Second)) {
		return
	}
	testing.expect_value(t, reload_errors, 1 + len(variants))
	testing.expect_value(t, reload_successes, 1)
	testing.expect(t, server.tls_ctx != ctx)
}
