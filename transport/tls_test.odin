package transport

import proto "../protocol"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Test-only self-signed PEMs (SAN IP:127.0.0.1 and DNS:localhost). Not for production.
TEST_SERVER_CERT :: string(#load("testdata/test_server.crt"))
TEST_SERVER_KEY :: string(#load("testdata/test_server.key"))
TEST_OTHER_CERT :: string(#load("testdata/unrelated.crt"))

tls_temp_seq: int

write_temp_pem :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&tls_temp_seq, 1)
	temp_dir := os.get_env("TEMP", context.temp_allocator)
	if len(temp_dir) == 0 {
		temp_dir = os.get_env("TMP", context.temp_allocator)
	}
	if len(temp_dir) == 0 {
		temp_dir = os.get_env("TMPDIR", context.temp_allocator)
	}
	when ODIN_OS == .Windows {
		if len(temp_dir) == 0 {
			temp_dir = "C:\\Windows\\Temp"
		}
	} else {
		if len(temp_dir) == 0 {
			temp_dir = "/tmp"
		}
	}
	path = fmt.aprintf("%s%cthirp-tls-%s-%d.pem", temp_dir, os.Path_Separator, label, n)
	err := os.write_entire_file(path, transmute([]u8)contents)
	if err != nil {
		delete(path)
		return "", false
	}
	return path, true
}

remove_temp_pem :: proc(path: string) {
	_ = os.remove(path)
	delete(path)
}

TlsAcceptArg :: struct {
	ln:     ^Listener,
	ctx:    ^TlsServerContext,
	server: ^Connection,
	err:    TransportError,
}

PlainAcceptArg :: struct {
	ln:   ^Listener,
	conn: ^Connection,
}

plain_accept_and_read :: proc(p: ^PlainAcceptArg) {
	conn, _ := listener_accept(p.ln)
	p.conn = conn
	if conn != nil {
		connection_close(conn)
	}
}

tls_accept_worker :: proc(arg: ^TlsAcceptArg) {
	conn, aerr := listener_accept(arg.ln)
	if aerr != .None {
		arg.err = aerr
		return
	}
	herr := connection_tls_accept(conn, arg.ctx)
	if herr != .None {
		connection_destroy(conn)
		arg.err = herr
		return
	}
	arg.server = conn
}

start_tls_pair :: proc(
	t: ^testing.T,
	loc := #caller_location,
) -> (
	client: ^Connection,
	server: ^Connection,
	ctx: ^TlsServerContext,
	cert_path: string,
	key_path: string,
) {
	cert_ok: bool
	cert_path, cert_ok = write_temp_pem("cert", TEST_SERVER_CERT)
	testing.expect(t, cert_ok, loc = loc)
	key_ok: bool
	key_path, key_ok = write_temp_pem("key", TEST_SERVER_KEY)
	testing.expect(t, key_ok, loc = loc)

	ctx_err: TransportError
	ctx, ctx_err = tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, ctx_err, TransportError.None, loc)
	testing.expect(t, ctx != nil, loc = loc)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None, loc)
	_ = listener_set_recv_timeout(&ln, 2 * time.Second)

	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None, loc)

	arg := TlsAcceptArg {
		ln  = &ln,
		ctx = ctx,
	}
	worker := thread.create_and_start_with_poly_data(&arg, tls_accept_worker)

	cfg := TlsClientConfig {
		ca_path     = cert_path,
		server_name = "127.0.0.1",
	}
	dial_err: TransportError
	client, dial_err = connection_dial_tls(ep, cfg)
	testing.expect_value(t, dial_err, TransportError.None, loc)
	testing.expect(t, client != nil, loc = loc)

	thread.join(worker)
	thread.destroy(worker)
	listener_close(&ln)

	testing.expect_value(t, arg.err, TransportError.None, loc)
	testing.expect(t, arg.server != nil, loc = loc)
	server = arg.server
	return
}

@(test)
test_tls_listen_dial_exchanges_bytes :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(client)
		connection_destroy(server)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}

	msg := []u8{'p', 'i', 'n', 'g'}
	testing.expect_value(t, connection_write(client, msg), TransportError.None)

	buf: [16]u8
	n, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.None)
	testing.expect_value(t, n, len(msg))
	testing.expect_value(t, string(buf[:n]), "ping")
}

@(test)
test_tls_server_sends_chain_from_multi_pem_file :: proc(t: ^testing.T) {
	chain, _ := strings.concatenate({TEST_SERVER_CERT, TEST_OTHER_CERT})
	testing.expect(t, len(chain) > 0)
	defer delete(chain)
	cert_path, cert_ok := write_temp_pem("chain", chain)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", TEST_SERVER_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)
	ca_path, ca_ok := write_temp_pem("ca", TEST_SERVER_CERT)
	testing.expect(t, ca_ok)
	defer remove_temp_pem(ca_path)

	ctx, ctx_err := tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, ctx_err, TransportError.None)
	defer tls_server_context_destroy(ctx)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	_ = listener_set_recv_timeout(&ln, 2 * time.Second)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	arg := TlsAcceptArg {
		ln  = &ln,
		ctx = ctx,
	}
	worker := thread.create_and_start_with_poly_data(&arg, tls_accept_worker)
	client, derr := connection_dial_tls(ep, TlsClientConfig{ca_path = ca_path, server_name = "127.0.0.1"})
	testing.expect_value(t, derr, TransportError.None)
	testing.expect(t, client != nil)
	defer connection_destroy(client)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, arg.err, TransportError.None)
	testing.expect(t, arg.server != nil)
	connection_destroy(arg.server)
}

@(test)
test_tls_client_wrong_ca_fails :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", TEST_SERVER_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", TEST_SERVER_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)
	other_path, other_ok := write_temp_pem("other", TEST_OTHER_CERT)
	testing.expect(t, other_ok)
	defer remove_temp_pem(other_path)

	ctx, ctx_err := tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, ctx_err, TransportError.None)
	defer tls_server_context_destroy(ctx)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	_ = listener_set_recv_timeout(&ln, 2 * time.Second)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	arg := TlsAcceptArg {
		ln  = &ln,
		ctx = ctx,
	}
	worker := thread.create_and_start_with_poly_data(&arg, tls_accept_worker)
	defer {
		thread.join(worker)
		thread.destroy(worker)
		if arg.server != nil {
			connection_destroy(arg.server)
		}
	}

	cfg := TlsClientConfig {
		ca_path     = other_path,
		server_name = "127.0.0.1",
	}
	client, derr := connection_dial_tls(ep, cfg)
	testing.expect_value(t, derr, TransportError.Tls)
	testing.expect(t, client == nil)
}

@(test)
test_tls_client_wrong_server_name_fails :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", TEST_SERVER_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", TEST_SERVER_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	ctx, ctx_err := tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, ctx_err, TransportError.None)
	defer tls_server_context_destroy(ctx)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	_ = listener_set_recv_timeout(&ln, 2 * time.Second)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	arg := TlsAcceptArg {
		ln  = &ln,
		ctx = ctx,
	}
	worker := thread.create_and_start_with_poly_data(&arg, tls_accept_worker)
	defer {
		thread.join(worker)
		thread.destroy(worker)
		if arg.server != nil {
			connection_destroy(arg.server)
		}
	}

	cfg := TlsClientConfig {
		ca_path     = cert_path,
		server_name = "other.example",
	}
	client, derr := connection_dial_tls(ep, cfg)
	testing.expect_value(t, derr, TransportError.Tls)
	testing.expect(t, client == nil)
}

@(test)
test_tls_client_vs_plaintext_listener_fails :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", TEST_SERVER_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	_ = listener_set_recv_timeout(&ln, 2 * time.Second)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	plain := PlainAcceptArg{ln = &ln}
	worker := thread.create_and_start_with_poly_data(&plain, plain_accept_and_read)
	defer {
		thread.join(worker)
		thread.destroy(worker)
		if plain.conn != nil {
			connection_destroy(plain.conn)
		}
	}

	cfg := TlsClientConfig {
		ca_path     = cert_path,
		server_name = "127.0.0.1",
	}
	client, derr := connection_dial_tls(ep, cfg)
	testing.expect_value(t, derr, TransportError.Tls)
	testing.expect(t, client == nil)
}

@(test)
test_tls_plaintext_client_vs_tls_server_fails :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", TEST_SERVER_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", TEST_SERVER_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	ctx, ctx_err := tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, ctx_err, TransportError.None)
	defer tls_server_context_destroy(ctx)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	_ = listener_set_recv_timeout(&ln, 2 * time.Second)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	arg := TlsAcceptArg {
		ln  = &ln,
		ctx = ctx,
	}
	worker := thread.create_and_start_with_poly_data(&arg, tls_accept_worker)

	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	_ = connection_write(client, []u8{'h', 'i'})
	connection_destroy(client)

	thread.join(worker)
	thread.destroy(worker)
	if arg.server != nil {
		connection_destroy(arg.server)
	}
	testing.expect_value(t, arg.err, TransportError.Tls)
}

TlsReadArg :: struct {
	conn: ^Connection,
	buf:  [8]u8,
	n:    int,
	err:  TransportError,
}

tls_read_worker :: proc(arg: ^TlsReadArg) {
	arg.n, arg.err = connection_read(arg.conn, arg.buf[:])
}

@(test)
test_tls_read_delivers_bytes_sent_before_shutdown :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(client)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}

	arg := TlsReadArg{conn = client}
	worker := thread.create_and_start_with_poly_data(&arg, tls_read_worker)
	time.sleep(20 * time.Millisecond)

	msg := []u8{'4', '0', '3'}
	testing.expect_value(t, connection_write(server, msg), TransportError.None)
	connection_shutdown_both(server)
	connection_destroy(server)

	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, arg.err, TransportError.None)
	testing.expect_value(t, arg.n, len(msg))
	testing.expect_value(t, string(arg.buf[:arg.n]), "403")
}

@(test)
test_tls_connection_close_is_visible_to_peer :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(server)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}

	connection_close(client)
	connection_destroy(client)
	buf: [8]u8
	_, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.Closed)
}

@(test)
test_tls_set_recv_timeout_returns_timeout :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(client)
		connection_destroy(server)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}

	testing.expect_value(t, connection_set_recv_timeout(server, 20 * time.Millisecond), TransportError.None)
	buf: [8]u8
	_, rerr := connection_read(server, buf[:])
	testing.expect_value(t, rerr, TransportError.Timeout)
}

@(test)
test_tls_servername_returns_sni :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(client)
		connection_destroy(server)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}
	testing.expect_value(t, connection_tls_servername(server), "127.0.0.1")
}

@(test)
test_tls_alpn_http11_rejects_h2_only_client :: proc(t: ^testing.T) {
	cert_path, cert_ok := write_temp_pem("cert", TEST_SERVER_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", TEST_SERVER_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	ctx, ctx_err := tls_server_context_init(cert_path, key_path)
	testing.expect_value(t, ctx_err, TransportError.None)
	defer tls_server_context_destroy(ctx)
	tls_server_context_set_alpn_http11(ctx)

	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	_ = listener_set_recv_timeout(&ln, 2 * time.Second)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)

	arg := TlsAcceptArg {
		ln  = &ln,
		ctx = ctx,
	}
	worker := thread.create_and_start_with_poly_data(&arg, tls_accept_worker)
	defer {
		thread.join(worker)
		thread.destroy(worker)
		if arg.server != nil {
			connection_destroy(arg.server)
		}
	}

	h2 := []u8{2, 'h', '2'}
	cfg := TlsClientConfig {
		ca_path     = cert_path,
		server_name = "127.0.0.1",
		alpn        = h2,
	}
	client, derr := connection_dial_tls(ep, cfg)
	testing.expect_value(t, derr, TransportError.Tls)
	testing.expect(t, client == nil)
}

// Peer shuts its write side after a request. The response written after that
// half-close must arrive byte for byte. An unexpected TCP FIN must not mark
// the TLS connection closed before that write.
@(test)
test_tls_response_after_peer_shutdown_write :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(client)
		connection_destroy(server)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}
	_ = connection_set_recv_timeout(client, 2 * time.Second)
	_ = connection_set_recv_timeout(server, 2 * time.Second)

	testing.expect_value(t, connection_write(client, []u8{'B'}), TransportError.None)
	testing.expect_value(t, connection_shutdown_write(client), TransportError.None)

	got_req: [1]u8
	n, rerr := connection_read(server, got_req[:])
	testing.expect_value(t, rerr, TransportError.None)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, got_req[0], u8('B'))

	buf: [256]u8
	for {
		_, rerr = connection_read(server, buf[:])
		if rerr != .None {
			break
		}
	}
	testing.expect_value(t, rerr, TransportError.Closed)

	body := make([]u8, 20 * 1024)
	defer delete(body)
	for i in 0 ..< len(body) {
		body[i] = u8(i + 1)
	}
	testing.expect_value(t, connection_write(server, body), TransportError.None)
	testing.expect_value(t, connection_shutdown_write(server), TransportError.None)

	got := make([dynamic]u8, 0, len(body))
	defer delete(got)
	read_buf: [4096]u8
	for len(got) < len(body) {
		m, err := connection_read(client, read_buf[:])
		if m > 0 {
			append(&got, ..read_buf[:m])
		}
		if err != .None {
			break
		}
	}
	testing.expect_value(t, len(got), len(body))
	same := len(got) == len(body)
	if same {
		for i in 0 ..< len(body) {
			if got[i] != body[i] {
				same = false
				break
			}
		}
	}
	testing.expect(t, same, "response after shutdown_write")
}

// The server writes a full body and then TCP FIN, with no TLS close_notify.
// The client must read every byte and then see a clean close. Removing
// SSL_OP_IGNORE_UNEXPECTED_EOF from tls_client_context_new makes this
// extra read return .Tls.
@(test)
test_tls_client_unexpected_eof_is_clean_close :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(client)
		connection_destroy(server)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}
	_ = connection_set_recv_timeout(client, 2 * time.Second)
	_ = connection_set_recv_timeout(server, 2 * time.Second)

	body := make([]u8, 4096)
	defer delete(body)
	for i in 0 ..< len(body) {
		body[i] = u8(i)
	}
	testing.expect_value(t, connection_write(server, body), TransportError.None)
	testing.expect_value(t, connection_shutdown_write(server), TransportError.None)

	got := make([dynamic]u8, 0, len(body))
	defer delete(got)
	read_buf: [1024]u8
	for len(got) < len(body) {
		m, err := connection_read(client, read_buf[:])
		if m > 0 {
			append(&got, ..read_buf[:m])
		}
		if err != .None {
			testing.expect_value(t, err, TransportError.None)
			return
		}
	}
	testing.expect_value(t, len(got), len(body))
	same := true
	for i in 0 ..< len(body) {
		if got[i] != body[i] {
			same = false
			break
		}
	}
	testing.expect(t, same, "client body")

	n, err := connection_read(client, read_buf[:])
	testing.expect_value(t, n, 0)
	testing.expect_value(t, err, TransportError.Closed)
}

// The server writes a length-prefixed frame cut short, then TCP FIN and no
// close_notify. OpenSSL 3.5.7 with SSL_OP_IGNORE_UNEXPECTED_EOF reports
// that FIN as a clean close. read_frame must still fail at the frame
// layer. conn_run treats that protocol error as the end of the session.
@(test)
test_tls_truncated_frame_is_frame_error :: proc(t: ^testing.T) {
	client, server, ctx, cert_path, key_path := start_tls_pair(t)
	defer {
		connection_destroy(client)
		connection_destroy(server)
		tls_server_context_destroy(ctx)
		remove_temp_pem(cert_path)
		remove_temp_pem(key_path)
	}
	_ = connection_set_recv_timeout(client, 2 * time.Second)
	_ = connection_set_recv_timeout(server, 2 * time.Second)

	body := make([]u8, 64)
	defer delete(body)
	for i in 0 ..< len(body) {
		body[i] = u8(i + 1)
	}
	raw, perr := proto.encode_frame(proto.FrameHeader{opcode = .Data, stream_id = 9}, body)
	testing.expect_value(t, perr, proto.ProtocolError.None)
	defer delete(raw)
	cut := proto.HEADER_SIZE + 8
	testing.expect(t, cut < len(raw))
	testing.expect_value(t, connection_write(server, raw[:cut]), TransportError.None)
	testing.expect_value(t, connection_shutdown_write(server), TransportError.None)

	decoder: proto.FrameDecoder
	testing.expect_value(t, proto.decoder_init(&decoder), proto.ProtocolError.None)
	defer proto.decoder_destroy(&decoder)

	frame, terr, rperr := read_frame(client, &decoder)
	testing.expect_value(t, terr, TransportError.None)
	testing.expect_value(t, rperr, proto.ProtocolError.Truncated)
	proto.frame_destroy(&frame)
	testing.expect(t, len(decoder.buf) > 0, "short frame was discarded")
}
