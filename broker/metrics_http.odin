package broker

import trans "../transport"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:thread"
import "core:time"

METRICS_HTTP_TIMEOUT :: 2 * time.Second
METRICS_HTTP_MAX_REQUEST :: 4096

server_metrics_listen :: proc(server: ^Server, endpoint: net.Endpoint) -> trans.TransportError {
	ln, err := trans.listener_listen(endpoint)
	if err != .None {
		return err
	}
	server.metrics_listener = ln
	server.metrics_listening = true
	server.metrics_stop = false
	_ = trans.listener_set_recv_timeout(&server.metrics_listener, ACCEPT_POLL_INTERVAL)
	return .None
}

server_metrics_start :: proc(server: ^Server) {
	if !server.metrics_listening {
		return
	}
	server.metrics_thread = thread.create_and_start_with_poly_data(server, metrics_http_serve)
}

server_metrics_stop :: proc(server: ^Server) {
	server.metrics_stop = true
	if server.metrics_listening {
		trans.listener_close(&server.metrics_listener)
		server.metrics_listening = false
	}
	if server.metrics_thread != nil {
		thread.join(server.metrics_thread)
		thread.destroy(server.metrics_thread)
		server.metrics_thread = nil
	}
}

server_metrics_endpoint :: proc(server: ^Server) -> (net.Endpoint, trans.TransportError) {
	if !server.metrics_listening {
		return {}, .Closed
	}
	return trans.listener_endpoint(server.metrics_listener)
}

metrics_http_serve :: proc(server: ^Server) {
	for {
		if server.metrics_stop {
			return
		}
		conn, err := trans.listener_accept(&server.metrics_listener, server.allocator)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		metrics_http_handle(server, conn)
		trans.connection_destroy(conn, server.allocator)
	}
}

metrics_http_handle :: proc(server: ^Server, conn: ^trans.Connection) {
	_ = trans.connection_set_recv_timeout(conn, METRICS_HTTP_TIMEOUT)
	req: [METRICS_HTTP_MAX_REQUEST]u8
	n := 0
	for n < len(req) {
		got, rerr := trans.connection_read(conn, req[n:])
		if rerr != .None || got == 0 {
			return
		}
		n += got
		if has_header_end(req[:n]) {
			break
		}
	}
	path, ok := http_request_path(req[:n])
	if !ok {
		metrics_http_write_status(conn, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		return
	}
	switch path {
	case "/healthz":
		metrics_http_write_body(conn, "200 OK", "text/plain; charset=utf-8", "ok\n")
	case "/readyz":
		ready, reason := server_ready(server)
		status := ready ? "200 OK" : "503 Service Unavailable"
		metrics_http_write_body(conn, status, "text/plain; charset=utf-8", fmt.tprintf("%s\n", reason))
	case "/metrics":
		snap := metrics_snapshot(server)
		body := metrics_write_prometheus(snap, server.allocator)
		defer delete(body, server.allocator)
		metrics_http_write_body(conn, "200 OK", "text/plain; version=0.0.4; charset=utf-8", body)
	case:
		metrics_http_write_status(conn, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	}
}

metrics_http_write_status :: proc(conn: ^trans.Connection, status: string) {
	_ = trans.connection_write(conn, transmute([]u8)status)
}

metrics_http_write_body :: proc(conn: ^trans.Connection, status: string, content_type: string, body: string) {
	header := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		status,
		content_type,
		len(body),
	)
	_ = trans.connection_write(conn, transmute([]u8)header)
	if len(body) > 0 {
		_ = trans.connection_write(conn, transmute([]u8)body)
	}
}

has_header_end :: proc(buf: []u8) -> bool {
	return strings.contains(string(buf), "\r\n\r\n")
}

http_request_path :: proc(buf: []u8) -> (string, bool) {
	text := string(buf)
	line_end := strings.index(text, "\r\n")
	if line_end < 0 {
		return "", false
	}
	line := text[:line_end]
	if !strings.has_prefix(line, "GET ") {
		return "", false
	}
	rest := line[4:]
	sp := strings.index_byte(rest, ' ')
	if sp < 0 {
		return "", false
	}
	target := rest[:sp]
	q := strings.index_byte(target, '?')
	if q >= 0 {
		target = target[:q]
	}
	return target, true
}