package connect

import auth "../../auth"
import trans "../../transport"
import private_file "private_file"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"

CALLER_FILE_MODE :: private_file.MODE
CALLER_CONF_MAX :: 1 << 20
CALLER_TOKEN_PREFIX :: "thirp_cen_"

EnrollmentLinkConfig :: struct {service, listen: string}
EnrollmentConfig :: struct {
	// String fields borrow this buffer, except the two resolved file paths.
	text: []u8,
	api, org, environment, enrollment, broker, tls_server_name: string,
	token_file, tls_ca: string,
	links: [dynamic]EnrollmentLinkConfig,
}

enrollment_config_destroy :: proc(c: ^EnrollmentConfig) {
	delete(c.token_file)
	delete(c.tls_ca)
	delete(c.links)
	delete(c.text)
	c^ = {}
}

enrollment_id_ok :: proc(s: string) -> bool {
	if len(s) == 0 {return false}
	for b in transmute([]u8)s {
		if !(b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '-' || b == '_') {return false}
	}
	return true
}

enrollment_file_private :: private_file.is_private
enrollment_read_private :: private_file.read

enrollment_relative_path :: proc(base, path: string) -> string {
	if len(path) == 0 {return ""}
	if filepath.is_abs(path) {return strings.clone(path)}
	joined, _ := filepath.join({os.dir(base), path})
	return joined
}

enrollment_config_parse :: proc(text, path: string) -> (c: EnrollmentConfig, ok: bool) {
	c.text = make([]u8, len(text))
	copy(c.text, text)
	defer if !ok {enrollment_config_destroy(&c)}
	seen := make(map[string]bool)
	defer delete(seen)
	token_file, tls_ca: string
	rest := string(c.text)
	for raw in strings.split_lines_iterator(&rest) {
		line := raw
		if hash := strings.index_byte(line, '#'); hash >= 0 {line = line[:hash]}
		line = strings.trim_space(line)
		if len(line) == 0 {continue}
		eq := strings.index_byte(line, '=')
		if eq < 0 {return c, false}
		key, value := strings.trim_space(line[:eq]), strings.trim_space(line[eq+1:])
		if key == "service" {
			listen_eq := strings.index_byte(value, '=')
			if listen_eq < 0 {return c, false}
			fields := strings.fields(value[:listen_eq])
			defer delete(fields)
			listen := strings.trim_space(value[listen_eq+1:])
			if len(fields) != 2 || fields[1] != "listen" || !enrollment_id_ok(fields[0]) {return c, false}
			_, err := trans.parse_endpoint(listen)
			if err != .None {return c, false}
			for link in c.links {if link.listen == listen {return c, false}}
			append(&c.links, EnrollmentLinkConfig{fields[0], listen})
			continue
		}
		if seen[key] {return c, false}
		seen[key] = true
		switch key {
		case "api": c.api = value
		case "org": c.org = value
		case "environment": c.environment = value
		case "enrollment": c.enrollment = value
		case "token_file": token_file = value
		case "broker": c.broker = value
		case "tls_ca": tls_ca = value
		case "tls_server_name": c.tls_server_name = value
		case: return c, false
		}
	}
	for key in ([]string{"api", "org", "environment", "enrollment", "token_file", "broker", "tls_ca", "tls_server_name"}) {
		if !seen[key] {return c, false}
	}
	if !enrollment_id_ok(c.org) || !enrollment_id_ok(c.enrollment) ||
		(len(c.environment) > 0 && !enrollment_id_ok(c.environment)) || len(token_file) == 0 || len(c.links) == 0 {return c, false}
	_, _, _, url_ok := enrollment_api_address(c.api)
	broker_host, broker_port, broker_ok := net.split_port(c.broker)
	if !url_ok || !broker_ok || len(broker_host) == 0 || broker_port <= 0 ||
		strings.contains_any(c.broker, "/?#@ \r\n\t\x00") || strings.contains_any(c.tls_server_name, "\r\n\x00") {return c, false}
	c.token_file = enrollment_relative_path(path, token_file)
	c.tls_ca = enrollment_relative_path(path, tls_ca)
	return c, true
}

enrollment_config_load :: proc(path: string) -> (EnrollmentConfig, string, bool) {
	text, private := enrollment_read_private(path, CALLER_CONF_MAX)
	if !private {return {}, "", false}
	defer delete(text)
	c, ok := enrollment_config_parse(string(text), path)
	if !ok {return {}, "", false}
	secret, token_private := enrollment_read_private(c.token_file, auth.MAX_SECRET_FILE_LEN)
	defer delete(secret)
	token := auth.trim_ascii_space(string(secret))
	if !token_private || !enrollment_token_ok(token) {
		enrollment_config_destroy(&c)
		return {}, "", false
	}
	return c, strings.clone(token), true
}

enrollment_token_ok :: proc(token: string) -> bool {
	if !strings.has_prefix(token, CALLER_TOKEN_PREFIX) || len(token) <= len(CALLER_TOKEN_PREFIX) || len(token) > auth.MAX_TOKEN_LEN {return false}
	for b in transmute([]u8)token {if b <= 32 || b >= 127 {return false}}
	return true
}
