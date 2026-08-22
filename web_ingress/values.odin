package web_ingress

import "core:strconv"
import "core:strings"
import "core:time"

MAX_PUBLIC_HOST_LEN :: 253
MAX_DNS_LABEL_LEN :: 63

DEFAULT_MAX_CONNECTIONS :: 4096
DEFAULT_MAX_CONNECTIONS_PER_IP :: 64
DEFAULT_MAX_CLIENT_HELLO_BYTES :: 65536
DEFAULT_CLIENT_HELLO_TIMEOUT_SECONDS :: 10
DEFAULT_BROKER_DIAL_TIMEOUT_SECONDS :: 10
DEFAULT_IDLE_TIMEOUT_SECONDS :: 300
DEFAULT_SHUTDOWN_GRACE_SECONDS :: 15
INGRESS_IMPLEMENTATION :: "thirp-web-ingress"
INGRESS_COPY_BUF :: 16 * 1024
ACCEPT_POLL_INTERVAL :: 50 * time.Millisecond
INGRESS_IDLE_POLL_SLICE :: 1 * time.Second
INGRESS_RETRY_POLL_SLICE :: 50 * time.Millisecond
METRICS_HTTP_TIMEOUT :: 2 * time.Second
METRICS_HTTP_MAX_REQUEST :: 4096
READYZ_READY :: "ready"
READYZ_NOT_READY :: "not_ready"
READYZ_DRAINING :: "draining"

default_ingress_limits :: proc() -> IngressLimits {
	return IngressLimits {
		max_connections        = DEFAULT_MAX_CONNECTIONS,
		max_connections_per_ip = DEFAULT_MAX_CONNECTIONS_PER_IP,
		max_client_hello_bytes = DEFAULT_MAX_CLIENT_HELLO_BYTES,
		client_hello_timeout   = DEFAULT_CLIENT_HELLO_TIMEOUT_SECONDS * time.Second,
		broker_dial_timeout    = DEFAULT_BROKER_DIAL_TIMEOUT_SECONDS * time.Second,
		idle_timeout           = DEFAULT_IDLE_TIMEOUT_SECONDS * time.Second,
	}
}

check_public_host :: proc(value: string) -> PublicHostError {
	buf: [MAX_PUBLIC_HOST_LEN]u8
	_, err := canonicalize_public_host(value, buf[:])
	return err
}

make_public_host :: proc(value: string, allocator := context.allocator) -> (PublicHost, PublicHostError) {
	buf: [MAX_PUBLIC_HOST_LEN]u8
	canonical, err := canonicalize_public_host(value, buf[:])
	if err != .None {
		return {}, err
	}
	owned, cerr := strings.clone(canonical, allocator)
	if cerr != .None {
		return {}, .OutOfMemory
	}
	return PublicHost(owned), .None
}

public_host_destroy :: proc(host: PublicHost, allocator := context.allocator) {
	delete(string(host), allocator)
}

canonicalize_public_host :: proc(value: string, buf: []u8) -> (canonical: string, err: PublicHostError) {
	if len(value) == 0 {
		return "", .Empty
	}
	for i in 0 ..< len(value) {
		b := value[i]
		switch b {
		case ':', '/', '?', '#', '@', '[', ']':
			return "", .InvalidSyntax
		case '*':
			return "", .Wildcard
		}
	}
	host := value
	if host[len(host) - 1] == '.' {
		host = host[:len(host) - 1]
	}
	if len(host) == 0 {
		return "", .Empty
	}
	if len(host) > MAX_PUBLIC_HOST_LEN {
		return "", .TooLong
	}
	if is_ipv4_literal(host) {
		return "", .IpLiteral
	}
	if len(buf) < len(host) {
		return "", .TooLong
	}
	for i in 0 ..< len(host) {
		buf[i] = ascii_lower(host[i])
	}
	canonical = string(buf[:len(host)])
	start := 0
	for i := 0; i <= len(canonical); i += 1 {
		if i < len(canonical) && canonical[i] != '.' {
			continue
		}
		label := canonical[start:i]
		start = i + 1
		if label_err := check_dns_label(label); label_err != .None {
			return "", label_err
		}
	}
	return canonical, .None
}

check_dns_label :: proc(label: string) -> PublicHostError {
	if len(label) == 0 {
		return .EmptyLabel
	}
	if len(label) > MAX_DNS_LABEL_LEN {
		return .LabelTooLong
	}
	if label[0] == '-' {
		return .LeadingHyphen
	}
	if label[len(label) - 1] == '-' {
		return .TrailingHyphen
	}
	for i in 0 ..< len(label) {
		b := label[i]
		switch b {
		case 'a' ..= 'z', '0' ..= '9', '-':
			continue
		case:
			return .InvalidCharacter
		}
	}
	return .None
}

is_ipv4_literal :: proc(host: string) -> bool {
	start := 0
	octets := 0
	dots := 0
	for i := 0; i <= len(host); i += 1 {
		if i < len(host) && host[i] != '.' {
			continue
		}
		if i < len(host) {
			dots += 1
		}
		if !is_decimal_octet(host[start:i]) {
			return false
		}
		octets += 1
		start = i + 1
	}
	return octets == 4 && dots == 3
}

is_decimal_octet :: proc(label: string) -> bool {
	if len(label) == 0 || len(label) > 3 {
		return false
	}
	for i in 0 ..< len(label) {
		if label[i] < '0' || label[i] > '9' {
			return false
		}
	}
	n, ok := strconv.parse_int(label)
	return ok && n >= 0 && n <= 255
}

ascii_lower :: proc(b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

public_host_error_to_ingress :: proc(err: PublicHostError) -> IngressError {
	#partial switch err {
	case .None:
		return .None
	case .OutOfMemory:
		return .Internal
	}
	return .InvalidPublicHost
}
