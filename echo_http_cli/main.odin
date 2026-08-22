package main

import trans "../transport"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"

ECHO_READ_MAX :: 1024 * 1024

usage :: proc() {
	fmt.eprintf("usage: thirp-echo-http --listen HOST:PORT\n")
}

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	listen := ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--listen":
			if i + 1 >= len(args) {
				fmt.eprintf("--listen requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			listen = args[i]
		case "-h", "--help":
			usage()
			return 0
		case:
			fmt.eprintf("unknown flag: %s\n", args[i])
			usage()
			return 1
		}
	}
	if len(listen) == 0 {
		fmt.eprintf("--listen is required\n")
		usage()
		return 1
	}

	ep, eerr := trans.parse_endpoint(listen)
	if eerr != .None {
		fmt.eprintf("invalid --listen address\n")
		return 1
	}

	ln, lerr := trans.listener_listen(ep)
	if lerr != .None {
		fmt.eprintf("listen failed\n")
		return 1
	}
	defer trans.listener_close(&ln)
	bound, _ := trans.listener_endpoint(ln)
	fmt.printf("thirp-echo-http listening on %s\n", net.endpoint_to_string(bound))

	for {
		conn, aerr := trans.listener_accept(&ln)
		if aerr != .None {
			return 1
		}
		thread.run_with_poly_data(conn, echo_http_conn)
	}
}

echo_http_conn :: proc(conn: ^trans.Connection) {
	defer trans.connection_destroy(conn)
	buf := make([dynamic]u8)
	defer delete(buf)
	header_end := -1
	for len(buf) < ECHO_READ_MAX {
		tmp: [4096]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		header_end = strings.index(string(buf[:]), "\r\n\r\n")
		if header_end >= 0 {
			break
		}
		if err != .None {
			return
		}
	}
	if header_end < 0 {
		return
	}
	headers := string(buf[:header_end])
	method, target, host, ok := echo_parse_request_head(headers)
	if !ok {
		return
	}
	clen := echo_content_length(headers)
	body_off := header_end + 4
	for len(buf) - body_off < clen {
		if len(buf) >= ECHO_READ_MAX {
			return
		}
		tmp: [4096]u8
		n, err := trans.connection_read(conn, tmp[:])
		if n > 0 {
			_, _ = append(&buf, ..tmp[:n])
		}
		if err != .None {
			return
		}
	}
	body := buf[body_off:body_off + clen]
	resp := fmt.aprintf(
		"HTTP/1.1 200 OK\r\n" +
		"Content-Type: application/octet-stream\r\n" +
		"X-Echo-Method: %s\r\n" +
		"X-Echo-Target: %s\r\n" +
		"X-Echo-Host: %s\r\n" +
		"Content-Length: %d\r\n" +
		"Connection: close\r\n" +
		"\r\n",
		method,
		target,
		host,
		len(body),
	)
	defer delete(resp)
	if trans.connection_write(conn, transmute([]u8)resp) != .None {
		return
	}
	if len(body) > 0 {
		_ = trans.connection_write(conn, body)
	}
}

echo_parse_request_head :: proc(headers: string) -> (method, target, host: string, ok: bool) {
	line_end := strings.index(headers, "\r\n")
	if line_end < 0 {
		return "", "", "", false
	}
	line := headers[:line_end]
	sp1 := strings.index_byte(line, ' ')
	if sp1 <= 0 {
		return "", "", "", false
	}
	rest := line[sp1 + 1:]
	sp2 := strings.index_byte(rest, ' ')
	if sp2 <= 0 {
		return "", "", "", false
	}
	method = line[:sp1]
	target = rest[:sp2]
	host = echo_header_value(headers, "Host")
	return method, target, host, true
}

echo_header_value :: proc(headers, name: string) -> string {
	needle := fmt.tprintf("\r\n%s:", name)
	idx := strings.index(headers, needle)
	if idx < 0 {
		if strings.has_prefix(headers, name) && len(headers) > len(name) && headers[len(name)] == ':' {
			val := strings.trim_left_space(headers[len(name) + 1:])
			end := strings.index(val, "\r\n")
			if end >= 0 {
				val = val[:end]
			}
			return strings.trim_space(val)
		}
		return ""
	}
	rest := headers[idx + 2:]
	colon := strings.index_byte(rest, ':')
	if colon < 0 {
		return ""
	}
	val := strings.trim_left_space(rest[colon + 1:])
	end := strings.index(val, "\r\n")
	if end >= 0 {
		val = val[:end]
	}
	return strings.trim_space(val)
}

echo_content_length :: proc(headers: string) -> int {
	val := echo_header_value(headers, "Content-Length")
	if len(val) == 0 {
		return 0
	}
	n, ok := strconv.parse_int(val)
	if !ok || n < 0 {
		return 0
	}
	return n
}
