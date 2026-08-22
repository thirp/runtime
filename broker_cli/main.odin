package main

import auth "../auth"
import broker "../broker"
import cfg "../config"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import ver "../version"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"
import "core:thread"
import "core:time"

usage :: proc() {
	fmt.eprintf(
		"usage: thirp-broker [--version] [--config PATH] --listen HOST:PORT (--token TOKEN=PRINCIPAL[:ORG] | --token-file PATH) ...\n" +
		"       [--tls-cert PATH --tls-key PATH | --insecure]\n" +
		"       [--policy-mode development|production]\n" +
		"       [--capability PRINCIPAL=register|connect] [--allow-register PRINCIPAL=PATTERN]\n" +
		"       [--allow-connect PRINCIPAL=PATTERN] [--org-namespace ORG=PATTERN]\n" +
		"       [--max-stream-buffer BYTES] [--max-connection-buffer BYTES]\n" +
		"       [--max-streams-per-session N] [--max-registrations-per-session N]\n" +
		"       [--max-frame-size BYTES] [--max-connections N] [--max-connections-per-ip N]\n" +
		"       [--auth-rate-limit N] [--register-rate-limit N] [--connect-rate-limit N]\n" +
		"       [--max-buffered-bytes BYTES] [--stream-idle-timeout SECONDS]\n" +
		"       [--heartbeat-interval SECONDS] [--session-timeout SECONDS]\n" +
		"       [--shutdown-grace SECONDS] [--metrics-listen HOST:PORT] [--log-level LEVEL]\n",
	)
}

split_key_value :: proc(spec: string) -> (key, value: string, ok: bool) {
	eq := strings.index_byte(spec, '=')
	if eq <= 0 || eq >= len(spec) - 1 {
		return "", "", false
	}
	return spec[:eq], spec[eq + 1:], true
}

parse_capability_list :: proc(value: string) -> (caps: broker.PrincipalCapabilities, ok: bool) {
	if len(value) == 0 {
		return {}, false
	}
	start := 0
	for i := 0; i <= len(value); i += 1 {
		if i < len(value) && value[i] != ',' {
			continue
		}
		part := value[start:i]
		start = i + 1
		if len(part) == 0 {
			return {}, false
		}
		switch part {
		case "register":
			caps += {.RegisterService}
		case "connect":
			caps += {.ConnectService}
		case:
			return {}, false
		}
	}
	return caps, true
}

parse_nonneg_int :: proc(value: string) -> (int, bool) {
	n, ok := strconv.parse_int(value)
	if !ok || n < 0 {
		return 0, false
	}
	return n, true
}

require_flag_value :: proc(args: []string, i: int, flag: string) -> (string, int, bool) {
	if i + 1 >= len(args) {
		fmt.eprintf("%s requires a value\n", flag)
		return "", i, false
	}
	return args[i + 1], i + 1, true
}

main :: proc() {
	listen := ""
	insecure := false
	tls_cert := ""
	tls_key := ""
	token_specs: [dynamic]string
	defer delete(token_specs)
	token_files: [dynamic]string
	defer delete(token_files)
	max_stream_buffer := -1
	max_connection_buffer := -1
	max_streams_per_session := -1
	max_registrations_per_session := -1
	max_frame_size := -1
	max_connections := -1
	max_connections_per_ip := -1
	auth_rate_limit := -1
	register_rate_limit := -1
	connect_rate_limit := -1
	max_buffered_bytes := -1
	stream_idle_timeout := -1
	heartbeat_interval := -1
	session_timeout := -1
	shutdown_grace := -1
	metrics_listen := ""
	log_level_str := "info"
	log_level_set := false
	policy_mode_str := "development"
	policy_mode_set := false
	config_path := ""
	capability_specs: [dynamic]string
	defer delete(capability_specs)
	register_grant_specs: [dynamic]string
	defer delete(register_grant_specs)
	connect_grant_specs: [dynamic]string
	defer delete(connect_grant_specs)
	org_namespace_specs: [dynamic]string
	defer delete(org_namespace_specs)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--insecure":
			insecure = true
		case "--tls-cert":
			value, next, ok := require_flag_value(args, i, "--tls-cert")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			tls_cert = value
		case "--tls-key":
			value, next, ok := require_flag_value(args, i, "--tls-key")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			tls_key = value
		case "--listen":
			value, next, ok := require_flag_value(args, i, "--listen")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			listen = value
		case "--token":
			value, next, ok := require_flag_value(args, i, "--token")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			append(&token_specs, value)
		case "--token-file":
			value, next, ok := require_flag_value(args, i, "--token-file")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			append(&token_files, value)
		case "--config":
			value, next, ok := require_flag_value(args, i, "--config")
			if !ok {
				usage()
				os.exit(1)
			}
			if len(config_path) > 0 {
				fmt.eprintf("--config may be set once\n")
				os.exit(1)
			}
			i = next
			config_path = value
		case "--policy-mode":
			value, next, ok := require_flag_value(args, i, "--policy-mode")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			policy_mode_str = value
			policy_mode_set = true
		case "--capability":
			value, next, ok := require_flag_value(args, i, "--capability")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			append(&capability_specs, value)
		case "--allow-register":
			value, next, ok := require_flag_value(args, i, "--allow-register")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			append(&register_grant_specs, value)
		case "--allow-connect":
			value, next, ok := require_flag_value(args, i, "--allow-connect")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			append(&connect_grant_specs, value)
		case "--org-namespace":
			value, next, ok := require_flag_value(args, i, "--org-namespace")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			append(&org_namespace_specs, value)
		case "--max-stream-buffer":
			value, next, ok := require_flag_value(args, i, "--max-stream-buffer")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_stream_buffer, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-stream-buffer\n")
				os.exit(1)
			}
		case "--max-connection-buffer":
			value, next, ok := require_flag_value(args, i, "--max-connection-buffer")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_connection_buffer, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-connection-buffer\n")
				os.exit(1)
			}
		case "--max-streams-per-session":
			value, next, ok := require_flag_value(args, i, "--max-streams-per-session")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_streams_per_session, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-streams-per-session\n")
				os.exit(1)
			}
		case "--max-registrations-per-session":
			value, next, ok := require_flag_value(args, i, "--max-registrations-per-session")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_registrations_per_session, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-registrations-per-session\n")
				os.exit(1)
			}
		case "--max-frame-size":
			value, next, ok := require_flag_value(args, i, "--max-frame-size")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_frame_size, ok = parse_nonneg_int(value)
			if !ok || max_frame_size <= 0 || max_frame_size > int(proto.MAX_FRAME_PAYLOAD) {
				fmt.eprintf("invalid --max-frame-size, expected 1..%d\n", int(proto.MAX_FRAME_PAYLOAD))
				os.exit(1)
			}
		case "--max-connections":
			value, next, ok := require_flag_value(args, i, "--max-connections")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_connections, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-connections\n")
				os.exit(1)
			}
		case "--max-connections-per-ip":
			value, next, ok := require_flag_value(args, i, "--max-connections-per-ip")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_connections_per_ip, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-connections-per-ip\n")
				os.exit(1)
			}
		case "--auth-rate-limit":
			value, next, ok := require_flag_value(args, i, "--auth-rate-limit")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			auth_rate_limit, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --auth-rate-limit\n")
				os.exit(1)
			}
		case "--register-rate-limit":
			value, next, ok := require_flag_value(args, i, "--register-rate-limit")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			register_rate_limit, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --register-rate-limit\n")
				os.exit(1)
			}
		case "--connect-rate-limit":
			value, next, ok := require_flag_value(args, i, "--connect-rate-limit")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			connect_rate_limit, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --connect-rate-limit\n")
				os.exit(1)
			}
		case "--max-buffered-bytes":
			value, next, ok := require_flag_value(args, i, "--max-buffered-bytes")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			max_buffered_bytes, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-buffered-bytes\n")
				os.exit(1)
			}
		case "--stream-idle-timeout":
			value, next, ok := require_flag_value(args, i, "--stream-idle-timeout")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			stream_idle_timeout, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --stream-idle-timeout\n")
				os.exit(1)
			}
		case "--heartbeat-interval":
			value, next, ok := require_flag_value(args, i, "--heartbeat-interval")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			heartbeat_interval, ok = parse_nonneg_int(value)
			if !ok || heartbeat_interval <= 0 {
				fmt.eprintf("invalid --heartbeat-interval\n")
				os.exit(1)
			}
		case "--session-timeout":
			value, next, ok := require_flag_value(args, i, "--session-timeout")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			session_timeout, ok = parse_nonneg_int(value)
			if !ok || session_timeout <= 0 {
				fmt.eprintf("invalid --session-timeout\n")
				os.exit(1)
			}
		case "--shutdown-grace":
			value, next, ok := require_flag_value(args, i, "--shutdown-grace")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			shutdown_grace, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --shutdown-grace\n")
				os.exit(1)
			}
		case "--metrics-listen":
			value, next, ok := require_flag_value(args, i, "--metrics-listen")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			metrics_listen = value
		case "--log-level":
			value, next, ok := require_flag_value(args, i, "--log-level")
			if !ok {
				usage()
				os.exit(1)
			}
			i = next
			log_level_str = value
			log_level_set = true
		case "--version":
			line := ver.version_line("thirp-broker")
			fmt.printf("%s\n", line)
			delete(line)
			os.exit(0)
		case "-h", "--help":
			usage()
			os.exit(0)
		case:
			fmt.eprintf("unknown flag: %s\n", args[i])
			usage()
			os.exit(1)
		}
	}

	issues := make([dynamic]cfg.ValidationIssue)
	defer cfg.issues_destroy(issues)
	file: cfg.BrokerSettings
	if len(config_path) > 0 {
		doc, derr := cfg.parse_ini_file(config_path)
		if derr != .None {
			print_config_read_error(derr)
			os.exit(1)
		}
		defer cfg.ini_document_destroy(&doc)
		loaded, lerr := cfg.broker_settings_from_ini(doc, &issues)
		file = loaded
		if lerr != .None && lerr != .UnknownKey && lerr != .DuplicateKey && lerr != .InvalidValue {
			print_config_issues(issues[:])
			os.exit(1)
		}
	} else {
		cfg.broker_settings_init(&file)
	}
	defer cfg.broker_settings_destroy(&file)
	flags := broker_flags_from_cli(
		listen,
		tls_cert,
		tls_key,
		insecure,
		policy_mode_str,
		policy_mode_set,
		token_specs[:],
		token_files[:],
		capability_specs[:],
		register_grant_specs[:],
		connect_grant_specs[:],
		org_namespace_specs[:],
		max_stream_buffer,
		max_connection_buffer,
		max_streams_per_session,
		max_registrations_per_session,
		max_frame_size,
		max_connections,
		max_connections_per_ip,
		auth_rate_limit,
		register_rate_limit,
		connect_rate_limit,
		max_buffered_bytes,
		stream_idle_timeout,
		heartbeat_interval,
		session_timeout,
		shutdown_grace,
		metrics_listen,
		log_level_str,
		log_level_set,
	)
	defer cfg.broker_settings_destroy(&flags)
	settings, merr := cfg.settings_merge_broker(file, flags)
	if merr != .None {
		fmt.eprintf("failed to merge configuration\n")
		os.exit(1)
	}
	defer cfg.broker_settings_destroy(&settings)
	_ = cfg.broker_settings_validate(settings, &issues)
	if insecure && (len(tls_cert) > 0 || len(tls_key) > 0) {
		_ = cfg.append_issue(&issues, 0, "--insecure", "cannot be combined with --tls-cert or --tls-key")
	}
	if len(issues) > 0 {
		print_config_issues(issues[:])
		os.exit(1)
	}

	listen = settings.listen.value
	insecure = settings.insecure.set && settings.insecure.value
	tls_cert = settings.tls_cert.value
	tls_key = settings.tls_key.value
	metrics_listen = settings.metrics_listen.value
	if settings.policy_mode.set {
		policy_mode_str = settings.policy_mode.value
	} else {
		policy_mode_str = "development"
	}
	if settings.log_level.set {
		log_level_str = settings.log_level.value
	} else {
		log_level_str = "info"
	}

	ep, eerr := trans.parse_endpoint(listen)
	if eerr != .None {
		fmt.eprintf("invalid listen address\n")
		os.exit(1)
	}

	store: auth.StaticTokenAuth
	if auth.auth_init(&store) != .None {
		fmt.eprintf("failed to init authenticator\n")
		os.exit(1)
	}
	defer auth.auth_destroy(&store)

	add_credential_spec :: proc(store: ^auth.StaticTokenAuth, spec: auth.CredentialSpec) -> bool {
		if auth.auth_add_credential(store, spec) != .None {
			fmt.eprintf("invalid token mapping\n")
			return false
		}
		return true
	}

	for spec in settings.tokens {
		parsed, skip, perr := auth.parse_credential_line(spec.value)
		if skip || perr != .None {
			fmt.eprintf("invalid token mapping\n")
			os.exit(1)
		}
		if !add_credential_spec(&store, parsed) {
			os.exit(1)
		}
	}
	for tf in settings.token_files {
		if auth.file_group_or_world_readable(tf.value) {
			fmt.eprintf("WARNING: token file is group- or world-readable; prefer mode 0600\n")
		}
		loaded, lerr := auth.load_credential_file(tf.value)
		if lerr != .None {
			fmt.eprintf("failed to load token file\n")
			os.exit(1)
		}
		added := true
		for spec in loaded {
			if !add_credential_spec(&store, spec) {
				added = false
				break
			}
		}
		auth.credential_specs_destroy(loaded)
		if !added {
			os.exit(1)
		}
	}

	reg: broker.Registry
	if broker.registry_init(&reg) != .None {
		fmt.eprintf("failed to init registry\n")
		os.exit(1)
	}
	defer broker.registry_destroy(&reg)

	server: broker.Server
	broker.server_init(&server, &reg, auth.static_token_authenticator(&store))
	switch policy_mode_str {
	case "development":
		server.policy_mode = .Development
	case "production":
		server.policy_mode = .Production
		server.may_register = nil
		server.may_connect = nil
	}
	for spec in settings.capabilities {
		principal, value, ok := split_key_value(spec.value)
		if !ok {
			fmt.eprintf("invalid capability\n")
			os.exit(1)
		}
		caps, cok := parse_capability_list(value)
		if !cok {
			fmt.eprintf("invalid capability\n")
			os.exit(1)
		}
		merged_caps := broker.policy_capabilities(&server.policy, principal) + caps
		if broker.policy_set_capabilities(&server.policy, principal, merged_caps) != .None {
			fmt.eprintf("invalid capability principal\n")
			os.exit(1)
		}
	}
	for spec in settings.allow_register {
		principal, pattern, ok := split_key_value(spec.value)
		if !ok || broker.policy_add_namespace_grant(&server.policy, principal, pattern) != .None {
			fmt.eprintf("invalid allow_register pattern\n")
			os.exit(1)
		}
	}
	for spec in settings.allow_connect {
		principal, pattern, ok := split_key_value(spec.value)
		if !ok || broker.policy_add_connect_grant(&server.policy, principal, pattern) != .None {
			fmt.eprintf("invalid allow_connect pattern\n")
			os.exit(1)
		}
	}
	for spec in settings.org_namespace {
		org, pattern, ok := split_key_value(spec.value)
		if !ok || broker.policy_add_org_namespace(&server.policy, org, pattern) != .None {
			fmt.eprintf("invalid org_namespace pattern\n")
			os.exit(1)
		}
	}
	if settings.max_stream_buffer.set {
		server.max_stream_buffer = settings.max_stream_buffer.value
	}
	if settings.max_connection_buffer.set {
		server.max_connection_buffer = settings.max_connection_buffer.value
	}
	if settings.max_streams_per_session.set {
		server.max_streams_per_session = settings.max_streams_per_session.value
	}
	if settings.max_registrations_per_session.set {
		reg.max_registrations_per_session = settings.max_registrations_per_session.value
	}
	if settings.max_frame_size.set {
		server.max_frame_payload = u32(settings.max_frame_size.value)
	}
	if settings.max_connections.set {
		server.max_physical_connections = settings.max_connections.value
	}
	if settings.max_connections_per_ip.set {
		server.max_connections_per_ip = settings.max_connections_per_ip.value
	}
	if settings.auth_rate_limit.set {
		server.auth_rate = broker.rate_limit_config(settings.auth_rate_limit.value, broker.DEFAULT_RATE_LIMIT_WINDOW)
	}
	if settings.register_rate_limit.set {
		server.register_rate = broker.rate_limit_config(settings.register_rate_limit.value, broker.DEFAULT_RATE_LIMIT_WINDOW)
	}
	if settings.connect_rate_limit.set {
		server.connect_rate = broker.rate_limit_config(settings.connect_rate_limit.value, broker.DEFAULT_RATE_LIMIT_WINDOW)
	}
	if settings.max_buffered_bytes.set {
		server.max_buffered_bytes = settings.max_buffered_bytes.value
	}
	if settings.stream_idle_timeout.set {
		server.stream_idle_timeout = time.Duration(settings.stream_idle_timeout.value) * time.Second
	}
	if settings.heartbeat_interval.set {
		server.heartbeat_interval = time.Duration(settings.heartbeat_interval.value) * time.Second
	}
	if settings.session_timeout.set {
		server.session_timeout = time.Duration(settings.session_timeout.value) * time.Second
	}
	if settings.shutdown_grace.set {
		server.shutdown_grace = time.Duration(settings.shutdown_grace.value) * time.Second
	}
	level, lok := log.log_level_from_string(log_level_str)
	if !lok {
		fmt.eprintf("invalid log level\n")
		os.exit(1)
	}
	logger: log.Logger
	log.logger_init(&logger, level)
	server.logger = &logger
	if !insecure {
		ctx, terr := trans.tls_server_context_init(tls_cert, tls_key)
		if terr != .None {
			fmt.eprintf("failed to load TLS certificate or key\n")
			os.exit(1)
		}
		server.tls_ctx = ctx
	}
	if serr := broker.server_listen(&server, ep); serr != .None {
		fmt.eprintf("listen failed\n")
		os.exit(1)
	}
	bound, _ := broker.server_endpoint(&server)
	if insecure {
		fmt.printf("thirp-broker listening on %s (--insecure)\n", net.endpoint_to_string(bound))
	} else {
		fmt.printf("thirp-broker listening on %s\n", net.endpoint_to_string(bound))
	}
	if server.policy_mode == .Development {
		fmt.eprintf(
			"WARNING: development policy enabled: authenticated principals may register and connect (allow-all). Do not use this mode on an Internet-reachable host.\n",
		)
	}
	if server.policy_mode == .Production && len(settings.tokens) > 0 {
		fmt.eprintf(
			"WARNING: --token puts the credential in the process listing and shell history. Prefer --token-file.\n",
		)
	}
	if settings.metrics_listen.set {
		mep, merr := trans.parse_endpoint(metrics_listen)
		if merr != .None {
			fmt.eprintf("invalid metrics listen address\n")
			os.exit(1)
		}
		if broker.server_metrics_listen(&server, mep) != .None {
			fmt.eprintf("metrics listen failed\n")
			os.exit(1)
		}
		broker.server_metrics_start(&server)
		mbound, _ := broker.server_metrics_endpoint(&server)
		fmt.printf("metrics on http://%s/metrics (/healthz /readyz)\n", net.endpoint_to_string(mbound))
	}

	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	waiter := SignalWaiter {
		server = &server,
		set    = set,
	}
	th := thread.create_and_start_with_poly_data(&waiter, signal_wait_proc)
	_ = th
	broker.server_serve(&server)
	broker.server_drain(&server, server.shutdown_grace)
	_ = broker.server_wait_idle(&server, server.shutdown_grace + 2 * time.Second)
	broker.server_destroy(&server)
}

SignalWaiter :: struct {
	server: ^broker.Server,
	set:    posix.sigset_t,
}

signal_wait_proc :: proc(w: ^SignalWaiter) {
	sig: posix.Signal
	_ = posix.sigwait(&w.set, &sig)
	w.server.stop = true
	if w.server.listening {
		trans.listener_close(&w.server.listener)
		w.server.listening = false
	}
}

print_config_read_error :: proc(err: cfg.ConfigError) {
	switch err {
	case .Io:
		fmt.eprintf("failed to read --config\n")
	case .Empty:
		fmt.eprintf("--config is empty\n")
	case .TooLarge:
		fmt.eprintf("--config is too large\n")
	case .InvalidLine:
		fmt.eprintf("--config has an invalid line\n")
	case .OutOfMemory:
		fmt.eprintf("out of memory\n")
	case .None, .UnknownKey, .DuplicateKey, .InvalidValue, .MissingRequired, .InsecureProduction:
		fmt.eprintf("failed to read --config\n")
	}
}

print_config_issues :: proc(issues: []cfg.ValidationIssue) {
	for issue in issues {
		text := cfg.format_issue(issue)
		fmt.eprintf("%s\n", text)
		delete(text)
	}
}

assign_cli_string :: proc(dst: ^cfg.SourcedString, value, flag: string) {
	if len(value) == 0 {
		return
	}
	if cfg.assign_sourced_string(dst, value, 0, flag) != .None {
		fmt.eprintf("out of memory\n")
		os.exit(1)
	}
}

append_cli_strings :: proc(dst: ^[dynamic]cfg.SourcedString, values: []string, flag: string) {
	for value in values {
		if cfg.append_sourced_string(dst, value, 0, flag) != .None {
			fmt.eprintf("out of memory\n")
			os.exit(1)
		}
	}
}

broker_flags_from_cli :: proc(
	listen: string,
	tls_cert: string,
	tls_key: string,
	insecure: bool,
	policy_mode_str: string,
	policy_mode_set: bool,
	token_specs: []string,
	token_files: []string,
	capability_specs: []string,
	register_grant_specs: []string,
	connect_grant_specs: []string,
	org_namespace_specs: []string,
	max_stream_buffer: int,
	max_connection_buffer: int,
	max_streams_per_session: int,
	max_registrations_per_session: int,
	max_frame_size: int,
	max_connections: int,
	max_connections_per_ip: int,
	auth_rate_limit: int,
	register_rate_limit: int,
	connect_rate_limit: int,
	max_buffered_bytes: int,
	stream_idle_timeout: int,
	heartbeat_interval: int,
	session_timeout: int,
	shutdown_grace: int,
	metrics_listen: string,
	log_level_str: string,
	log_level_set: bool,
) -> cfg.BrokerSettings {
	flags: cfg.BrokerSettings
	cfg.broker_settings_init(&flags)
	assign_cli_string(&flags.listen, listen, "--listen")
	assign_cli_string(&flags.tls_cert, tls_cert, "--tls-cert")
	assign_cli_string(&flags.tls_key, tls_key, "--tls-key")
	if insecure {
		flags.insecure = cfg.sourced_bool(true, 0, "--insecure")
	}
	if policy_mode_set {
		assign_cli_string(&flags.policy_mode, policy_mode_str, "--policy-mode")
	}
	append_cli_strings(&flags.tokens, token_specs, "--token")
	append_cli_strings(&flags.token_files, token_files, "--token-file")
	append_cli_strings(&flags.capabilities, capability_specs, "--capability")
	append_cli_strings(&flags.allow_register, register_grant_specs, "--allow-register")
	append_cli_strings(&flags.allow_connect, connect_grant_specs, "--allow-connect")
	append_cli_strings(&flags.org_namespace, org_namespace_specs, "--org-namespace")
	if max_stream_buffer >= 0 {
		flags.max_stream_buffer = cfg.sourced_int(max_stream_buffer, 0, "--max-stream-buffer")
	}
	if max_connection_buffer >= 0 {
		flags.max_connection_buffer = cfg.sourced_int(max_connection_buffer, 0, "--max-connection-buffer")
	}
	if max_streams_per_session >= 0 {
		flags.max_streams_per_session = cfg.sourced_int(max_streams_per_session, 0, "--max-streams-per-session")
	}
	if max_registrations_per_session >= 0 {
		flags.max_registrations_per_session = cfg.sourced_int(max_registrations_per_session, 0, "--max-registrations-per-session")
	}
	if max_frame_size >= 0 {
		flags.max_frame_size = cfg.sourced_int(max_frame_size, 0, "--max-frame-size")
	}
	if max_connections >= 0 {
		flags.max_connections = cfg.sourced_int(max_connections, 0, "--max-connections")
	}
	if max_connections_per_ip >= 0 {
		flags.max_connections_per_ip = cfg.sourced_int(max_connections_per_ip, 0, "--max-connections-per-ip")
	}
	if auth_rate_limit >= 0 {
		flags.auth_rate_limit = cfg.sourced_int(auth_rate_limit, 0, "--auth-rate-limit")
	}
	if register_rate_limit >= 0 {
		flags.register_rate_limit = cfg.sourced_int(register_rate_limit, 0, "--register-rate-limit")
	}
	if connect_rate_limit >= 0 {
		flags.connect_rate_limit = cfg.sourced_int(connect_rate_limit, 0, "--connect-rate-limit")
	}
	if max_buffered_bytes >= 0 {
		flags.max_buffered_bytes = cfg.sourced_int(max_buffered_bytes, 0, "--max-buffered-bytes")
	}
	if stream_idle_timeout >= 0 {
		flags.stream_idle_timeout = cfg.sourced_int(stream_idle_timeout, 0, "--stream-idle-timeout")
	}
	if heartbeat_interval > 0 {
		flags.heartbeat_interval = cfg.sourced_int(heartbeat_interval, 0, "--heartbeat-interval")
	}
	if session_timeout > 0 {
		flags.session_timeout = cfg.sourced_int(session_timeout, 0, "--session-timeout")
	}
	if shutdown_grace >= 0 {
		flags.shutdown_grace = cfg.sourced_int(shutdown_grace, 0, "--shutdown-grace")
	}
	assign_cli_string(&flags.metrics_listen, metrics_listen, "--metrics-listen")
	if log_level_set {
		assign_cli_string(&flags.log_level, log_level_str, "--log-level")
	}
	return flags
}
