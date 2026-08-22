package web_ingress

import trans "../transport"
import "core:testing"
import "core:thread"
import "core:time"

HelloWriteLater :: struct {
	conn:  ^trans.Connection,
	bytes: []u8,
	delay: time.Duration,
}

hello_write_later_proc :: proc(arg: ^HelloWriteLater) {
	time.sleep(arg.delay)
	_ = trans.connection_write(arg.conn, arg.bytes)
}

hello_put_u16 :: proc(buf: ^[dynamic]u8, n: int) {
	append(buf, u8(n >> 8), u8(n))
}

hello_put_u24 :: proc(buf: ^[dynamic]u8, n: int) {
	append(buf, u8(n >> 16), u8(n >> 8), u8(n))
}

hello_wrap_record :: proc(payload: []u8) -> []u8 {
	out := make([dynamic]u8, 0, 5 + len(payload))
	append(&out, TLS_CONTENT_HANDSHAKE, 0x03, 0x03)
	hello_put_u16(&out, len(payload))
	append(&out, ..payload)
	return out[:]
}

// Minimal ClientHello. `names` are host_name entries in one server_name list.
// Empty `names` omits the server_name extension. `session` is the session_id.
build_client_hello :: proc(names: []string, session: []u8 = nil, random_fill: u8 = 0) -> []u8 {
	body := make([dynamic]u8)
	defer delete(body)
	append(&body, 0x03, 0x03)
	for _ in 0 ..< 32 {
		append(&body, random_fill)
	}
	append(&body, u8(len(session)))
	if len(session) > 0 {
		append(&body, ..session)
	}
	hello_put_u16(&body, 2)
	append(&body, 0x00, 0x2f)
	append(&body, 1, 0)

	ext := make([dynamic]u8)
	defer delete(ext)
	if len(names) > 0 {
		list := make([dynamic]u8)
		defer delete(list)
		for name in names {
			append(&list, TLS_SNI_HOST_NAME)
			hello_put_u16(&list, len(name))
			append(&list, ..transmute([]u8)name)
		}
		hello_put_u16(&ext, TLS_EXT_SERVER_NAME)
		hello_put_u16(&ext, 2 + len(list))
		hello_put_u16(&ext, len(list))
		append(&ext, ..list[:])
	} else {
		hello_put_u16(&ext, 0x000d)
		hello_put_u16(&ext, 2)
		append(&ext, 0x00, 0x00)
	}
	hello_put_u16(&body, len(ext))
	append(&body, ..ext[:])

	hs := make([dynamic]u8)
	defer delete(hs)
	append(&hs, TLS_HANDSHAKE_CLIENT_HELLO)
	hello_put_u24(&hs, len(body))
	append(&hs, ..body[:])
	return hello_wrap_record(hs[:])
}

build_client_hello_two_exts :: proc(name_a, name_b: string) -> []u8 {
	one := build_client_hello([]string{name_a})
	defer delete(one)
	two := build_client_hello([]string{name_b})
	defer delete(two)
	// Rebuild with two server_name extensions by parsing is harder; construct body.
	body := make([dynamic]u8)
	defer delete(body)
	append(&body, 0x03, 0x03)
	for _ in 0 ..< 32 {
		append(&body, 0)
	}
	append(&body, 0)
	hello_put_u16(&body, 2)
	append(&body, 0x00, 0x2f)
	append(&body, 1, 0)
	ext := make([dynamic]u8)
	defer delete(ext)
	names := [2]string{name_a, name_b}
	for name in names {
		hello_put_u16(&ext, TLS_EXT_SERVER_NAME)
		hello_put_u16(&ext, 2 + 1 + 2 + len(name))
		hello_put_u16(&ext, 1 + 2 + len(name))
		append(&ext, TLS_SNI_HOST_NAME)
		hello_put_u16(&ext, len(name))
		append(&ext, ..transmute([]u8)name)
	}
	hello_put_u16(&body, len(ext))
	append(&body, ..ext[:])
	hs := make([dynamic]u8)
	defer delete(hs)
	append(&hs, TLS_HANDSHAKE_CLIENT_HELLO)
	hello_put_u24(&hs, len(body))
	append(&hs, ..body[:])
	return hello_wrap_record(hs[:])
}

split_hello_records :: proc(hello: []u8, first_payload: int) -> []u8 {
	if len(hello) < TLS_RECORD_HEADER_LEN {
		return nil
	}
	payload := hello[TLS_RECORD_HEADER_LEN:]
	if first_payload <= 0 || first_payload >= len(payload) {
		cloned := make([]u8, len(hello))
		copy(cloned, hello)
		return cloned
	}
	a := hello_wrap_record(payload[:first_payload])
	defer delete(a)
	b := hello_wrap_record(payload[first_payload:])
	defer delete(b)
	out := make([]u8, len(a) + len(b))
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

@(test)
test_parse_client_hello_sni_complete :: proc(t: ^testing.T) {
	hello := build_client_hello([]string{"Ingress.TEST."})
	defer delete(hello)
	sni, st := parse_client_hello_sni(hello, len(hello))
	testing.expect_value(t, st, ClientHelloStatus.Complete)
	testing.expect_value(t, sni, "Ingress.TEST.")
}

@(test)
test_parse_client_hello_exact_max_and_one_over :: proc(t: ^testing.T) {
	hello := build_client_hello([]string{"secure.test"})
	defer delete(hello)
	sni, st := parse_client_hello_sni(hello, len(hello))
	testing.expect_value(t, st, ClientHelloStatus.Complete)
	testing.expect_value(t, sni, "secure.test")
	_, over := parse_client_hello_sni(hello, len(hello) - 1)
	testing.expect_value(t, over, ClientHelloStatus.TooLarge)
}

@(test)
test_parse_client_hello_split_across_records :: proc(t: ^testing.T) {
	hello := build_client_hello([]string{"secure.test"})
	defer delete(hello)
	split := split_hello_records(hello, 8)
	defer delete(split)
	sni, st := parse_client_hello_sni(split, len(split))
	testing.expect_value(t, st, ClientHelloStatus.Complete)
	testing.expect_value(t, sni, "secure.test")
	first_end := TLS_RECORD_HEADER_LEN + 8
	_, inc := parse_client_hello_sni(split[:first_end], len(split))
	testing.expect_value(t, inc, ClientHelloStatus.Incomplete)
}

@(test)
test_parse_client_hello_truncated_record :: proc(t: ^testing.T) {
	hello := build_client_hello([]string{"secure.test"})
	defer delete(hello)
	_, st := parse_client_hello_sni(hello[:7], 65536)
	testing.expect_value(t, st, ClientHelloStatus.Incomplete)
}

@(test)
test_parse_client_hello_overflowing_record_length :: proc(t: ^testing.T) {
	buf := []u8{0x16, 0x03, 0x03, 0xff, 0xff, 0x01}
	_, st := parse_client_hello_sni(buf, 64)
	testing.expect_value(t, st, ClientHelloStatus.TooLarge)
}

@(test)
test_parse_client_hello_overflowing_handshake_length :: proc(t: ^testing.T) {
	payload := []u8{0x01, 0xff, 0xff, 0xff, 0x03, 0x03}
	hello := hello_wrap_record(payload)
	defer delete(hello)
	_, st := parse_client_hello_sni(hello, 64)
	testing.expect_value(t, st, ClientHelloStatus.TooLarge)
}

@(test)
test_parse_client_hello_overflowing_extension_length :: proc(t: ^testing.T) {
	body := make([dynamic]u8)
	defer delete(body)
	append(&body, 0x03, 0x03)
	for _ in 0 ..< 32 {
		append(&body, 0)
	}
	append(&body, 0)
	hello_put_u16(&body, 2)
	append(&body, 0x00, 0x2f)
	append(&body, 1, 0)
	ext := make([dynamic]u8)
	defer delete(ext)
	hello_put_u16(&ext, TLS_EXT_SERVER_NAME)
	hello_put_u16(&ext, 0x4000)
	hello_put_u16(&ext, 5)
	append(&ext, TLS_SNI_HOST_NAME)
	hello_put_u16(&ext, 1)
	append(&ext, 'a')
	hello_put_u16(&body, len(ext))
	append(&body, ..ext[:])
	hs := make([dynamic]u8)
	defer delete(hs)
	append(&hs, TLS_HANDSHAKE_CLIENT_HELLO)
	hello_put_u24(&hs, len(body))
	append(&hs, ..body[:])
	hello := hello_wrap_record(hs[:])
	defer delete(hello)
	_, st := parse_client_hello_sni(hello, len(hello))
	testing.expect_value(t, st, ClientHelloStatus.Malformed)
}

@(test)
test_parse_client_hello_overflowing_server_name_list :: proc(t: ^testing.T) {
	body := make([dynamic]u8)
	defer delete(body)
	append(&body, 0x03, 0x03)
	for _ in 0 ..< 32 {
		append(&body, 0)
	}
	append(&body, 0)
	hello_put_u16(&body, 2)
	append(&body, 0x00, 0x2f)
	append(&body, 1, 0)
	ext := make([dynamic]u8)
	defer delete(ext)
	hello_put_u16(&ext, TLS_EXT_SERVER_NAME)
	hello_put_u16(&ext, 4)
	hello_put_u16(&ext, 0xffff)
	append(&ext, 0x00, 0x00)
	hello_put_u16(&body, len(ext))
	append(&body, ..ext[:])
	hs := make([dynamic]u8)
	defer delete(hs)
	append(&hs, TLS_HANDSHAKE_CLIENT_HELLO)
	hello_put_u24(&hs, len(body))
	append(&hs, ..body[:])
	hello := hello_wrap_record(hs[:])
	defer delete(hello)
	_, st := parse_client_hello_sni(hello, len(hello))
	testing.expect_value(t, st, ClientHelloStatus.Malformed)
}

@(test)
test_parse_client_hello_missing_and_empty_sni :: proc(t: ^testing.T) {
	none := build_client_hello(nil)
	defer delete(none)
	_, st := parse_client_hello_sni(none, len(none))
	testing.expect_value(t, st, ClientHelloStatus.MissingSni)

	empty := build_client_hello([]string{""})
	defer delete(empty)
	_, est := parse_client_hello_sni(empty, len(empty))
	testing.expect_value(t, est, ClientHelloStatus.MissingSni)
}

@(test)
test_parse_client_hello_duplicate_equal_and_conflicting_sni :: proc(t: ^testing.T) {
	eq := build_client_hello([]string{"secure.test", "SECURE.TEST."})
	defer delete(eq)
	sni, st := parse_client_hello_sni(eq, len(eq))
	testing.expect_value(t, st, ClientHelloStatus.Complete)
	testing.expect_value(t, sni, "secure.test")

	conf := build_client_hello([]string{"secure.test", "other.test"})
	defer delete(conf)
	_, cst := parse_client_hello_sni(conf, len(conf))
	testing.expect_value(t, cst, ClientHelloStatus.Malformed)

	exts := build_client_hello_two_exts("secure.test", "other.test")
	defer delete(exts)
	_, est := parse_client_hello_sni(exts, len(exts))
	testing.expect_value(t, est, ClientHelloStatus.Malformed)
}

@(test)
test_parse_client_hello_rejects_non_handshake_record :: proc(t: ^testing.T) {
	buf := []u8{0x17, 0x03, 0x03, 0x00, 0x01, 0x00}
	_, st := parse_client_hello_sni(buf, 64)
	testing.expect_value(t, st, ClientHelloStatus.Malformed)
}

@(test)
test_inspect_client_hello_invalid_host :: proc(t: ^testing.T) {
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	defer trans.listener_close(&ln)
	ep, eerr := trans.listener_endpoint(ln)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(client)
	server, aerr := trans.listener_accept(&ln)
	testing.expect_value(t, aerr, trans.TransportError.None)
	defer trans.connection_destroy(server)

	hello := build_client_hello([]string{"127.0.0.1"})
	defer delete(hello)
	testing.expect_value(t, trans.connection_write(client, hello), trans.TransportError.None)
	_, err := ingress_inspect_client_hello(server, 1024, 500 * time.Millisecond)
	testing.expect_value(t, err, IngressError.InvalidPublicHost)
}

@(test)
test_inspect_client_hello_timeout :: proc(t: ^testing.T) {
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	defer trans.listener_close(&ln)
	ep, eerr := trans.listener_endpoint(ln)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(client)
	server, aerr := trans.listener_accept(&ln)
	testing.expect_value(t, aerr, trans.TransportError.None)
	defer trans.connection_destroy(server)

	testing.expect_value(t, trans.connection_write(client, []u8{0x16, 0x03, 0x01, 0x00, 0x80}), trans.TransportError.None)
	_, err := ingress_inspect_client_hello(server, 1024, 200 * time.Millisecond)
	testing.expect_value(t, err, IngressError.ClientHelloTimeout)
}

@(test)
test_inspect_client_hello_split_write :: proc(t: ^testing.T) {
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None)
	defer trans.listener_close(&ln)
	ep, eerr := trans.listener_endpoint(ln)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client, derr := trans.connection_dial(ep)
	testing.expect_value(t, derr, trans.TransportError.None)
	defer trans.connection_destroy(client)
	server, aerr := trans.listener_accept(&ln)
	testing.expect_value(t, aerr, trans.TransportError.None)
	defer trans.connection_destroy(server)

	hello := build_client_hello([]string{"secure.test"})
	defer delete(hello)
	mid := 8
	if mid >= len(hello) {
		mid = len(hello) / 2
	}
	testing.expect_value(t, trans.connection_write(client, hello[:mid]), trans.TransportError.None)
	later := HelloWriteLater{conn = client, bytes = hello[mid:], delay = 30 * time.Millisecond}
	th := thread.create_and_start_with_poly_data(&later, hello_write_later_proc)
	host, err := ingress_inspect_client_hello(server, 1024, 1 * time.Second)
	if th != nil {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, err, IngressError.None)
	testing.expect_value(t, string(host), "secure.test")
	public_host_destroy(host)
}
