package auth

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

credential_temp_seq: int

write_temp_text :: proc(label, contents: string) -> (path: string, ok: bool) {
	n := sync.atomic_add(&credential_temp_seq, 1)
	path = fmt.aprintf("/tmp/thirp-auth-%s-%d.txt", label, n)
	err := os.write_entire_file(path, transmute([]u8)contents)
	if err != nil {
		delete(path)
		return "", false
	}
	return path, true
}

remove_temp_text :: proc(path: string) {
	_ = os.remove(path)
	delete(path)
}

@(test)
test_parse_credential_line_bare_principal :: proc(t: ^testing.T) {
	spec, skip, err := parse_credential_line("host-dev-token=host-a")
	testing.expect_value(t, err, AuthError.None)
	testing.expect(t, !skip)
	testing.expect_value(t, spec.token, "host-dev-token")
	testing.expect_value(t, spec.principal_id, "host-a")
	testing.expect_value(t, spec.organization, "")
	testing.expect_value(t, spec.capabilities, TokenCapabilities{})
	testing.expect_value(t, spec.label, "")
}

@(test)
test_parse_credential_line_principal_org :: proc(t: ^testing.T) {
	spec, skip, err := parse_credential_line("host-site-17=agent-site-17:acme")
	testing.expect_value(t, err, AuthError.None)
	testing.expect(t, !skip)
	testing.expect_value(t, spec.token, "host-site-17")
	testing.expect_value(t, spec.principal_id, "agent-site-17")
	testing.expect_value(t, spec.organization, "acme")
}

@(test)
test_parse_credential_line_optional_fields :: proc(t: ^testing.T) {
	spec, skip, err := parse_credential_line(
		"host-site-17=agent-site-17:acme;capabilities=register;label=site-17-agent;expires=2027-01-01T00:00:00Z",
	)
	testing.expect_value(t, err, AuthError.None)
	testing.expect(t, !skip)
	testing.expect_value(t, spec.capabilities, TokenCapabilities{.RegisterService})
	testing.expect_value(t, spec.label, "site-17-agent")
	testing.expect(t, spec.expires_at != {})
}

@(test)
test_parse_credential_line_comment_and_blank_skip :: proc(t: ^testing.T) {
	_, skip, err := parse_credential_line("# agent-site-17")
	testing.expect_value(t, err, AuthError.None)
	testing.expect(t, skip)

	_, skip, err = parse_credential_line("   ")
	testing.expect_value(t, err, AuthError.None)
	testing.expect(t, skip)
}

@(test)
test_parse_credential_line_unknown_key_fails :: proc(t: ^testing.T) {
	_, skip, err := parse_credential_line("tok=host-a;role=agent")
	testing.expect_value(t, err, AuthError.InvalidToken)
	testing.expect(t, !skip)
}

@(test)
test_parse_credential_line_capabilities_register_connect :: proc(t: ^testing.T) {
	spec, skip, err := parse_credential_line("tok=host-a;capabilities=register,connect")
	testing.expect_value(t, err, AuthError.None)
	testing.expect(t, !skip)
	testing.expect_value(t, spec.capabilities, TokenCapabilities{.RegisterService, .ConnectService})
}

@(test)
test_parse_credential_line_duplicate_field_fails :: proc(t: ^testing.T) {
	_, _, err := parse_credential_line("tok=host-a;label=a;label=b")
	testing.expect_value(t, err, AuthError.InvalidToken)
}

@(test)
test_read_secret_file_trims_newline :: proc(t: ^testing.T) {
	path, ok := write_temp_text("secret", "host-dev-token\n")
	testing.expect(t, ok)
	defer remove_temp_text(path)

	token, err := read_secret_file(path)
	testing.expect_value(t, err, AuthError.None)
	defer delete(token)
	testing.expect_value(t, token, "host-dev-token")
}

@(test)
test_read_secret_file_rejects_empty :: proc(t: ^testing.T) {
	path, ok := write_temp_text("empty", "\n")
	testing.expect(t, ok)
	defer remove_temp_text(path)

	_, err := read_secret_file(path)
	testing.expect_value(t, err, AuthError.InvalidToken)
}

@(test)
test_read_secret_file_rejects_internal_newline :: proc(t: ^testing.T) {
	path, ok := write_temp_text("multiline", "one\ntwo\n")
	testing.expect(t, ok)
	defer remove_temp_text(path)

	_, err := read_secret_file(path)
	testing.expect_value(t, err, AuthError.InvalidToken)
}

@(test)
test_read_secret_file_rejects_too_long :: proc(t: ^testing.T) {
	buf := make([]u8, MAX_TOKEN_LEN + 1)
	defer delete(buf)
	for i in 0 ..< len(buf) {
		buf[i] = 'a'
	}
	path, ok := write_temp_text("long", string(buf))
	testing.expect(t, ok)
	defer remove_temp_text(path)

	_, err := read_secret_file(path)
	testing.expect_value(t, err, AuthError.InvalidToken)
}

@(test)
test_load_credential_file_two_records_and_comment :: proc(t: ^testing.T) {
	contents :=
		"# production credentials\n" +
		"host-site-17=agent-site-17:acme;capabilities=register;label=site-17-agent\n" +
		"\n" +
		"reporting-client=reporting-client:acme;capabilities=connect;label=reporting-client\n"
	path, ok := write_temp_text("creds", contents)
	testing.expect(t, ok)
	defer remove_temp_text(path)

	specs, err := load_credential_file(path)
	testing.expect_value(t, err, AuthError.None)
	defer credential_specs_destroy(specs)
	testing.expect_value(t, len(specs), 2)
	testing.expect_value(t, specs[0].token, "host-site-17")
	testing.expect_value(t, specs[0].principal_id, "agent-site-17")
	testing.expect_value(t, specs[0].organization, "acme")
	testing.expect_value(t, specs[0].capabilities, TokenCapabilities{.RegisterService})
	testing.expect_value(t, specs[0].label, "site-17-agent")
	testing.expect_value(t, specs[1].token, "reporting-client")
	testing.expect_value(t, specs[1].capabilities, TokenCapabilities{.ConnectService})
}
