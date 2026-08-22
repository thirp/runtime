package web_ingress

import trans "../transport"
import "core:strings"
import "core:time"

ClientHelloStatus :: enum {
	Complete,
	Incomplete,
	TooLarge,
	Malformed,
	MissingSni,
}

TLS_RECORD_HEADER_LEN :: 5
TLS_CONTENT_HANDSHAKE :: 0x16
TLS_HANDSHAKE_CLIENT_HELLO :: 0x01
TLS_EXT_SERVER_NAME :: 0
TLS_SNI_HOST_NAME :: 0

// Parse a bounded TLS ClientHello for SNI. `sni` is a slice into `data` on
// Complete; empty otherwise. Does not implement a TLS stack.
parse_client_hello_sni :: proc(data: []u8, max_bytes: int) -> (sni: string, status: ClientHelloStatus) {
	if max_bytes <= 0 {
		return "", .TooLarge
	}
	hs_off := 0
	rec := 0
	for {
		st := hello_need(data, rec, TLS_RECORD_HEADER_LEN, max_bytes)
		if st != .Complete {
			return "", hello_incomplete_or_large(data, max_bytes, st)
		}
		if data[rec] != TLS_CONTENT_HANDSHAKE {
			return "", .Malformed
		}
		rec_len := hello_u16(data, rec + 3)
		pay := rec + TLS_RECORD_HEADER_LEN
		st = hello_need(data, pay, rec_len, max_bytes)
		if st != .Complete {
			return "", hello_incomplete_or_large(data, max_bytes, st)
		}
		hs_off += rec_len
		if hs_off >= 4 {
			typ, tok := hello_hs_byte(data, 0)
			if !tok || typ != TLS_HANDSHAKE_CLIENT_HELLO {
				return "", .Malformed
			}
			hs_len, lok := hello_hs_u24(data, 1)
			if !lok {
				return "", .Malformed
			}
			if 4 + hs_len > max_bytes {
				return "", .TooLarge
			}
			if hs_off >= 4 + hs_len {
				return hello_parse_sni(data, 4 + hs_len, max_bytes)
			}
		}
		rec = pay + rec_len
		if rec >= len(data) {
			if len(data) >= max_bytes {
				return "", .TooLarge
			}
			return "", .Incomplete
		}
	}
}

ingress_inspect_client_hello :: proc(
	conn: ^trans.Connection,
	max_bytes: int,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (
	PublicHost,
	IngressError,
) {
	if conn == nil || max_bytes <= 0 {
		return {}, .MalformedClientHello
	}
	start := time.now()
	buf := make([]u8, max_bytes, allocator)
	defer delete(buf, allocator)
	last_n := 0
	for {
		remain := timeout
		if timeout > 0 {
			used := time.since(start)
			if used >= timeout {
				_ = trans.connection_set_recv_lowat(conn, 1)
				return {}, .ClientHelloTimeout
			}
			remain = timeout - used
		}
		_ = trans.connection_set_recv_timeout(conn, remain)
		n, perr := trans.connection_peek(conn, buf)
		if perr == .Timeout {
			_ = trans.connection_set_recv_lowat(conn, 1)
			return {}, .ClientHelloTimeout
		}
		if perr == .Closed {
			_ = trans.connection_set_recv_lowat(conn, 1)
			return {}, .MalformedClientHello
		}
		if perr != .None {
			_ = trans.connection_set_recv_lowat(conn, 1)
			return {}, .MalformedClientHello
		}
		sni, status := parse_client_hello_sni(buf[:n], max_bytes)
		switch status {
		case .Complete:
			_ = trans.connection_set_recv_lowat(conn, 1)
			host, herr := make_public_host(sni, allocator)
			if herr != .None {
				return {}, public_host_error_to_ingress(herr)
			}
			return host, .None
		case .Incomplete:
			if n >= max_bytes {
				_ = trans.connection_set_recv_lowat(conn, 1)
				return {}, .ClientHelloTooLarge
			}
			if n == last_n || n > last_n {
				want := n + 1
				if want > max_bytes {
					want = max_bytes
				}
				_ = trans.connection_set_recv_lowat(conn, want)
			}
			last_n = n
		case .TooLarge:
			_ = trans.connection_set_recv_lowat(conn, 1)
			return {}, .ClientHelloTooLarge
		case .Malformed:
			_ = trans.connection_set_recv_lowat(conn, 1)
			return {}, .MalformedClientHello
		case .MissingSni:
			_ = trans.connection_set_recv_lowat(conn, 1)
			return {}, .MissingSni
		}
	}
}

hello_need :: proc(data: []u8, off, n, max_bytes: int) -> ClientHelloStatus {
	if n < 0 || off < 0 {
		return .Malformed
	}
	end := off + n
	if end < off {
		return .Malformed
	}
	if end > max_bytes {
		return .TooLarge
	}
	if end > len(data) {
		return .Incomplete
	}
	return .Complete
}

hello_incomplete_or_large :: proc(data: []u8, max_bytes: int, st: ClientHelloStatus) -> ClientHelloStatus {
	if st == .Incomplete && len(data) >= max_bytes {
		return .TooLarge
	}
	return st
}

hello_u16 :: proc(data: []u8, off: int) -> int {
	return int(data[off]) << 8 | int(data[off + 1])
}

hello_hs_u24 :: proc(data: []u8, hs_index: int) -> (int, bool) {
	a, aok := hello_hs_byte(data, hs_index)
	b, bok := hello_hs_byte(data, hs_index + 1)
	c, cok := hello_hs_byte(data, hs_index + 2)
	if !aok || !bok || !cok {
		return 0, false
	}
	return int(a) << 16 | int(b) << 8 | int(c), true
}

hello_hs_byte :: proc(data: []u8, hs_index: int) -> (u8, bool) {
	off := 0
	skipped := 0
	for off + TLS_RECORD_HEADER_LEN <= len(data) {
		if data[off] != TLS_CONTENT_HANDSHAKE {
			return 0, false
		}
		rec_len := hello_u16(data, off + 3)
		pay := off + TLS_RECORD_HEADER_LEN
		if pay + rec_len > len(data) {
			return 0, false
		}
		if hs_index < skipped + rec_len {
			return data[pay + (hs_index - skipped)], true
		}
		skipped += rec_len
		off = pay + rec_len
	}
	return 0, false
}

hello_hs_slice :: proc(data: []u8, hs_index, n: int) -> (string, bool) {
	if n < 0 {
		return "", false
	}
	off := 0
	skipped := 0
	for off + TLS_RECORD_HEADER_LEN <= len(data) {
		if data[off] != TLS_CONTENT_HANDSHAKE {
			return "", false
		}
		rec_len := hello_u16(data, off + 3)
		pay := off + TLS_RECORD_HEADER_LEN
		if pay + rec_len > len(data) {
			return "", false
		}
		if hs_index >= skipped && hs_index + n <= skipped + rec_len {
			start := pay + (hs_index - skipped)
			return string(data[start:start + n]), true
		}
		skipped += rec_len
		off = pay + rec_len
	}
	return "", false
}

hello_parse_sni :: proc(data: []u8, hs_total, max_bytes: int) -> (string, ClientHelloStatus) {
	_ = max_bytes
	p := 4
	if p + 2 + 32 + 1 > hs_total {
		return "", .Malformed
	}
	p += 2 + 32
	sid_len, ok := hello_hs_u8(data, p)
	if !ok {
		return "", .Malformed
	}
	p += 1
	if p + sid_len + 2 > hs_total {
		return "", .Malformed
	}
	p += sid_len
	cs_len, cs_ok := hello_hs_u16(data, p)
	if !cs_ok {
		return "", .Malformed
	}
	p += 2
	if p + cs_len + 1 > hs_total {
		return "", .Malformed
	}
	p += cs_len
	comp_len, comp_ok := hello_hs_u8(data, p)
	if !comp_ok {
		return "", .Malformed
	}
	p += 1
	if p + comp_len > hs_total {
		return "", .Malformed
	}
	p += comp_len
	if p == hs_total {
		return "", .MissingSni
	}
	if p + 2 > hs_total {
		return "", .Malformed
	}
	ext_len, ext_ok := hello_hs_u16(data, p)
	if !ext_ok {
		return "", .Malformed
	}
	p += 2
	if p + ext_len != hs_total {
		return "", .Malformed
	}
	end := p + ext_len
	found := false
	chosen: string
	for p + 4 <= end {
		ext_type, t_ok := hello_hs_u16(data, p)
		ext_size, s_ok := hello_hs_u16(data, p + 2)
		if !t_ok || !s_ok {
			return "", .Malformed
		}
		p += 4
		if p + ext_size > end {
			return "", .Malformed
		}
		if ext_type == TLS_EXT_SERVER_NAME {
			name, nst := hello_parse_server_name(data, p, ext_size)
			if nst != .Complete {
				return "", nst
			}
			if found {
				if !hello_sni_equal(chosen, name) {
					return "", .Malformed
				}
			} else {
				chosen = name
				found = true
			}
		}
		p += ext_size
	}
	if p != end {
		return "", .Malformed
	}
	if !found || len(chosen) == 0 {
		return "", .MissingSni
	}
	return chosen, .Complete
}

hello_parse_server_name :: proc(data: []u8, start, size: int) -> (string, ClientHelloStatus) {
	if size < 2 {
		return "", .Malformed
	}
	list_len, ok := hello_hs_u16(data, start)
	if !ok || list_len + 2 != size {
		return "", .Malformed
	}
	p := start + 2
	end := start + size
	chosen: string
	found := false
	for p < end {
		if p + 3 > end {
			return "", .Malformed
		}
		name_type, t_ok := hello_hs_u8(data, p)
		name_len, n_ok := hello_hs_u16(data, p + 1)
		if !t_ok || !n_ok {
			return "", .Malformed
		}
		p += 3
		if p + name_len > end {
			return "", .Malformed
		}
		if name_type == TLS_SNI_HOST_NAME {
			if name_len == 0 {
				return "", .MissingSni
			}
			name, nst := hello_hs_slice(data, p, name_len)
			if !nst {
				return "", .Malformed
			}
			if found {
				if !hello_sni_equal(chosen, name) {
					return "", .Malformed
				}
			} else {
				chosen = name
				found = true
			}
		}
		p += name_len
	}
	if p != end {
		return "", .Malformed
	}
	if !found {
		return "", .MissingSni
	}
	return chosen, .Complete
}

hello_hs_u8 :: proc(data: []u8, hs_index: int) -> (int, bool) {
	b, ok := hello_hs_byte(data, hs_index)
	return int(b), ok
}

hello_hs_u16 :: proc(data: []u8, hs_index: int) -> (int, bool) {
	hi, hok := hello_hs_byte(data, hs_index)
	lo, lok := hello_hs_byte(data, hs_index + 1)
	if !hok || !lok {
		return 0, false
	}
	return int(hi) << 8 | int(lo), true
}

hello_sni_equal :: proc(a, b: string) -> bool {
	buf_a: [MAX_PUBLIC_HOST_LEN]u8
	buf_b: [MAX_PUBLIC_HOST_LEN]u8
	ca, ea := canonicalize_public_host(a, buf_a[:])
	cb, eb := canonicalize_public_host(b, buf_b[:])
	if ea != .None || eb != .None {
		return strings.equal_fold(a, b)
	}
	return ca == cb
}
