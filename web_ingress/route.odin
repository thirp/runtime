package web_ingress

import proto "../protocol"
import "core:strings"

parse_ingress_mode :: proc(value: string) -> (IngressMode, bool) {
	switch value {
	case "http":
		return .TerminateHttp, true
	case "tls_passthrough":
		return .TlsPassthrough, true
	}
	return {}, false
}

split_route_spec :: proc(spec: string) -> (host, rest: string, ok: bool) {
	eq := strings.index_byte(spec, '=')
	if eq <= 0 || eq >= len(spec) - 1 {
		return "", "", false
	}
	return spec[:eq], spec[eq + 1:], true
}

parse_ingress_route :: proc(
	spec: string,
	allocator := context.allocator,
) -> (
	route: IngressRoute,
	err: IngressError,
) {
	host_raw, rest, ok := split_route_spec(spec)
	if !ok {
		return {}, .InvalidConfiguration
	}
	service := rest
	mode := IngressMode.TerminateHttp
	colon := strings.index_byte(rest, ':')
	if colon >= 0 {
		service = rest[:colon]
		mode_str := rest[colon + 1:]
		parsed, mok := parse_ingress_mode(mode_str)
		if !mok {
			return {}, .InvalidConfiguration
		}
		mode = parsed
	}
	host, herr := make_public_host(host_raw, allocator)
	if herr != .None {
		return {}, public_host_error_to_ingress(herr)
	}
	if proto.check_service_id(service) != .None {
		public_host_destroy(host, allocator)
		return {}, .InvalidConfiguration
	}
	owned_sid, cerr := strings.clone(service, allocator)
	if cerr != .None {
		public_host_destroy(host, allocator)
		return {}, .Internal
	}
	return IngressRoute {
		public_host = host,
		service_id  = proto.ServiceId(owned_sid),
		mode        = mode,
	}, .None
}

lookup_ingress_route :: proc(routes: []IngressRoute, host: PublicHost) -> (IngressRoute, bool) {
	want := string(host)
	for route in routes {
		if string(route.public_host) == want {
			return route, true
		}
	}
	return {}, false
}

ingress_route_destroy :: proc(route: IngressRoute, allocator := context.allocator) {
	public_host_destroy(route.public_host, allocator)
	delete(string(route.service_id), allocator)
}

ingress_config_has_passthrough :: proc(config: IngressConfig) -> bool {
	for route in config.routes {
		if route.mode == .TlsPassthrough {
			return true
		}
	}
	return false
}

ingress_config_has_terminated :: proc(config: IngressConfig) -> bool {
	for route in config.routes {
		if route.mode == .TerminateHttp {
			return true
		}
	}
	return false
}

ingress_mode_label :: proc(mode: IngressMode) -> string {
	switch mode {
	case .TerminateHttp:
		return "http"
	case .TlsPassthrough:
		return "tls_passthrough"
	}
	return "http"
}
