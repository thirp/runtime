package transport

import "core:c"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// A legacy encrypted PEM header causes the certificate reader to ask for a
// password before it attempts to decode the body as an X509 certificate.
TEST_ENCRYPTED_CERT :: `-----BEGIN CERTIFICATE-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-128-CBC,11111111111111111111111111111111

AAAAAAAAAAAAAAAAAAAAAA==
-----END CERTIFICATE-----
`

tls_test_password_requested :: proc "c" (_: [^]c.char, _, _: c.int, user: rawptr) -> c.int {
	(^bool)(user)^ = true
	return -1
}

@(test)
test_tls_reload_rejects_encrypted_certificate :: proc(t: ^testing.T) {
	openssl_ensure_init()
	ERR_clear_error()
	defer ERR_clear_error()
	fixture := string(TEST_ENCRYPTED_CERT)
	bio := BIO_new_mem_buf(raw_data(fixture), c.int(len(fixture)))
	if !testing.expect(t, bio != nil) {
		return
	}
	defer BIO_free(bio)
	asked: bool
	parsed := PEM_read_bio_X509_AUX(bio, nil, tls_test_password_requested, &asked)
	X509_free(parsed)
	if !testing.expect(t, asked, "fixture must reach the password callback") {
		return
	}

	cert, cert_ok := write_temp_pem("reload-encrypted-cert", TEST_ENCRYPTED_CERT)
	key, key_ok := write_temp_pem("reload-encrypted-cert-key", TEST_SERVER_KEY)
	defer remove_temp_pem(cert)
	defer remove_temp_pem(key)
	if !testing.expect(t, cert_ok && key_ok) {
		return
	}
	ctx, err := tls_server_context_init(cert, key, allow_key_prompt = false)
	defer tls_server_context_destroy(ctx)
	testing.expect_value(t, err, TransportError.Tls)
}

@(test)
test_tls_reload_requires_complete_cert_chain :: proc(t: ^testing.T) {
	CHAIN :: string(#load("testdata/reload_chain.crt"))
	// #load preserves checkout line endings. Normalize before building both forms.
	chain, chain_allocated := strings.replace_all(CHAIN, "\r\n", "\n")
	defer if chain_allocated {
		delete(chain)
	}
	key, key_ok := write_temp_pem("reload-chain-key", string(#load("testdata/reload_server.key")))
	defer remove_temp_pem(key)
	cert, cert_ok := write_temp_pem("reload-chain", chain)
	defer remove_temp_pem(cert)
	if !testing.expect(t, cert_ok && key_ok) {
		return
	}
	intermediate := strings.last_index(chain, "-----BEGIN CERTIFICATE-----")
	if !testing.expect(t, intermediate > 0) {
		return
	}
	leaf := chain[:intermediate]
	ROOT :: string(#load("testdata/reload_root.crt"))
	// The first fixture changes the BasicConstraints value's SEQUENCE tag to SET.
	BAD_CONSTRAINTS :: string(#load("testdata/reload_intermediate_bad_constraints.crt"))
	// The second fixture appends bytes to the DER before base64 encoding it.
	TRAILING_BYTES :: string(#load("testdata/reload_intermediate_trailing_bytes.crt"))
	// This intermediate has a NUL and text after its first base64 line's data.
	NUL_BODY :: string(#load("testdata/reload_intermediate_nul.crt"))
	// Each fixture changes one validity field in the last supplied CA. Its
	// public key still verifies the leaf, and it serves as the local anchor.
	BAD_NOT_BEFORE :: string(#load("testdata/reload_intermediate_bad_not_before.crt"))
	BAD_NOT_AFTER :: string(#load("testdata/reload_intermediate_bad_not_after.crt"))
	// The outer signature algorithm is ECDSA/SHA-384 and the signed body names ECDSA/SHA-256.
	MISMATCHED_SIGNATURE :: string(#load("testdata/reload_intermediate_mismatched_signature.crt"))
	// The signatures verify with time checks disabled, but the intermediate ends before it starts.
	INVERTED_INTERVAL_CHAIN :: string(#load("testdata/reload_inverted_interval_chain.crt"))
	CLIENT_ISSUER_CHAIN :: string(#load("testdata/reload_client_issuer_chain.crt"))
	CLIENT_LEAF :: string(#load("testdata/reload_client_leaf.crt"))
	// Change the final signature byte while preserving the leaf's DER framing.
	bad_signature, signature_changed := strings.replace_all(leaf, "K8CLCOE=", "K8CLCOA=")
	if !testing.expect(t, signature_changed) {
		return
	}
	defer delete(bad_signature)

	lf, format_err := strings.concatenate({" \t\n", chain, "\n\t "})
	if !testing.expect(t, format_err == .None) {
		return
	}
	defer delete(lf)
	crlf, allocated := strings.replace_all(lf, "\n", "\r\n")
	if !testing.expect(t, allocated) {
		return
	}
	defer delete(crlf)
	for variant in ([]struct {name, prefix, suffix: string, want: TransportError}{
		{"LF with whitespace", "", lf, .None},
		{"CRLF with whitespace", "", crlf, .None},
		{"optional root included", chain, ROOT, .None},
		{"leaf alone", "", leaf, .None},
		{"damaged intermediate delimiter", leaf, chain[intermediate + 1:], .Tls},
		{"garbage after the chain", CHAIN, "trailing garbage\n", .Tls},
		{"malformed BasicConstraints", leaf, BAD_CONSTRAINTS, .Tls},
		{"bytes after intermediate DER", leaf, TRAILING_BYTES, .Tls},
		{"NUL and garbage on an intermediate body line", leaf, NUL_BODY, .Tls},
		{"malformed intermediate notBefore", leaf, BAD_NOT_BEFORE, .Tls},
		{"malformed intermediate notAfter", leaf, BAD_NOT_AFTER, .Tls},
		{"inconsistent intermediate signature algorithms", leaf, MISMATCHED_SIGNATURE, .Tls},
		{"inverted intermediate validity interval", "", INVERTED_INTERVAL_CHAIN, .Tls},
		{"root cannot substitute for intermediate", leaf, ROOT, .Tls},
		{"intermediate cannot verify leaf signature", bad_signature, chain[intermediate:], .Tls},
		{"client-only issuer", "", CLIENT_ISSUER_CHAIN, .Tls},
		{"client-only leaf", "", CLIENT_LEAF, .Tls},
	}) {
		pem, err := strings.concatenate({variant.prefix, variant.suffix})
		if !testing.expect(t, err == .None) {
			return
		}
		defer delete(pem)
		if !testing.expect(t, os.write_entire_file_from_string(cert, pem) == nil) {
			return
		}
		ctx, load_err := tls_server_context_init(cert, key, allow_key_prompt = false)
		tls_server_context_destroy(ctx)
		testing.expectf(t, load_err == variant.want, "%s: expected %v, got %v", variant.name, variant.want, load_err)
	}

	// The EC fixture keeps the matching public point and changes the scalar.
	if !testing.expect(t, os.write_entire_file_from_string(cert, chain) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(key, string(#load("testdata/reload_inconsistent.key"))) == nil) {
		return
	}
	ctx, load_err := tls_server_context_init(cert, key, allow_key_prompt = false)
	tls_server_context_destroy(ctx)
	testing.expect_value(t, load_err, TransportError.Tls)
}

@(test)
test_tls_reload_bounds_pem_allocation :: proc(t: ^testing.T) {
	path, ok := write_temp_pem("reload-size-limit", TEST_SERVER_CERT)
	if !testing.expect(t, ok) {
		return
	}
	defer remove_temp_pem(path)
	file, err := os.open(path, os.O_RDWR)
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.close(file)
	if !testing.expect(t, os.truncate(file, TLS_RELOAD_MAX_PEM_BYTES) == nil) {
		return
	}
	bytes := tls_read_pem_file(path, context.allocator)
	defer delete(bytes)
	testing.expect_value(t, len(bytes), TLS_RELOAD_MAX_PEM_BYTES)

	if !testing.expect(t, os.truncate(file, TLS_RELOAD_MAX_PEM_BYTES + 1) == nil) {
		return
	}
	// Fail the test if the oversized file reaches the buffer allocation.
	testing.expect(t, tls_read_pem_file(path, mem.panic_allocator()) == nil)
}
