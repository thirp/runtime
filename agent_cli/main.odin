package main

import ag "../agent"
import auth "../auth"
import cfg "../config"
import proto "../protocol"
import trans "../transport"
import log "../logging"
import ver "../version"
import "core:fmt"
import "core:net"
import "core:os"
import posix "core:sys/posix"
import "core:strings"
import "core:thread"

ServiceMapping :: struct {
	service: string,
	target:  string,
}

usage :: proc() {
	fmt.eprintf(
		"usage: thirp-agent [--version] [--config PATH] --broker HOST:PORT (--token TOKEN | --token-file PATH)\n" +
		"       (--map SERVICE_ID=HOST:PORT ... | --service SERVICE_ID --target HOST:PORT)\n" +
		"       [--tls-ca PATH] [--tls-server-name NAME | --insecure]\n",
	)
}

split_map_spec :: proc(spec: string) -> (service, target: string, ok: bool) {
	eq := strings.index_byte(spec, '=')
	if eq <= 0 || eq + 1 >= len(spec) {
		return "", "", false
	}
	return spec[:eq], spec[eq + 1:], true
}

mapping_exists :: proc(mappings: []ServiceMapping, service: string) -> bool {
	for m in mappings {
		if m.service == service {
			return true
		}
	}
	return false
}

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	broker := ""
	token := ""
	token_file := ""
	service := ""
	target := ""
	insecure := false
	tls_ca := ""
	tls_server_name := ""
	config_path := ""
	mappings: [dynamic]ServiceMapping
	defer delete(mappings)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--insecure":
			insecure = true
		case "--tls-ca":
			if i + 1 >= len(args) {
				fmt.eprintf("--tls-ca requires PATH\n")
				usage()
				return 1
			}
			i += 1
			tls_ca = args[i]
		case "--tls-server-name":
			if i + 1 >= len(args) {
				fmt.eprintf("--tls-server-name requires NAME\n")
				usage()
				return 1
			}
			i += 1
			tls_server_name = args[i]
		case "--config":
			if i + 1 >= len(args) {
				fmt.eprintf("--config requires PATH\n")
				usage()
				return 1
			}
			if len(config_path) > 0 {
				fmt.eprintf("--config may be set once\n")
				return 1
			}
			i += 1
			config_path = args[i]
		case "--broker":
			if i + 1 >= len(args) {
				fmt.eprintf("--broker requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			broker = args[i]
		case "--token":
			if i + 1 >= len(args) {
				fmt.eprintf("--token requires TOKEN\n")
				usage()
				return 1
			}
			i += 1
			token = args[i]
		case "--token-file":
			if i + 1 >= len(args) {
				fmt.eprintf("--token-file requires PATH\n")
				usage()
				return 1
			}
			i += 1
			token_file = args[i]
		case "--service":
			if i + 1 >= len(args) {
				fmt.eprintf("--service requires SERVICE_ID\n")
				usage()
				return 1
			}
			i += 1
			service = args[i]
		case "--target":
			if i + 1 >= len(args) {
				fmt.eprintf("--target requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			target = args[i]
		case "--map":
			if i + 1 >= len(args) {
				fmt.eprintf("--map requires SERVICE_ID=HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			sid, dest, ok := split_map_spec(args[i])
			if !ok {
				fmt.eprintf("invalid --map, expected SERVICE_ID=HOST:PORT\n")
				return 1
			}
			if mapping_exists(mappings[:], sid) {
				fmt.eprintf("duplicate service id: %s\n", sid)
				return 1
			}
			append(&mappings, ServiceMapping{service = sid, target = dest})
		case "--version":
			line := ver.version_line("thirp-agent")
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
	file: cfg.AgentSettings
	if len(config_path) > 0 {
		doc, derr := cfg.parse_ini_file(config_path)
		if derr != .None {
			print_agent_config_read_error(derr)
			return 1
		}
		defer cfg.ini_document_destroy(&doc)
		loaded, lerr := cfg.agent_settings_from_ini(doc, &issues)
		file = loaded
		if lerr != .None && lerr != .UnknownKey && lerr != .DuplicateKey && lerr != .InvalidValue {
			print_agent_config_issues(issues[:])
			return 1
		}
	} else {
		cfg.agent_settings_init(&file)
	}
	defer cfg.agent_settings_destroy(&file)
	flags: cfg.AgentSettings
	cfg.agent_settings_init(&flags)
	defer cfg.agent_settings_destroy(&flags)
	if len(broker) > 0 {
		_ = cfg.assign_sourced_string(&flags.broker, broker, 0, "--broker")
	}
	if len(token) > 0 {
		_ = cfg.assign_sourced_string(&flags.token, token, 0, "--token")
	}
	if len(token_file) > 0 {
		_ = cfg.assign_sourced_string(&flags.token_file, token_file, 0, "--token-file")
	}
	if len(tls_ca) > 0 {
		_ = cfg.assign_sourced_string(&flags.tls_ca, tls_ca, 0, "--tls-ca")
	}
	if len(tls_server_name) > 0 {
		_ = cfg.assign_sourced_string(&flags.tls_server_name, tls_server_name, 0, "--tls-server-name")
	}
	if insecure {
		flags.insecure = cfg.sourced_bool(true, 0, "--insecure")
	}
	if len(service) > 0 {
		_ = cfg.assign_sourced_string(&flags.service, service, 0, "--service")
	}
	if len(target) > 0 {
		_ = cfg.assign_sourced_string(&flags.target, target, 0, "--target")
	}
	for m in mappings {
		spec := fmt.tprintf("%s=%s", m.service, m.target)
		_ = cfg.append_sourced_string(&flags.maps, spec, 0, "--map")
	}
	settings, merr := cfg.settings_merge_agent(file, flags)
	if merr != .None {
		fmt.eprintf("failed to merge configuration\n")
		return 1
	}
	defer cfg.agent_settings_destroy(&settings)
	_ = cfg.agent_settings_validate(settings, &issues)
	if len(issues) > 0 {
		print_agent_config_issues(issues[:])
		return 1
	}

	broker = settings.broker.value
	insecure = settings.insecure.set && settings.insecure.value
	tls_ca = settings.tls_ca.value
	tls_server_name = settings.tls_server_name.value
	if settings.token.set {
		token = settings.token.value
	}
	if settings.token_file.set {
		token_file = settings.token_file.value
	}
	if len(token_file) > 0 {
		if auth.file_group_or_world_readable(token_file) {
			fmt.eprintf("WARNING: token file is group- or world-readable; prefer mode 0600\n")
		}
		secret, serr := auth.read_secret_file(token_file)
		if serr != .None {
			fmt.eprintf("failed to read token file\n")
			return 1
		}
		token = secret
		defer delete(token)
	}

	clear(&mappings)
	for spec in settings.maps {
		sid, dest, ok := split_map_spec(spec.value)
		if !ok {
			fmt.eprintf("invalid map\n")
			return 1
		}
		append(&mappings, ServiceMapping{service = sid, target = dest})
	}
	if settings.service.set && settings.target.set {
		if mapping_exists(mappings[:], settings.service.value) {
			fmt.eprintf("duplicate service id: %s\n", settings.service.value)
			return 1
		}
		append(&mappings, ServiceMapping{service = settings.service.value, target = settings.target.value})
	}

	ep, eerr := trans.parse_endpoint(broker)
	if eerr != .None {
		fmt.eprintf("invalid broker address\n")
		return 1
	}

	ParsedMapping :: struct {
		service_id: proto.ServiceId,
		target:     net.Endpoint,
		service:    string,
	}
	parsed: [dynamic]ParsedMapping
	defer delete(parsed)
	invalid := false
	for m in mappings {
		service_id, sid_err := proto.make_service_id(m.service)
		if sid_err != .None {
			fmt.eprintf("invalid service id: %s\n", m.service)
			invalid = true
			continue
		}
		target_ep, terr := trans.parse_endpoint(m.target)
		if terr != .None || target_ep.port == 0 {
			fmt.eprintf("invalid target address: %s\n", m.target)
			invalid = true
			continue
		}
		append(&parsed, ParsedMapping{service_id = service_id, target = target_ep, service = m.service})
	}
	if invalid {
		return 1
	}

	logger: log.Logger
	log.logger_init(&logger, .Info)

	agent: ag.Agent
	aerr := ag.agent_init(
		&agent,
		ag.AgentConfig {
			broker          = ep,
			token           = token,
			insecure        = insecure,
			tls_ca          = tls_ca,
			tls_server_name = tls_server_name,
			implementation  = ag.DEFAULT_IMPLEMENTATION,
			logger          = &logger,
		},
	)
	if aerr != .None {
		fmt.eprintf("agent init failed\n")
		return 1
	}
	defer ag.agent_destroy(&agent)

	for m in parsed {
		if ag.register_service(&agent, m.service_id, ag.LocalTarget{address = m.target}) != .None {
			fmt.eprintf("register failed: %s\n", m.service)
			return 1
		}
	}

	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	waiter := AgentSignalWaiter{set = set, agent = &agent}
	_ = thread.create_and_start_with_poly_data(&waiter, agent_signal_wait)

	for m in parsed {
		fmt.printf("registered %s -> %s\n", m.service, net.endpoint_to_string(m.target))
	}
	_ = ag.agent_run(&agent)
	return 0
}

AgentSignalWaiter :: struct {
	set:   posix.sigset_t,
	agent: ^ag.Agent,
}

agent_signal_wait :: proc(w: ^AgentSignalWaiter) {
	sig: posix.Signal
	_ = posix.sigwait(&w.set, &sig)
	ag.agent_stop(w.agent)
}

print_agent_config_read_error :: proc(err: cfg.ConfigError) {
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

print_agent_config_issues :: proc(issues: []cfg.ValidationIssue) {
	for issue in issues {
		text := cfg.format_issue(issue)
		fmt.eprintf("%s\n", text)
		delete(text)
	}
}
