package config

import "core:strings"
import "core:testing"

@(test)
test_parse_ini_comments_blanks_sections_and_spaces :: proc(t: ^testing.T) {
	text := `
# comment
[listen]

listen = 127.0.0.1:9000
tls_cert= /tmp/cert.pem
tls_key =/tmp/key.pem
`
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	testing.expect_value(t, len(doc.entries), 3)
	testing.expect_value(t, doc.entries[0].key, "listen")
	testing.expect_value(t, doc.entries[0].value, "127.0.0.1:9000")
	testing.expect_value(t, doc.entries[1].key, "tls_cert")
	testing.expect_value(t, doc.entries[1].value, "/tmp/cert.pem")
	testing.expect_value(t, doc.entries[2].key, "tls_key")
	testing.expect_value(t, doc.entries[2].value, "/tmp/key.pem")
}

@(test)
test_parse_ini_repeatable_keys_append :: proc(t: ^testing.T) {
	text := "map = a=127.0.0.1:1\nmap = b=127.0.0.1:2\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	testing.expect_value(t, len(doc.entries), 2)
	testing.expect_value(t, doc.entries[0].value, "a=127.0.0.1:1")
	testing.expect_value(t, doc.entries[1].value, "b=127.0.0.1:2")
}

@(test)
test_parse_ini_unknown_key_reports_line :: proc(t: ^testing.T) {
	text := "listen = 127.0.0.1:9000\nnot_a_key = yes\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := broker_settings_from_ini(doc, &issues)
	defer broker_settings_destroy(&settings)
	testing.expect_value(t, serr, ConfigError.UnknownKey)
	testing.expect(t, len(issues) >= 1)
	testing.expect_value(t, issues[0].line, 2)
	testing.expect_value(t, issues[0].message, "unknown key")
}

@(test)
test_parse_ini_duplicate_listen_reports_line :: proc(t: ^testing.T) {
	text := "listen = 127.0.0.1:9000\nlisten = 127.0.0.1:9001\n"
	doc, err := parse_ini_bytes(transmute([]u8)text)
	testing.expect_value(t, err, ConfigError.None)
	defer ini_document_destroy(&doc)
	issues := make([dynamic]ValidationIssue)
	defer issues_destroy(issues)
	settings, serr := broker_settings_from_ini(doc, &issues)
	defer broker_settings_destroy(&settings)
	testing.expect_value(t, serr, ConfigError.DuplicateKey)
	testing.expect(t, len(issues) >= 1)
	testing.expect_value(t, issues[0].line, 2)
	testing.expect_value(t, issues[0].message, "duplicate key")
}

@(test)
test_parse_ini_empty_and_missing_and_too_large :: proc(t: ^testing.T) {
	empty := "# only comment\n\n"
	_, err := parse_ini_bytes(transmute([]u8)empty)
	testing.expect_value(t, err, ConfigError.Empty)

	_, err = parse_ini_file("/tmp/thirp-config-does-not-exist-9f3a.conf")
	testing.expect_value(t, err, ConfigError.Io)

	huge := make([]u8, MAX_CONFIG_FILE_LEN + 1)
	defer delete(huge)
	_, err = parse_ini_bytes(huge)
	testing.expect_value(t, err, ConfigError.TooLarge)
}

@(test)
test_parse_ini_error_does_not_include_file_body :: proc(t: ^testing.T) {
	secret := "redact-me-unique-token-9f3a=host-a\nnot a line\n"
	path, ok := write_temp_config("body", secret)
	testing.expect(t, ok)
	defer remove_temp_config(path)
	_, err := parse_ini_file(path)
	testing.expect_value(t, err, ConfigError.InvalidLine)
	name := fmt_error(err)
	testing.expect(t, !strings.contains(name, "redact-me-unique-token-9f3a"))
	testing.expect(t, !strings.contains(name, "not a line"))
}

fmt_error :: proc(err: ConfigError) -> string {
	switch err {
	case .None:
		return "none"
	case .Io:
		return "cannot read file"
	case .Empty:
		return "empty config"
	case .TooLarge:
		return "config file too large"
	case .InvalidLine:
		return "invalid line"
	case .UnknownKey:
		return "unknown key"
	case .DuplicateKey:
		return "duplicate key"
	case .InvalidValue:
		return "invalid value"
	case .MissingRequired:
		return "missing required"
	case .InsecureProduction:
		return "production mode cannot enable insecure"
	case .OutOfMemory:
		return "out of memory"
	}
	return "error"
}
