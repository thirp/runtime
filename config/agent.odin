package config

import proto "../protocol"

agent_settings_init :: proc(settings: ^AgentSettings, allocator := context.allocator) {
	settings^ = {}
	settings.allocator = allocator
	settings.maps = make([dynamic]SourcedString, allocator)
}

agent_settings_destroy :: proc(settings: ^AgentSettings) {
	if settings == nil {
		return
	}
	alloc := settings.allocator
	destroy_sourced_string(settings.broker, alloc)
	destroy_sourced_string(settings.token, alloc)
	destroy_sourced_string(settings.token_file, alloc)
	destroy_sourced_list(settings.maps, alloc)
	destroy_sourced_string(settings.service, alloc)
	destroy_sourced_string(settings.target, alloc)
	destroy_sourced_string(settings.tls_ca, alloc)
	destroy_sourced_string(settings.tls_server_name, alloc)
	settings^ = {}
}

agent_apply_entry :: proc(settings: ^AgentSettings, entry: IniEntry) -> ConfigError {
	alloc := settings.allocator
	switch entry.key {
	case "broker":
		return assign_sourced_string(&settings.broker, entry.value, entry.line, "", alloc)
	case "token":
		return assign_sourced_string(&settings.token, entry.value, entry.line, "", alloc)
	case "token_file":
		return assign_sourced_string(&settings.token_file, entry.value, entry.line, "", alloc)
	case "map":
		return append_sourced_string(&settings.maps, entry.value, entry.line, "", alloc)
	case "service":
		return assign_sourced_string(&settings.service, entry.value, entry.line, "", alloc)
	case "target":
		return assign_sourced_string(&settings.target, entry.value, entry.line, "", alloc)
	case "tls_ca":
		return assign_sourced_string(&settings.tls_ca, entry.value, entry.line, "", alloc)
	case "tls_server_name":
		return assign_sourced_string(&settings.tls_server_name, entry.value, entry.line, "", alloc)
	case "insecure":
		return assign_sourced_bool(&settings.insecure, entry.value, entry.line, "")
	}
	return .UnknownKey
}

agent_settings_from_ini :: proc(
	doc: IniDocument,
	issues: ^[dynamic]ValidationIssue,
	allocator := context.allocator,
) -> (
	settings: AgentSettings,
	err: ConfigError,
) {
	agent_settings_init(&settings, allocator)
	had_error := ConfigError.None
	for entry in doc.entries {
		apply_err := agent_apply_entry(&settings, entry)
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
			agent_settings_destroy(&settings)
			return {}, .OutOfMemory
		case .None, .Io, .Empty, .TooLarge, .InvalidLine, .MissingRequired, .InsecureProduction:
			msg = "invalid value"
		}
		if append_issue(issues, entry.line, "", msg, issues.allocator) != .None {
			agent_settings_destroy(&settings)
			return {}, .OutOfMemory
		}
		if had_error == .None {
			had_error = apply_err
		}
	}
	return settings, had_error
}

settings_merge_agent :: proc(file, flags: AgentSettings, allocator := context.allocator) -> (AgentSettings, ConfigError) {
	out: AgentSettings
	agent_settings_init(&out, allocator)
	if copy_if_set_string(&out.broker, file.broker, allocator) != .None ||
	   copy_if_set_string(&out.token, file.token, allocator) != .None ||
	   copy_if_set_string(&out.token_file, file.token_file, allocator) != .None ||
	   copy_if_set_string(&out.service, file.service, allocator) != .None ||
	   copy_if_set_string(&out.target, file.target, allocator) != .None ||
	   copy_if_set_string(&out.tls_ca, file.tls_ca, allocator) != .None ||
	   copy_if_set_string(&out.tls_server_name, file.tls_server_name, allocator) != .None {
		agent_settings_destroy(&out)
		return {}, .OutOfMemory
	}
	out.insecure = file.insecure
	if clone_sourced_list(file.maps[:], &out.maps, allocator) != .None {
		agent_settings_destroy(&out)
		return {}, .OutOfMemory
	}

	if copy_if_set_string(&out.broker, flags.broker, allocator) != .None ||
	   copy_if_set_string(&out.tls_ca, flags.tls_ca, allocator) != .None ||
	   copy_if_set_string(&out.tls_server_name, flags.tls_server_name, allocator) != .None ||
	   copy_if_set_string(&out.service, flags.service, allocator) != .None ||
	   copy_if_set_string(&out.target, flags.target, allocator) != .None {
		agent_settings_destroy(&out)
		return {}, .OutOfMemory
	}
	copy_if_set_bool(&out.insecure, flags.insecure)
	if flags.token.set || flags.token_file.set {
		destroy_sourced_string(out.token, allocator)
		destroy_sourced_string(out.token_file, allocator)
		out.token = {}
		out.token_file = {}
		if copy_if_set_string(&out.token, flags.token, allocator) != .None ||
		   copy_if_set_string(&out.token_file, flags.token_file, allocator) != .None {
			agent_settings_destroy(&out)
			return {}, .OutOfMemory
		}
	}
	for spec in flags.maps {
		service, _, ok := split_key_value(spec.value)
		if ok {
			for i := 0; i < len(out.maps); i += 1 {
				existing, _, eok := split_key_value(out.maps[i].value)
				if eok && existing == service {
					destroy_sourced_string(out.maps[i], allocator)
					ordered_remove(&out.maps, i)
					break
				}
			}
		}
		cloned, cerr := clone_sourced_string(spec, allocator)
		if cerr != .None {
			agent_settings_destroy(&out)
			return {}, .OutOfMemory
		}
		_, aerr := append(&out.maps, cloned)
		if aerr != .None {
			delete(cloned.value, allocator)
			agent_settings_destroy(&out)
			return {}, .OutOfMemory
		}
	}
	return out, .None
}

agent_settings_validate :: proc(settings: AgentSettings, issues: ^[dynamic]ValidationIssue) -> ConfigError {
	if !settings.broker.set {
		add_sourced_issue(issues, 0, "", "broker is required")
	} else if !check_host_port(settings.broker.value, false) {
		line, flag := issue_source(settings.broker)
		add_sourced_issue(issues, line, flag, "invalid address")
	}
	token_set := settings.token.set
	file_set := settings.token_file.set
	if token_set == file_set {
		add_sourced_issue(issues, 0, "", "exactly one of token or token_file is required")
	}
	insecure := settings.insecure.set && settings.insecure.value
	if insecure && (settings.tls_ca.set || settings.tls_server_name.set) {
		line, flag := issue_source_bool(settings.insecure)
		add_sourced_issue(issues, line, flag, "insecure cannot be combined with tls_ca or tls_server_name")
	}
	service_set := settings.service.set
	target_set := settings.target.set
	if service_set != target_set {
		line, flag := issue_source(settings.service)
		if !service_set {
			line, flag = issue_source(settings.target)
		}
		add_sourced_issue(issues, line, flag, "service and target must be used together")
	}

	seen: map[string]struct{}
	seen = make(map[string]struct{})
	defer delete(seen)

	check_map :: proc(spec: SourcedString, seen: ^map[string]struct{}, issues: ^[dynamic]ValidationIssue) {
		service, target, ok := split_key_value(spec.value)
		line, flag := issue_source(spec)
		if !ok {
			add_sourced_issue(issues, line, flag, "invalid map")
			return
		}
		if proto.check_service_id(service) != .None {
			add_sourced_issue(issues, line, flag, "invalid service id")
			return
		}
		if !check_host_port(target, false) {
			add_sourced_issue(issues, line, flag, "invalid target address")
			return
		}
		if _, exists := seen[service]; exists {
			add_sourced_issue(issues, line, flag, "duplicate service id")
			return
		}
		seen[service] = {}
	}

	for spec in settings.maps {
		check_map(spec, &seen, issues)
	}
	if service_set && target_set {
		if proto.check_service_id(settings.service.value) != .None {
			line, flag := issue_source(settings.service)
			add_sourced_issue(issues, line, flag, "invalid service id")
		} else if _, exists := seen[settings.service.value]; exists {
			line, flag := issue_source(settings.service)
			add_sourced_issue(issues, line, flag, "duplicate service id")
		} else {
			if !check_host_port(settings.target.value, false) {
				line, flag := issue_source(settings.target)
				add_sourced_issue(issues, line, flag, "invalid target address")
			} else {
				seen[settings.service.value] = {}
			}
		}
	}
	if len(settings.maps) == 0 && !(service_set && target_set) {
		add_sourced_issue(issues, 0, "", "at least one map or service/target is required")
	}
	if len(issues) == 0 {
		return .None
	}
	if !settings.broker.set || token_set == file_set || (len(settings.maps) == 0 && !(service_set && target_set)) {
		return .MissingRequired
	}
	return .InvalidValue
}
