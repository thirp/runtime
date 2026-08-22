package web_ingress

import proto "../protocol"
import "core:testing"

@(test)
test_parse_ingress_route_defaults_to_http :: proc(t: ^testing.T) {
	route, err := parse_ingress_route("portfolio-k7m4x2.web.example.com=acme/site-17/portfolio-ui")
	testing.expect_value(t, err, IngressError.None)
	defer ingress_route_destroy(route)
	testing.expect_value(t, string(route.public_host), "portfolio-k7m4x2.web.example.com")
	testing.expect_value(t, string(route.service_id), "acme/site-17/portfolio-ui")
	testing.expect_value(t, route.mode, IngressMode.TerminateHttp)
}

@(test)
test_parse_ingress_route_accepts_explicit_http_and_passthrough :: proc(t: ^testing.T) {
	http_route, herr := parse_ingress_route("web.example.com=demo/echo:http")
	testing.expect_value(t, herr, IngressError.None)
	defer ingress_route_destroy(http_route)
	testing.expect_value(t, http_route.mode, IngressMode.TerminateHttp)

	pass_route, perr := parse_ingress_route(
		"secure-k9p3.web.example.com=acme/site-17/secure-ui:tls_passthrough",
	)
	testing.expect_value(t, perr, IngressError.None)
	defer ingress_route_destroy(pass_route)
	testing.expect_value(t, pass_route.mode, IngressMode.TlsPassthrough)
	testing.expect_value(t, string(pass_route.public_host), "secure-k9p3.web.example.com")
}

@(test)
test_parse_ingress_route_canonicalizes_host :: proc(t: ^testing.T) {
	route, err := parse_ingress_route("Example.COM.=demo/echo")
	testing.expect_value(t, err, IngressError.None)
	defer ingress_route_destroy(route)
	testing.expect_value(t, string(route.public_host), "example.com")
}

@(test)
test_parse_ingress_route_rejects_missing_equals :: proc(t: ^testing.T) {
	_, err := parse_ingress_route("web.example.com")
	testing.expect_value(t, err, IngressError.InvalidConfiguration)
	_, err = parse_ingress_route("=demo/echo")
	testing.expect_value(t, err, IngressError.InvalidConfiguration)
	_, err = parse_ingress_route("web.example.com=")
	testing.expect_value(t, err, IngressError.InvalidConfiguration)
}

@(test)
test_parse_ingress_route_rejects_malformed_mode :: proc(t: ^testing.T) {
	_, err := parse_ingress_route("web.example.com=demo/echo:")
	testing.expect_value(t, err, IngressError.InvalidConfiguration)
	_, err = parse_ingress_route("web.example.com=demo/echo:HTTP")
	testing.expect_value(t, err, IngressError.InvalidConfiguration)
	_, err = parse_ingress_route("web.example.com=demo/echo:tcp")
	testing.expect_value(t, err, IngressError.InvalidConfiguration)
}

@(test)
test_parse_ingress_route_rejects_invalid_service_id :: proc(t: ^testing.T) {
	_, err := parse_ingress_route("web.example.com=demo echo")
	testing.expect_value(t, err, IngressError.InvalidConfiguration)
	testing.expect_value(t, proto.check_service_id("demo echo"), proto.ServiceIdError.InvalidCharacter)
}

@(test)
test_lookup_ingress_route_matches_canonical_host :: proc(t: ^testing.T) {
	route, err := parse_ingress_route("Example.COM.=demo/echo")
	testing.expect_value(t, err, IngressError.None)
	defer ingress_route_destroy(route)
	routes := []IngressRoute{route}

	query, qerr := make_public_host("example.com")
	testing.expect_value(t, qerr, PublicHostError.None)
	defer public_host_destroy(query)
	found, ok := lookup_ingress_route(routes, query)
	testing.expect(t, ok)
	testing.expect_value(t, string(found.service_id), "demo/echo")

	upper, uerr := make_public_host("EXAMPLE.COM")
	testing.expect_value(t, uerr, PublicHostError.None)
	defer public_host_destroy(upper)
	found, ok = lookup_ingress_route(routes, upper)
	testing.expect(t, ok)
	testing.expect_value(t, string(found.public_host), "example.com")
}

@(test)
test_lookup_ingress_route_misses_unknown_host :: proc(t: ^testing.T) {
	route, err := parse_ingress_route("ingress.test=demo/echo")
	testing.expect_value(t, err, IngressError.None)
	defer ingress_route_destroy(route)
	routes := []IngressRoute{route}

	other, oerr := make_public_host("other.test")
	testing.expect_value(t, oerr, PublicHostError.None)
	defer public_host_destroy(other)
	_, ok := lookup_ingress_route(routes, other)
	testing.expect(t, !ok)
}

@(test)
test_parse_ingress_route_rejects_invalid_public_host :: proc(t: ^testing.T) {
	_, err := parse_ingress_route("*.example.com=demo/echo")
	testing.expect_value(t, err, IngressError.InvalidPublicHost)
	_, err = parse_ingress_route("127.0.0.1=demo/echo")
	testing.expect_value(t, err, IngressError.InvalidPublicHost)
}
