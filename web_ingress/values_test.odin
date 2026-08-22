package web_ingress

import "core:testing"

@(test)
test_make_public_host_accepts_ordinary_hostname :: proc(t: ^testing.T) {
	host, err := make_public_host("portfolio-k7m4x2.web.example.com")
	testing.expect_value(t, err, PublicHostError.None)
	defer public_host_destroy(host)
	testing.expect_value(t, string(host), "portfolio-k7m4x2.web.example.com")
}

@(test)
test_make_public_host_accepts_localhost :: proc(t: ^testing.T) {
	host, err := make_public_host("localhost")
	testing.expect_value(t, err, PublicHostError.None)
	defer public_host_destroy(host)
	testing.expect_value(t, string(host), "localhost")
}

@(test)
test_make_public_host_accepts_a_label :: proc(t: ^testing.T) {
	host, err := make_public_host("xn--fsq.example.com")
	testing.expect_value(t, err, PublicHostError.None)
	defer public_host_destroy(host)
	testing.expect_value(t, string(host), "xn--fsq.example.com")
}

@(test)
test_make_public_host_lowercases_and_strips_terminal_dot :: proc(t: ^testing.T) {
	host, err := make_public_host("Example.COM.")
	testing.expect_value(t, err, PublicHostError.None)
	defer public_host_destroy(host)
	testing.expect_value(t, string(host), "example.com")
}

@(test)
test_make_public_host_canonicalizes_uppercase_without_dot :: proc(t: ^testing.T) {
	host, err := make_public_host("Web.Example.Com")
	testing.expect_value(t, err, PublicHostError.None)
	defer public_host_destroy(host)
	testing.expect_value(t, string(host), "web.example.com")
}

@(test)
test_check_public_host_rejects_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, check_public_host(""), PublicHostError.Empty)
	_, err := make_public_host("")
	testing.expect_value(t, err, PublicHostError.Empty)
	testing.expect_value(t, check_public_host("."), PublicHostError.Empty)
}

@(test)
test_check_public_host_rejects_too_long :: proc(t: ^testing.T) {
	ok_name := hostname_with_last_label_len(61)
	defer delete(ok_name)
	testing.expect_value(t, check_public_host(ok_name), PublicHostError.None)
	host, err := make_public_host(ok_name)
	testing.expect_value(t, err, PublicHostError.None)
	public_host_destroy(host)

	long_name := hostname_with_last_label_len(62)
	defer delete(long_name)
	testing.expect_value(t, check_public_host(long_name), PublicHostError.TooLong)
}

@(test)
test_check_public_host_rejects_empty_and_overlong_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, check_public_host("example..com"), PublicHostError.EmptyLabel)
	testing.expect_value(t, check_public_host(".example.com"), PublicHostError.EmptyLabel)
	testing.expect_value(t, check_public_host("example.com.."), PublicHostError.EmptyLabel)
	label64 := label_of('a', MAX_DNS_LABEL_LEN + 1)
	defer delete(label64)
	overlong := concat_host(label64, ".com")
	defer delete(overlong)
	testing.expect_value(t, check_public_host(overlong), PublicHostError.LabelTooLong)
	label63 := label_of('a', MAX_DNS_LABEL_LEN)
	defer delete(label63)
	ok := concat_host(label63, ".com")
	defer delete(ok)
	testing.expect_value(t, check_public_host(ok), PublicHostError.None)
}

@(test)
test_check_public_host_rejects_hyphen_placement :: proc(t: ^testing.T) {
	testing.expect_value(t, check_public_host("-example.com"), PublicHostError.LeadingHyphen)
	testing.expect_value(t, check_public_host("example-.com"), PublicHostError.TrailingHyphen)
	testing.expect_value(t, check_public_host("foo-bar.com"), PublicHostError.None)
}

@(test)
test_check_public_host_rejects_illegal_characters :: proc(t: ^testing.T) {
	testing.expect_value(t, check_public_host("foo_bar.example.com"), PublicHostError.InvalidCharacter)
	testing.expect_value(t, check_public_host("foo bar.example.com"), PublicHostError.InvalidCharacter)
}

@(test)
test_check_public_host_rejects_wildcard :: proc(t: ^testing.T) {
	testing.expect_value(t, check_public_host("*.example.com"), PublicHostError.Wildcard)
	testing.expect_value(t, check_public_host("foo.*.example.com"), PublicHostError.Wildcard)
}

@(test)
test_check_public_host_rejects_ipv4_literal :: proc(t: ^testing.T) {
	testing.expect_value(t, check_public_host("127.0.0.1"), PublicHostError.IpLiteral)
	testing.expect_value(t, check_public_host("192.168.1.20"), PublicHostError.IpLiteral)
	testing.expect_value(t, check_public_host("127.0.0.1."), PublicHostError.IpLiteral)
	testing.expect_value(t, check_public_host("1.2.3.4.com"), PublicHostError.None)
}

@(test)
test_check_public_host_rejects_syntax :: proc(t: ^testing.T) {
	testing.expect_value(t, check_public_host("https://example.com"), PublicHostError.InvalidSyntax)
	testing.expect_value(t, check_public_host("example.com/path"), PublicHostError.InvalidSyntax)
	testing.expect_value(t, check_public_host("example.com?q=1"), PublicHostError.InvalidSyntax)
	testing.expect_value(t, check_public_host("example.com#frag"), PublicHostError.InvalidSyntax)
	testing.expect_value(t, check_public_host("user@example.com"), PublicHostError.InvalidSyntax)
	testing.expect_value(t, check_public_host("example.com:443"), PublicHostError.InvalidSyntax)
	testing.expect_value(t, check_public_host("[::1]"), PublicHostError.InvalidSyntax)
}

label_of :: proc(ch: u8, n: int, allocator := context.allocator) -> string {
	buf := make([]u8, n, allocator)
	for i in 0 ..< n {
		buf[i] = ch
	}
	return string(buf)
}

concat_host :: proc(a, b: string, allocator := context.allocator) -> string {
	buf := make([]u8, len(a) + len(b), allocator)
	copy(buf[0:], transmute([]u8)a)
	copy(buf[len(a):], transmute([]u8)b)
	return string(buf)
}

hostname_with_last_label_len :: proc(last_len: int, allocator := context.allocator) -> string {
	// 63 + 1 + 63 + 1 + 63 + 1 + last_len
	total := MAX_DNS_LABEL_LEN * 3 + 3 + last_len
	buf := make([]u8, total, allocator)
	i := 0
	for round in 0 ..< 3 {
		if round > 0 {
			buf[i] = '.'
			i += 1
		}
		for _ in 0 ..< MAX_DNS_LABEL_LEN {
			buf[i] = 'a'
			i += 1
		}
	}
	buf[i] = '.'
	i += 1
	for _ in 0 ..< last_len {
		buf[i] = 'b'
		i += 1
	}
	return string(buf)
}
