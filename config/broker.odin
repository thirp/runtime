package config

import log "../logging"
import proto "../protocol"

broker_settings_init :: proc(settings: ^BrokerSettings, allocator := context.allocator) {
	settings^ = {}
	settings.allocator = allocator
	settings.tokens = make([dynamic]SourcedString, allocator)
	settings.token_files = make([dynamic]SourcedString, allocator)
	settings.capabilities = make([dynamic]SourcedString, allocator)
	settings.allow_register = make([dynamic]SourcedString, allocator)
	settings.allow_connect = make([dynamic]SourcedString, allocator)
	settings.org_namespace = make([dynamic]SourcedString, allocator)
}

broker_settings_destroy :: proc(settings: ^BrokerSettings) {
	if settings == nil {
		return
	}
	alloc := settings.allocator
	destroy_sourced_string(settings.listen, alloc)
	destroy_sourced_string(settings.tls_cert, alloc)
	destroy_sourced_string(settings.tls_key, alloc)
	destroy_sourced_string(settings.policy_mode, alloc)
	destroy_sourced_list(settings.tokens, alloc)
	destroy_sourced_list(settings.token_files, alloc)
	destroy_sourced_list(settings.capabilities, alloc)
	destroy_sourced_list(settings.allow_register, alloc)
	destroy_sourced_list(settings.allow_connect, alloc)
	destroy_sourced_list(settings.org_namespace, alloc)
	destroy_sourced_string(settings.metrics_listen, alloc)
	destroy_sourced_string(settings.log_level, alloc)
	settings^ = {}
}

assign_sourced_string :: proc(dst: ^SourcedString, value: string, line: int, flag: string, allocator := context.allocator) -> ConfigError {
	if dst.set {
		return .DuplicateKey
	}
	next, err := sourced_string(value, line, flag, allocator)
	if err != .None {
		return err
	}
	dst^ = next
	return .None
}

append_sourced_string :: proc(dst: ^[dynamic]SourcedString, value: string, line: int, flag: string, allocator := context.allocator) -> ConfigError {
	next, err := sourced_string(value, line, flag, allocator)
	if err != .None {
		return err
	}
	_, aerr := append(dst, next)
	if aerr != .None {
		delete(next.value, allocator)
		return .OutOfMemory
	}
	return .None
}

assign_sourced_int :: proc(dst: ^SourcedInt, raw: string, line: int, flag: string) -> ConfigError {
	if dst.set {
		return .DuplicateKey
	}
	n, ok := parse_nonneg_int(raw)
	if !ok {
		return .InvalidValue
	}
	dst^ = sourced_int(n, line, flag)
	return .None
}

assign_sourced_bool :: proc(dst: ^SourcedBool, raw: string, line: int, flag: string) -> ConfigError {
	if dst.set {
		return .DuplicateKey
	}
	v, ok := parse_bool_value(raw)
	if !ok {
		return .InvalidValue
	}
	dst^ = sourced_bool(v, line, flag)
	return .None
}

broker_apply_entry :: proc(settings: ^BrokerSettings, entry: IniEntry) -> ConfigError {
	alloc := settings.allocator
	switch entry.key {
	case "listen":
		return assign_sourced_string(&settings.listen, entry.value, entry.line, "", alloc)
	case "tls_cert":
		return assign_sourced_string(&settings.tls_cert, entry.value, entry.line, "", alloc)
	case "tls_key":
		return assign_sourced_string(&settings.tls_key, entry.value, entry.line, "", alloc)
	case "insecure":
		return assign_sourced_bool(&settings.insecure, entry.value, entry.line, "")
	case "policy_mode":
		return assign_sourced_string(&settings.policy_mode, entry.value, entry.line, "", alloc)
	case "token":
		return append_sourced_string(&settings.tokens, entry.value, entry.line, "", alloc)
	case "token_file":
		return append_sourced_string(&settings.token_files, entry.value, entry.line, "", alloc)
	case "capability":
		return append_sourced_string(&settings.capabilities, entry.value, entry.line, "", alloc)
	case "allow_register":
		return append_sourced_string(&settings.allow_register, entry.value, entry.line, "", alloc)
	case "allow_connect":
		return append_sourced_string(&settings.allow_connect, entry.value, entry.line, "", alloc)
	case "org_namespace":
		return append_sourced_string(&settings.org_namespace, entry.value, entry.line, "", alloc)
	case "max_stream_buffer":
		return assign_sourced_int(&settings.max_stream_buffer, entry.value, entry.line, "")
	case "max_connection_buffer":
		return assign_sourced_int(&settings.max_connection_buffer, entry.value, entry.line, "")
	case "max_streams_per_session":
		return assign_sourced_int(&settings.max_streams_per_session, entry.value, entry.line, "")
	case "max_registrations_per_session":
		return assign_sourced_int(&settings.max_registrations_per_session, entry.value, entry.line, "")
	case "max_frame_size":
		return assign_sourced_int(&settings.max_frame_size, entry.value, entry.line, "")
	case "max_connections":
		return assign_sourced_int(&settings.max_connections, entry.value, entry.line, "")
	case "max_connections_per_ip":
		return assign_sourced_int(&settings.max_connections_per_ip, entry.value, entry.line, "")
	case "auth_rate_limit":
		return assign_sourced_int(&settings.auth_rate_limit, entry.value, entry.line, "")
	case "register_rate_limit":
		return assign_sourced_int(&settings.register_rate_limit, entry.value, entry.line, "")
	case "connect_rate_limit":
		return assign_sourced_int(&settings.connect_rate_limit, entry.value, entry.line, "")
	case "max_buffered_bytes":
		return assign_sourced_int(&settings.max_buffered_bytes, entry.value, entry.line, "")
	case "stream_idle_timeout":
		return assign_sourced_int(&settings.stream_idle_timeout, entry.value, entry.line, "")
	case "heartbeat_interval":
		return assign_sourced_int(&settings.heartbeat_interval, entry.value, entry.line, "")
	case "session_timeout":
		return assign_sourced_int(&settings.session_timeout, entry.value, entry.line, "")
	case "shutdown_grace":
		return assign_sourced_int(&settings.shutdown_grace, entry.value, entry.line, "")
	case "metrics_listen":
		return assign_sourced_string(&settings.metrics_listen, entry.value, entry.line, "", alloc)
	case "log_level":
		return assign_sourced_string(&settings.log_level, entry.value, entry.line, "", alloc)
	}
	return .UnknownKey
}

broker_settings_from_ini :: proc(
	doc: IniDocument,
	issues: ^[dynamic]ValidationIssue,
	allocator := context.allocator,
) -> (
	settings: BrokerSettings,
	err: ConfigError,
) {
	broker_settings_init(&settings, allocator)
	had_error := ConfigError.None
	for entry in doc.entries {
		apply_err := broker_apply_entry(&settings, entry)
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
			broker_settings_destroy(&settings)
			return {}, .OutOfMemory
		case .None, .Io, .Empty, .TooLarge, .InvalidLine, .MissingRequired, .InsecureProduction:
			msg = "invalid value"
		}
		if append_issue(issues, entry.line, "", msg, issues.allocator) != .None {
			broker_settings_destroy(&settings)
			return {}, .OutOfMemory
		}
		if had_error == .None {
			had_error = apply_err
		}
	}
	return settings, had_error
}

copy_if_set_string :: proc(dst: ^SourcedString, src: SourcedString, allocator := context.allocator) -> ConfigError {
	if !src.set {
		return .None
	}
	destroy_sourced_string(dst^, allocator)
	next, err := clone_sourced_string(src, allocator)
	if err != .None {
		return err
	}
	dst^ = next
	return .None
}

copy_if_set_int :: proc(dst: ^SourcedInt, src: SourcedInt) {
	if src.set {
		dst^ = src
	}
}

copy_if_set_bool :: proc(dst: ^SourcedBool, src: SourcedBool) {
	if src.set {
		dst^ = src
	}
}

settings_merge_broker :: proc(file, flags: BrokerSettings, allocator := context.allocator) -> (BrokerSettings, ConfigError) {
	out: BrokerSettings
	broker_settings_init(&out, allocator)
	if copy_if_set_string(&out.listen, file.listen, allocator) != .None {
		broker_settings_destroy(&out)
		return {}, .OutOfMemory
	}
	if copy_if_set_string(&out.tls_cert, file.tls_cert, allocator) != .None ||
	   copy_if_set_string(&out.tls_key, file.tls_key, allocator) != .None ||
	   copy_if_set_string(&out.policy_mode, file.policy_mode, allocator) != .None ||
	   copy_if_set_string(&out.metrics_listen, file.metrics_listen, allocator) != .None ||
	   copy_if_set_string(&out.log_level, file.log_level, allocator) != .None {
		broker_settings_destroy(&out)
		return {}, .OutOfMemory
	}
	out.insecure = file.insecure
	out.max_stream_buffer = file.max_stream_buffer
	out.max_connection_buffer = file.max_connection_buffer
	out.max_streams_per_session = file.max_streams_per_session
	out.max_registrations_per_session = file.max_registrations_per_session
	out.max_frame_size = file.max_frame_size
	out.max_connections = file.max_connections
	out.max_connections_per_ip = file.max_connections_per_ip
	out.auth_rate_limit = file.auth_rate_limit
	out.register_rate_limit = file.register_rate_limit
	out.connect_rate_limit = file.connect_rate_limit
	out.max_buffered_bytes = file.max_buffered_bytes
	out.stream_idle_timeout = file.stream_idle_timeout
	out.heartbeat_interval = file.heartbeat_interval
	out.session_timeout = file.session_timeout
	out.shutdown_grace = file.shutdown_grace
	if clone_sourced_list(file.tokens[:], &out.tokens, allocator) != .None ||
	   clone_sourced_list(file.token_files[:], &out.token_files, allocator) != .None ||
	   clone_sourced_list(file.capabilities[:], &out.capabilities, allocator) != .None ||
	   clone_sourced_list(file.allow_register[:], &out.allow_register, allocator) != .None ||
	   clone_sourced_list(file.allow_connect[:], &out.allow_connect, allocator) != .None ||
	   clone_sourced_list(file.org_namespace[:], &out.org_namespace, allocator) != .None {
		broker_settings_destroy(&out)
		return {}, .OutOfMemory
	}

	if copy_if_set_string(&out.listen, flags.listen, allocator) != .None ||
	   copy_if_set_string(&out.tls_cert, flags.tls_cert, allocator) != .None ||
	   copy_if_set_string(&out.tls_key, flags.tls_key, allocator) != .None ||
	   copy_if_set_string(&out.policy_mode, flags.policy_mode, allocator) != .None ||
	   copy_if_set_string(&out.metrics_listen, flags.metrics_listen, allocator) != .None ||
	   copy_if_set_string(&out.log_level, flags.log_level, allocator) != .None {
		broker_settings_destroy(&out)
		return {}, .OutOfMemory
	}
	copy_if_set_bool(&out.insecure, flags.insecure)
	copy_if_set_int(&out.max_stream_buffer, flags.max_stream_buffer)
	copy_if_set_int(&out.max_connection_buffer, flags.max_connection_buffer)
	copy_if_set_int(&out.max_streams_per_session, flags.max_streams_per_session)
	copy_if_set_int(&out.max_registrations_per_session, flags.max_registrations_per_session)
	copy_if_set_int(&out.max_frame_size, flags.max_frame_size)
	copy_if_set_int(&out.max_connections, flags.max_connections)
	copy_if_set_int(&out.max_connections_per_ip, flags.max_connections_per_ip)
	copy_if_set_int(&out.auth_rate_limit, flags.auth_rate_limit)
	copy_if_set_int(&out.register_rate_limit, flags.register_rate_limit)
	copy_if_set_int(&out.connect_rate_limit, flags.connect_rate_limit)
	copy_if_set_int(&out.max_buffered_bytes, flags.max_buffered_bytes)
	copy_if_set_int(&out.stream_idle_timeout, flags.stream_idle_timeout)
	copy_if_set_int(&out.heartbeat_interval, flags.heartbeat_interval)
	copy_if_set_int(&out.session_timeout, flags.session_timeout)
	copy_if_set_int(&out.shutdown_grace, flags.shutdown_grace)
	if clone_sourced_list(flags.tokens[:], &out.tokens, allocator) != .None ||
	   clone_sourced_list(flags.token_files[:], &out.token_files, allocator) != .None ||
	   clone_sourced_list(flags.capabilities[:], &out.capabilities, allocator) != .None ||
	   clone_sourced_list(flags.allow_register[:], &out.allow_register, allocator) != .None ||
	   clone_sourced_list(flags.allow_connect[:], &out.allow_connect, allocator) != .None ||
	   clone_sourced_list(flags.org_namespace[:], &out.org_namespace, allocator) != .None {
		broker_settings_destroy(&out)
		return {}, .OutOfMemory
	}
	return out, .None
}

add_sourced_issue :: proc(issues: ^[dynamic]ValidationIssue, line: int, flag, message: string) {
	_ = append_issue(issues, line, flag, message, issues.allocator)
}

broker_settings_validate :: proc(settings: BrokerSettings, issues: ^[dynamic]ValidationIssue) -> ConfigError {
	if !settings.listen.set {
		add_sourced_issue(issues, 0, "", "listen is required")
	} else if !check_host_port(settings.listen.value, true) {
		line, flag := issue_source(settings.listen)
		add_sourced_issue(issues, line, flag, "invalid address")
	}
	if settings.metrics_listen.set && !check_host_port(settings.metrics_listen.value, true) {
		line, flag := issue_source(settings.metrics_listen)
		add_sourced_issue(issues, line, flag, "invalid address")
	}
	policy := "development"
	if settings.policy_mode.set {
		switch settings.policy_mode.value {
		case "development", "production":
			policy = settings.policy_mode.value
		case:
			line, flag := issue_source(settings.policy_mode)
			add_sourced_issue(issues, line, flag, "invalid policy mode")
		}
	}
	insecure := settings.insecure.set && settings.insecure.value
	if insecure && policy == "production" {
		line, flag := issue_source_bool(settings.insecure)
		if line == 0 && !settings.insecure.set {
			line, flag = issue_source(settings.policy_mode)
		}
		add_sourced_issue(issues, line, flag, "production mode cannot enable insecure")
	}
	if !insecure && (!settings.tls_cert.set || !settings.tls_key.set) {
		line, flag := issue_source(settings.tls_cert)
		if !settings.tls_cert.set {
			line, flag = issue_source(settings.tls_key)
		}
		add_sourced_issue(issues, line, flag, "tls required unless insecure")
	}
	if len(settings.tokens) == 0 && len(settings.token_files) == 0 {
		add_sourced_issue(issues, 0, "", "at least one token or token_file is required")
	}
	if settings.log_level.set {
		_, ok := log.log_level_from_string(settings.log_level.value)
		if !ok {
			line, flag := issue_source(settings.log_level)
			add_sourced_issue(issues, line, flag, "invalid log level")
		}
	}
	if settings.max_frame_size.set {
		n := settings.max_frame_size.value
		if n <= 0 || n > int(proto.MAX_FRAME_PAYLOAD) {
			line, flag := issue_source_int(settings.max_frame_size)
			add_sourced_issue(issues, line, flag, "invalid value")
		}
	}
	if settings.heartbeat_interval.set && settings.heartbeat_interval.value <= 0 {
		line, flag := issue_source_int(settings.heartbeat_interval)
		add_sourced_issue(issues, line, flag, "invalid value")
	}
	if settings.session_timeout.set && settings.session_timeout.value <= 0 {
		line, flag := issue_source_int(settings.session_timeout)
		add_sourced_issue(issues, line, flag, "invalid value")
	}
	for spec in settings.capabilities {
		if !check_capability_spec(spec.value) {
			line, flag := issue_source(spec)
			add_sourced_issue(issues, line, flag, "invalid capability")
		}
	}
	for spec in settings.allow_register {
		if !check_grant_spec(spec.value) {
			line, flag := issue_source(spec)
			add_sourced_issue(issues, line, flag, "invalid grant")
		}
	}
	for spec in settings.allow_connect {
		if !check_grant_spec(spec.value) {
			line, flag := issue_source(spec)
			add_sourced_issue(issues, line, flag, "invalid grant")
		}
	}
	for spec in settings.org_namespace {
		if !check_grant_spec(spec.value) {
			line, flag := issue_source(spec)
			add_sourced_issue(issues, line, flag, "invalid grant")
		}
	}
	if len(issues) == 0 {
		return .None
	}
	for issue in issues {
		if issue.message == "production mode cannot enable insecure" {
			return .InsecureProduction
		}
	}
	if !settings.listen.set || (len(settings.tokens) == 0 && len(settings.token_files) == 0) {
		return .MissingRequired
	}
	return .InvalidValue
}
