package web_ingress

import cfg "../config"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:mem"
import "core:net"
import "core:strings"
import "core:time"

settings_init :: proc(settings: ^IngressSettings, allocator := context.allocator) {
	settings^ = {}
	settings.allocator = allocator
	settings.routes = make([dynamic]cfg.SourcedString, allocator)
}

settings_destroy :: proc(settings: ^IngressSettings) {
	if settings == nil {
		return
	}
	alloc := settings.allocator
	cfg.destroy_sourced_string(settings.listen, alloc)
	cfg.destroy_sourced_string(settings.broker, alloc)
	cfg.destroy_sourced_string(settings.token, alloc)
	cfg.destroy_sourced_string(settings.token_file, alloc)
	cfg.destroy_sourced_list(settings.routes, alloc)
	cfg.destroy_sourced_string(settings.tls_cert, alloc)
	cfg.destroy_sourced_string(settings.tls_key, alloc)
	cfg.destroy_sourced_string(settings.tls_ca, alloc)
	cfg.destroy_sourced_string(settings.tls_server_name, alloc)
	cfg.destroy_sourced_string(settings.metrics_listen, alloc)
	cfg.destroy_sourced_string(settings.log_level, alloc)
	settings^ = {}
}

ingress_config_destroy :: proc(config: ^IngressConfig) {
	if config == nil {
		return
	}
	alloc := config.allocator
	delete(config.listen, alloc)
	delete(config.broker, alloc)
	delete(config.token, alloc)
	delete(config.token_file, alloc)
	for route in config.routes {
		ingress_route_destroy(route, alloc)
	}
	delete(config.routes, alloc)
	delete(config.tls_cert, alloc)
	delete(config.tls_key, alloc)
	delete(config.tls_ca, alloc)
	delete(config.tls_server_name, alloc)
	delete(config.metrics_listen, alloc)
	config^ = {}
}

settings_apply_entry :: proc(settings: ^IngressSettings, entry: cfg.IniEntry) -> cfg.ConfigError {
	alloc := settings.allocator
	switch entry.key {
	case "listen":
		return cfg.assign_sourced_string(&settings.listen, entry.value, entry.line, "", alloc)
	case "broker":
		return cfg.assign_sourced_string(&settings.broker, entry.value, entry.line, "", alloc)
	case "token":
		return cfg.assign_sourced_string(&settings.token, entry.value, entry.line, "", alloc)
	case "token_file":
		return cfg.assign_sourced_string(&settings.token_file, entry.value, entry.line, "", alloc)
	case "route":
		return cfg.append_sourced_string(&settings.routes, entry.value, entry.line, "", alloc)
	case "tls_cert":
		return cfg.assign_sourced_string(&settings.tls_cert, entry.value, entry.line, "", alloc)
	case "tls_key":
		return cfg.assign_sourced_string(&settings.tls_key, entry.value, entry.line, "", alloc)
	case "tls_ca":
		return cfg.assign_sourced_string(&settings.tls_ca, entry.value, entry.line, "", alloc)
	case "tls_server_name":
		return cfg.assign_sourced_string(&settings.tls_server_name, entry.value, entry.line, "", alloc)
	case "insecure":
		return cfg.assign_sourced_bool(&settings.insecure, entry.value, entry.line, "")
	case "insecure_broker":
		return cfg.assign_sourced_bool(&settings.insecure_broker, entry.value, entry.line, "")
	case "max_connections":
		return cfg.assign_sourced_int(&settings.max_connections, entry.value, entry.line, "")
	case "max_connections_per_ip":
		return cfg.assign_sourced_int(&settings.max_connections_per_ip, entry.value, entry.line, "")
	case "max_client_hello_bytes":
		return cfg.assign_sourced_int(&settings.max_client_hello_bytes, entry.value, entry.line, "")
	case "client_hello_timeout":
		return cfg.assign_sourced_int(&settings.client_hello_timeout, entry.value, entry.line, "")
	case "broker_dial_timeout":
		return cfg.assign_sourced_int(&settings.broker_dial_timeout, entry.value, entry.line, "")
	case "idle_timeout":
		return cfg.assign_sourced_int(&settings.idle_timeout, entry.value, entry.line, "")
	case "shutdown_grace":
		return cfg.assign_sourced_int(&settings.shutdown_grace, entry.value, entry.line, "")
	case "metrics_listen":
		return cfg.assign_sourced_string(&settings.metrics_listen, entry.value, entry.line, "", alloc)
	case "log_level":
		return cfg.assign_sourced_string(&settings.log_level, entry.value, entry.line, "", alloc)
	}
	return .UnknownKey
}

settings_from_ini :: proc(
	doc: cfg.IniDocument,
	issues: ^[dynamic]cfg.ValidationIssue,
	allocator := context.allocator,
) -> (
	settings: IngressSettings,
	err: cfg.ConfigError,
) {
	settings_init(&settings, allocator)
	had_error := cfg.ConfigError.None
	for entry in doc.entries {
		apply_err := settings_apply_entry(&settings, entry)
		if apply_err == .None {
			continue
		}
		msg := "invalid value"
		switch apply_err {
		case .UnknownKey:
			msg = "unknown key"
		case .DuplicateKey:
			msg = "duplicate key"
		case .InvalidValue:
			msg = "invalid value"
		case .OutOfMemory:
			settings_destroy(&settings)
			return {}, .OutOfMemory
		case .None, .Io, .Empty, .TooLarge, .InvalidLine, .MissingRequired, .InsecureProduction:
			msg = "invalid value"
		}
		if cfg.append_issue(issues, entry.line, "", msg, issues.allocator) != .None {
			settings_destroy(&settings)
			return {}, .OutOfMemory
		}
		if had_error == .None {
			had_error = apply_err
		}
	}
	return settings, had_error
}

settings_merge :: proc(
	file, flags: IngressSettings,
	allocator := context.allocator,
) -> (
	out: IngressSettings,
	err: cfg.ConfigError,
) {
	settings_init(&out, allocator)
	if cfg.copy_if_set_string(&out.listen, file.listen, allocator) != .None ||
	   cfg.copy_if_set_string(&out.broker, file.broker, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_cert, file.tls_cert, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_key, file.tls_key, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_ca, file.tls_ca, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_server_name, file.tls_server_name, allocator) != .None ||
	   cfg.copy_if_set_string(&out.metrics_listen, file.metrics_listen, allocator) != .None ||
	   cfg.copy_if_set_string(&out.log_level, file.log_level, allocator) != .None {
		settings_destroy(&out)
		return {}, .OutOfMemory
	}
	out.insecure = file.insecure
	out.insecure_broker = file.insecure_broker
	out.max_connections = file.max_connections
	out.max_connections_per_ip = file.max_connections_per_ip
	out.max_client_hello_bytes = file.max_client_hello_bytes
	out.client_hello_timeout = file.client_hello_timeout
	out.broker_dial_timeout = file.broker_dial_timeout
	out.idle_timeout = file.idle_timeout
	out.shutdown_grace = file.shutdown_grace
	if cfg.clone_sourced_list(file.routes[:], &out.routes, allocator) != .None ||
	   cfg.copy_if_set_string(&out.token, file.token, allocator) != .None ||
	   cfg.copy_if_set_string(&out.token_file, file.token_file, allocator) != .None {
		settings_destroy(&out)
		return {}, .OutOfMemory
	}

	if cfg.copy_if_set_string(&out.listen, flags.listen, allocator) != .None ||
	   cfg.copy_if_set_string(&out.broker, flags.broker, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_cert, flags.tls_cert, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_key, flags.tls_key, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_ca, flags.tls_ca, allocator) != .None ||
	   cfg.copy_if_set_string(&out.tls_server_name, flags.tls_server_name, allocator) != .None ||
	   cfg.copy_if_set_string(&out.metrics_listen, flags.metrics_listen, allocator) != .None ||
	   cfg.copy_if_set_string(&out.log_level, flags.log_level, allocator) != .None {
		settings_destroy(&out)
		return {}, .OutOfMemory
	}
	cfg.copy_if_set_bool(&out.insecure, flags.insecure)
	cfg.copy_if_set_bool(&out.insecure_broker, flags.insecure_broker)
	cfg.copy_if_set_int(&out.max_connections, flags.max_connections)
	cfg.copy_if_set_int(&out.max_connections_per_ip, flags.max_connections_per_ip)
	cfg.copy_if_set_int(&out.max_client_hello_bytes, flags.max_client_hello_bytes)
	cfg.copy_if_set_int(&out.client_hello_timeout, flags.client_hello_timeout)
	cfg.copy_if_set_int(&out.broker_dial_timeout, flags.broker_dial_timeout)
	cfg.copy_if_set_int(&out.idle_timeout, flags.idle_timeout)
	cfg.copy_if_set_int(&out.shutdown_grace, flags.shutdown_grace)
	if flags.token.set || flags.token_file.set {
		cfg.destroy_sourced_string(out.token, allocator)
		cfg.destroy_sourced_string(out.token_file, allocator)
		out.token = {}
		out.token_file = {}
		if cfg.copy_if_set_string(&out.token, flags.token, allocator) != .None ||
		   cfg.copy_if_set_string(&out.token_file, flags.token_file, allocator) != .None {
			settings_destroy(&out)
			return {}, .OutOfMemory
		}
	}
	for spec in flags.routes {
		remove_route_with_same_host(&out.routes, spec.value, allocator)
		cloned, cerr := cfg.clone_sourced_string(spec, allocator)
		if cerr != .None {
			settings_destroy(&out)
			return {}, .OutOfMemory
		}
		_, aerr := append(&out.routes, cloned)
		if aerr != .None {
			cfg.destroy_sourced_string(cloned, allocator)
			settings_destroy(&out)
			return {}, .OutOfMemory
		}
	}
	return out, .None
}

remove_route_with_same_host :: proc(
	routes: ^[dynamic]cfg.SourcedString,
	spec: string,
	allocator: mem.Allocator,
) {
	host_raw, _, ok := split_route_spec(spec)
	if !ok {
		return
	}
	flag_host, herr := make_public_host(host_raw, allocator)
	if herr != .None {
		return
	}
	defer public_host_destroy(flag_host, allocator)
	for i := 0; i < len(routes); i += 1 {
		existing_host, _, eok := split_route_spec(routes[i].value)
		if !eok {
			continue
		}
		file_host, ferr := make_public_host(existing_host, allocator)
		if ferr != .None {
			continue
		}
		same := string(file_host) == string(flag_host)
		public_host_destroy(file_host, allocator)
		if same {
			cfg.destroy_sourced_string(routes[i], allocator)
			ordered_remove(routes, i)
			return
		}
	}
}

validate_ingress_config :: proc(
	settings: IngressSettings,
	issues: ^[dynamic]cfg.ValidationIssue,
	allocator := context.allocator,
) -> (
	config: IngressConfig,
	err: IngressError,
) {
	validate_settings_fields(settings, issues)
	parsed: [dynamic]IngressRoute
	parsed.allocator = allocator
	destroy_parsed := true
	defer if destroy_parsed {
		for route in parsed {
			ingress_route_destroy(route, allocator)
		}
		delete(parsed)
	}

	seen: map[string]struct{}
	seen.allocator = allocator
	defer delete(seen)

	if len(settings.routes) == 0 {
		cfg.add_sourced_issue(issues, 0, "", "at least one route is required")
	}
	for spec in settings.routes {
		line, flag := cfg.issue_source(spec)
		append_route_issues(spec.value, line, flag, issues)
		route, rerr := parse_ingress_route(spec.value, allocator)
		if rerr != .None {
			continue
		}
		key := string(route.public_host)
		if _, exists := seen[key]; exists {
			cfg.add_sourced_issue(issues, line, flag, "duplicate route")
			ingress_route_destroy(route, allocator)
			continue
		}
		seen[key] = {}
		_, aerr := append(&parsed, route)
		if aerr != .None {
			ingress_route_destroy(route, allocator)
			return {}, .Internal
		}
	}

	validate_tls_and_insecure(settings, parsed[:], issues)

	if len(issues) > 0 {
		return {}, .InvalidConfiguration
	}
	built, berr := build_ingress_config(settings, parsed[:], allocator)
	if berr != .None {
		return {}, berr
	}
	destroy_parsed = false
	delete(parsed)
	return built, .None
}

validate_settings_fields :: proc(settings: IngressSettings, issues: ^[dynamic]cfg.ValidationIssue) {
	if !settings.listen.set {
		cfg.add_sourced_issue(issues, 0, "", "listen is required")
	} else if !cfg.check_host_port(settings.listen.value, true) {
		line, flag := cfg.issue_source(settings.listen)
		cfg.add_sourced_issue(issues, line, flag, "invalid address")
	}
	if !settings.broker.set {
		cfg.add_sourced_issue(issues, 0, "", "broker is required")
	} else if !cfg.check_host_port(settings.broker.value, false) {
		line, flag := cfg.issue_source(settings.broker)
		cfg.add_sourced_issue(issues, line, flag, "invalid address")
	}
	if settings.metrics_listen.set && !cfg.check_host_port(settings.metrics_listen.value, true) {
		line, flag := cfg.issue_source(settings.metrics_listen)
		cfg.add_sourced_issue(issues, line, flag, "invalid address")
	}
	token_set := settings.token.set
	file_set := settings.token_file.set
	if token_set == file_set {
		cfg.add_sourced_issue(issues, 0, "", "exactly one of token or token_file is required")
	}
	if settings.log_level.set {
		_, ok := log.log_level_from_string(settings.log_level.value)
		if !ok {
			line, flag := cfg.issue_source(settings.log_level)
			cfg.add_sourced_issue(issues, line, flag, "invalid log level")
		}
	}
	insecure_broker := settings.insecure_broker.set && settings.insecure_broker.value
	if insecure_broker && (settings.tls_ca.set || settings.tls_server_name.set) {
		line, flag := cfg.issue_source_bool(settings.insecure_broker)
		cfg.add_sourced_issue(issues, line, flag, "insecure_broker cannot be combined with tls_ca or tls_server_name")
	}
	check_positive_int(settings.max_connections, issues)
	check_positive_int(settings.max_connections_per_ip, issues)
	check_positive_int(settings.max_client_hello_bytes, issues)
	check_positive_int(settings.client_hello_timeout, issues)
	check_positive_int(settings.broker_dial_timeout, issues)
	check_positive_int(settings.shutdown_grace, issues)
	if settings.idle_timeout.set && settings.idle_timeout.value < 0 {
		line, flag := cfg.issue_source_int(settings.idle_timeout)
		cfg.add_sourced_issue(issues, line, flag, "invalid value")
	}
}

check_positive_int :: proc(src: cfg.SourcedInt, issues: ^[dynamic]cfg.ValidationIssue) {
	if src.set && src.value <= 0 {
		line, flag := cfg.issue_source_int(src)
		cfg.add_sourced_issue(issues, line, flag, "invalid value")
	}
}

append_route_issues :: proc(
	spec: string,
	line: int,
	flag: string,
	issues: ^[dynamic]cfg.ValidationIssue,
) {
	host, rest, ok := split_route_spec(spec)
	if !ok {
		cfg.add_sourced_issue(issues, line, flag, "invalid route")
		return
	}
	service := rest
	if colon := strings.index_byte(rest, ':'); colon >= 0 {
		service = rest[:colon]
		mode_str := rest[colon + 1:]
		if _, mok := parse_ingress_mode(mode_str); !mok {
			cfg.add_sourced_issue(issues, line, flag, "invalid mode")
		}
	}
	if check_public_host(host) != .None {
		cfg.add_sourced_issue(issues, line, flag, "invalid public host")
	}
	if proto.check_service_id(service) != .None {
		cfg.add_sourced_issue(issues, line, flag, "invalid service id")
	}
}

validate_tls_and_insecure :: proc(
	settings: IngressSettings,
	routes: []IngressRoute,
	issues: ^[dynamic]cfg.ValidationIssue,
) {
	insecure := settings.insecure.set && settings.insecure.value
	has_http := false
	for route in routes {
		if route.mode == .TerminateHttp {
			has_http = true
			break
		}
	}
	if insecure {
		if settings.tls_cert.set || settings.tls_key.set {
			line, flag := cfg.issue_source(settings.tls_cert)
			if !settings.tls_cert.set {
				line, flag = cfg.issue_source(settings.tls_key)
			}
			if line == 0 && flag == "" {
				line, flag = cfg.issue_source_bool(settings.insecure)
			}
			cfg.add_sourced_issue(issues, line, flag, "insecure cannot be combined with tls_cert or tls_key")
		}
		if settings.listen.set && !listen_is_loopback(settings.listen.value) {
			line, flag := cfg.issue_source(settings.listen)
			cfg.add_sourced_issue(issues, line, flag, "insecure requires a loopback listen address")
		}
		if len(settings.routes) != 1 {
			line, flag := cfg.issue_source_bool(settings.insecure)
			cfg.add_sourced_issue(issues, line, flag, "insecure requires exactly one route")
		}
	} else if has_http || route_specs_include_http(settings.routes[:]) {
		if !settings.tls_cert.set || !settings.tls_key.set {
			line, flag := cfg.issue_source(settings.tls_cert)
			if !settings.tls_cert.set {
				line, flag = cfg.issue_source(settings.tls_key)
			}
			cfg.add_sourced_issue(issues, line, flag, "tls required unless insecure")
		}
	}
}

route_specs_include_http :: proc(specs: []cfg.SourcedString) -> bool {
	for spec in specs {
		_, rest, ok := split_route_spec(spec.value)
		if !ok {
			continue
		}
		colon := strings.index_byte(rest, ':')
		if colon < 0 {
			return true
		}
		mode, mok := parse_ingress_mode(rest[colon + 1:])
		if mok && mode == .TerminateHttp {
			return true
		}
	}
	return false
}

listen_is_loopback :: proc(value: string) -> bool {
	ep, err := trans.parse_endpoint(value)
	if err == .None {
		return endpoint_is_loopback(ep)
	}
	colon := strings.last_index_byte(value, ':')
	if colon <= 0 {
		return false
	}
	host := value[:colon]
	if host == "localhost" || host == "127.0.0.1" || host == "::1" {
		return true
	}
	return false
}

endpoint_is_loopback :: proc(ep: net.Endpoint) -> bool {
	switch a in ep.address {
	case net.IP4_Address:
		return a[0] == 127
	case net.IP6_Address:
		return a == net.IP6_Loopback
	}
	return false
}

build_ingress_config :: proc(
	settings: IngressSettings,
	routes: []IngressRoute,
	allocator: mem.Allocator,
) -> (
	config: IngressConfig,
	err: IngressError,
) {
	config.allocator = allocator
	ok: bool
	config.listen, ok = clone_sourced(settings.listen, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.broker, ok = clone_sourced(settings.broker, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.token, ok = clone_sourced(settings.token, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.token_file, ok = clone_sourced(settings.token_file, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.tls_cert, ok = clone_sourced(settings.tls_cert, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.tls_key, ok = clone_sourced(settings.tls_key, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.tls_ca, ok = clone_sourced(settings.tls_ca, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.tls_server_name, ok = clone_sourced(settings.tls_server_name, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	config.metrics_listen, ok = clone_sourced(settings.metrics_listen, allocator)
	if !ok {
		ingress_config_destroy(&config)
		return {}, .Internal
	}
	owned_routes := make([]IngressRoute, len(routes), allocator)
	for i in 0 ..< len(routes) {
		owned_routes[i] = routes[i]
	}
	config.routes = owned_routes
	config.insecure = settings.insecure.set && settings.insecure.value
	config.insecure_broker = settings.insecure_broker.set && settings.insecure_broker.value
	config.limits = default_ingress_limits()
	if settings.max_connections.set {
		config.limits.max_connections = settings.max_connections.value
	}
	if settings.max_connections_per_ip.set {
		config.limits.max_connections_per_ip = settings.max_connections_per_ip.value
	}
	if settings.max_client_hello_bytes.set {
		config.limits.max_client_hello_bytes = settings.max_client_hello_bytes.value
	}
	if settings.client_hello_timeout.set {
		config.limits.client_hello_timeout = time.Duration(settings.client_hello_timeout.value) * time.Second
	}
	if settings.broker_dial_timeout.set {
		config.limits.broker_dial_timeout = time.Duration(settings.broker_dial_timeout.value) * time.Second
	}
	if settings.idle_timeout.set {
		config.limits.idle_timeout = time.Duration(settings.idle_timeout.value) * time.Second
	}
	config.shutdown_grace = DEFAULT_SHUTDOWN_GRACE_SECONDS * time.Second
	if settings.shutdown_grace.set {
		config.shutdown_grace = time.Duration(settings.shutdown_grace.value) * time.Second
	}
	config.log_level = .Info
	if settings.log_level.set {
		level, lok := log.log_level_from_string(settings.log_level.value)
		if lok {
			config.log_level = level
		}
	}
	return config, .None
}

clone_sourced :: proc(src: cfg.SourcedString, allocator: mem.Allocator) -> (string, bool) {
	if !src.set {
		return "", true
	}
	owned, err := strings.clone(src.value, allocator)
	if err != .None {
		return "", false
	}
	return owned, true
}
