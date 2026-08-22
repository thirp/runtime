package main

import auth "../auth"
import cfg "../config"
import log "../logging"
import ver "../version"
import wi "../web_ingress"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:thread"

usage :: proc() {
	fmt.eprintf(
		"usage: thirp-web-ingress [--version] [--config PATH] --listen HOST:PORT --broker HOST:PORT\n" +
		"       (--token TOKEN | --token-file PATH) --route HOST=SERVICE_ID[:MODE] ...\n" +
		"       [--tls-cert PATH --tls-key PATH | --insecure]\n" +
		"       [--tls-ca PATH] [--tls-server-name NAME | --insecure-broker]\n" +
		"       [--max-connections N] [--max-connections-per-ip N]\n" +
		"       [--max-client-hello-bytes BYTES] [--client-hello-timeout SECONDS]\n" +
		"       [--broker-dial-timeout SECONDS] [--idle-timeout SECONDS]\n" +
		"       [--shutdown-grace SECONDS] [--metrics-listen HOST:PORT] [--log-level LEVEL]\n",
	)
}

require_flag_value :: proc(args: []string, i: int, flag: string) -> (string, int, bool) {
	if i + 1 >= len(args) {
		fmt.eprintf("%s requires a value\n", flag)
		return "", i, false
	}
	return args[i + 1], i + 1, true
}

parse_nonneg_int :: proc(value: string) -> (int, bool) {
	n, ok := strconv.parse_int(value)
	if !ok || n < 0 {
		return 0, false
	}
	return n, true
}

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	config_path := ""
	listen := ""
	broker := ""
	token := ""
	token_file := ""
	tls_cert := ""
	tls_key := ""
	tls_ca := ""
	tls_server_name := ""
	metrics_listen := ""
	log_level := ""
	log_level_set := false
	insecure := false
	insecure_broker := false
	max_connections := -1
	max_connections_per_ip := -1
	max_client_hello_bytes := -1
	client_hello_timeout := -1
	broker_dial_timeout := -1
	idle_timeout := -1
	shutdown_grace := -1
	routes: [dynamic]string
	defer delete(routes)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--insecure":
			insecure = true
		case "--insecure-broker":
			insecure_broker = true
		case "--config":
			value, next, ok := require_flag_value(args, i, "--config")
			if !ok {
				usage()
				return 1
			}
			if len(config_path) > 0 {
				fmt.eprintf("--config may be set once\n")
				return 1
			}
			i = next
			config_path = value
		case "--listen":
			value, next, ok := require_flag_value(args, i, "--listen")
			if !ok {
				usage()
				return 1
			}
			i = next
			listen = value
		case "--broker":
			value, next, ok := require_flag_value(args, i, "--broker")
			if !ok {
				usage()
				return 1
			}
			i = next
			broker = value
		case "--token":
			value, next, ok := require_flag_value(args, i, "--token")
			if !ok {
				usage()
				return 1
			}
			i = next
			token = value
		case "--token-file":
			value, next, ok := require_flag_value(args, i, "--token-file")
			if !ok {
				usage()
				return 1
			}
			i = next
			token_file = value
		case "--route":
			value, next, ok := require_flag_value(args, i, "--route")
			if !ok {
				usage()
				return 1
			}
			i = next
			append(&routes, value)
		case "--tls-cert":
			value, next, ok := require_flag_value(args, i, "--tls-cert")
			if !ok {
				usage()
				return 1
			}
			i = next
			tls_cert = value
		case "--tls-key":
			value, next, ok := require_flag_value(args, i, "--tls-key")
			if !ok {
				usage()
				return 1
			}
			i = next
			tls_key = value
		case "--tls-ca":
			value, next, ok := require_flag_value(args, i, "--tls-ca")
			if !ok {
				usage()
				return 1
			}
			i = next
			tls_ca = value
		case "--tls-server-name":
			value, next, ok := require_flag_value(args, i, "--tls-server-name")
			if !ok {
				usage()
				return 1
			}
			i = next
			tls_server_name = value
		case "--metrics-listen":
			value, next, ok := require_flag_value(args, i, "--metrics-listen")
			if !ok {
				usage()
				return 1
			}
			i = next
			metrics_listen = value
		case "--log-level":
			value, next, ok := require_flag_value(args, i, "--log-level")
			if !ok {
				usage()
				return 1
			}
			i = next
			log_level = value
			log_level_set = true
		case "--max-connections":
			value, next, ok := require_flag_value(args, i, "--max-connections")
			if !ok {
				usage()
				return 1
			}
			i = next
			max_connections, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-connections\n")
				return 1
			}
		case "--max-connections-per-ip":
			value, next, ok := require_flag_value(args, i, "--max-connections-per-ip")
			if !ok {
				usage()
				return 1
			}
			i = next
			max_connections_per_ip, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-connections-per-ip\n")
				return 1
			}
		case "--max-client-hello-bytes":
			value, next, ok := require_flag_value(args, i, "--max-client-hello-bytes")
			if !ok {
				usage()
				return 1
			}
			i = next
			max_client_hello_bytes, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --max-client-hello-bytes\n")
				return 1
			}
		case "--client-hello-timeout":
			value, next, ok := require_flag_value(args, i, "--client-hello-timeout")
			if !ok {
				usage()
				return 1
			}
			i = next
			client_hello_timeout, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --client-hello-timeout\n")
				return 1
			}
		case "--broker-dial-timeout":
			value, next, ok := require_flag_value(args, i, "--broker-dial-timeout")
			if !ok {
				usage()
				return 1
			}
			i = next
			broker_dial_timeout, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --broker-dial-timeout\n")
				return 1
			}
		case "--idle-timeout":
			value, next, ok := require_flag_value(args, i, "--idle-timeout")
			if !ok {
				usage()
				return 1
			}
			i = next
			idle_timeout, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --idle-timeout\n")
				return 1
			}
		case "--shutdown-grace":
			value, next, ok := require_flag_value(args, i, "--shutdown-grace")
			if !ok {
				usage()
				return 1
			}
			i = next
			shutdown_grace, ok = parse_nonneg_int(value)
			if !ok {
				fmt.eprintf("invalid --shutdown-grace\n")
				return 1
			}
		case "--version":
			line := ver.version_line("thirp-web-ingress")
			fmt.printf("%s\n", line)
			delete(line)
			return 0
		case "-h", "--help":
			usage()
			return 0
		case:
			fmt.eprintf("unknown flag: %s\n", args[i])
			usage()
			return 1
		}
	}

	issues := make([dynamic]cfg.ValidationIssue)
	defer cfg.issues_destroy(issues)
	file: wi.IngressSettings
	if len(config_path) > 0 {
		doc, derr := cfg.parse_ini_file(config_path)
		if derr != .None {
			print_config_read_error(derr)
			return 1
		}
		defer cfg.ini_document_destroy(&doc)
		loaded, lerr := wi.settings_from_ini(doc, &issues)
		file = loaded
		if lerr != .None && lerr != .UnknownKey && lerr != .DuplicateKey && lerr != .InvalidValue {
			print_config_issues(issues[:])
			return 1
		}
	} else {
		wi.settings_init(&file)
	}
	defer wi.settings_destroy(&file)

	flags: wi.IngressSettings
	wi.settings_init(&flags)
	defer wi.settings_destroy(&flags)
	assign_cli_string(&flags.listen, listen, "--listen")
	assign_cli_string(&flags.broker, broker, "--broker")
	assign_cli_string(&flags.token, token, "--token")
	assign_cli_string(&flags.token_file, token_file, "--token-file")
	assign_cli_string(&flags.tls_cert, tls_cert, "--tls-cert")
	assign_cli_string(&flags.tls_key, tls_key, "--tls-key")
	assign_cli_string(&flags.tls_ca, tls_ca, "--tls-ca")
	assign_cli_string(&flags.tls_server_name, tls_server_name, "--tls-server-name")
	assign_cli_string(&flags.metrics_listen, metrics_listen, "--metrics-listen")
	if log_level_set {
		assign_cli_string(&flags.log_level, log_level, "--log-level")
	}
	if insecure {
		flags.insecure = cfg.sourced_bool(true, 0, "--insecure")
	}
	if insecure_broker {
		flags.insecure_broker = cfg.sourced_bool(true, 0, "--insecure-broker")
	}
	if max_connections >= 0 {
		flags.max_connections = cfg.sourced_int(max_connections, 0, "--max-connections")
	}
	if max_connections_per_ip >= 0 {
		flags.max_connections_per_ip = cfg.sourced_int(max_connections_per_ip, 0, "--max-connections-per-ip")
	}
	if max_client_hello_bytes >= 0 {
		flags.max_client_hello_bytes = cfg.sourced_int(max_client_hello_bytes, 0, "--max-client-hello-bytes")
	}
	if client_hello_timeout >= 0 {
		flags.client_hello_timeout = cfg.sourced_int(client_hello_timeout, 0, "--client-hello-timeout")
	}
	if broker_dial_timeout >= 0 {
		flags.broker_dial_timeout = cfg.sourced_int(broker_dial_timeout, 0, "--broker-dial-timeout")
	}
	if idle_timeout >= 0 {
		flags.idle_timeout = cfg.sourced_int(idle_timeout, 0, "--idle-timeout")
	}
	if shutdown_grace >= 0 {
		flags.shutdown_grace = cfg.sourced_int(shutdown_grace, 0, "--shutdown-grace")
	}
	for spec in routes {
		if cfg.append_sourced_string(&flags.routes, spec, 0, "--route") != .None {
			fmt.eprintf("out of memory\n")
			return 1
		}
	}

	settings, merr := wi.settings_merge(file, flags)
	if merr != .None {
		fmt.eprintf("failed to merge configuration\n")
		return 1
	}
	defer wi.settings_destroy(&settings)

	config, _ := wi.validate_ingress_config(settings, &issues)
	if len(issues) > 0 {
		print_config_issues(issues[:])
		wi.ingress_config_destroy(&config)
		return 1
	}
	defer wi.ingress_config_destroy(&config)

	if len(config.token_file) > 0 {
		if auth.file_group_or_world_readable(config.token_file) {
			fmt.eprintf("WARNING: token file is group- or world-readable; prefer mode 0600\n")
		}
		secret, serr := auth.read_secret_file(config.token_file)
		if serr != .None {
			fmt.eprintf("failed to read token file\n")
			return 1
		}
		delete(config.token)
		config.token = secret
	} else if len(config.token) > 0 {
		fmt.eprintf(
			"WARNING: --token puts the credential in the process listing and shell history. Prefer --token-file.\n",
		)
	}

	logger: log.Logger
	log.logger_init(&logger, config.log_level)

	server: wi.IngressServer
	if wi.ingress_server_init(&server, config, &logger) != .None {
		fmt.eprintf("failed to start thirp-web-ingress\n")
		return 1
	}
	defer wi.ingress_server_destroy(&server)

	bound, _ := wi.ingress_server_endpoint(&server)
	fmt.printf("thirp-web-ingress listening on %s\n", net.endpoint_to_string(bound))
	if mep, merr := wi.ingress_metrics_endpoint(&server); merr == .None {
		fmt.printf("thirp-web-ingress metrics on %s\n", net.endpoint_to_string(mep))
	}

	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	waiter := IngressSignalWaiter {
		server = &server,
		set    = set,
	}
	th := thread.create_and_start_with_poly_data(&waiter, ingress_signal_wait)
	_ = th
	wi.ingress_server_serve(&server)
	wi.ingress_server_drain(&server)
	return 0
}

IngressSignalWaiter :: struct {
	server: ^wi.IngressServer,
	set:    posix.sigset_t,
}

ingress_signal_wait :: proc(w: ^IngressSignalWaiter) {
	sig: posix.Signal
	_ = posix.sigwait(&w.set, &sig)
	wi.ingress_server_stop(w.server)
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
