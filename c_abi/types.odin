package c_abi

import ag "../agent"
import cl "../caller"
import proto "../protocol"
import trans "../transport"
import "core:c"
import "core:net"
import "core:thread"

HOSTING_SERVICE_ID_CAP :: proto.MAX_SERVICE_ID_LEN + 1
HOSTING_JOIN_CODE_CAP :: ag.JOIN_CODE_LEN + 1

ThirpAgentConfig :: struct {
	broker:          cstring,
	token:           cstring,
	insecure:        c.int,
	tls_ca:          cstring,
	tls_server_name: cstring,
	implementation:  cstring,
}

ThirpCallerConfig :: struct {
	broker:          cstring,
	token:           cstring,
	insecure:        c.int,
	tls_ca:          cstring,
	tls_server_name: cstring,
	implementation:  cstring,
}

ThirpHosting :: struct {
	service_id: [HOSTING_SERVICE_ID_CAP]u8,
	join_code:  [HOSTING_JOIN_CODE_CAP]u8,
}

CAgent :: struct {
	inner:  ag.Agent,
	thread: ^thread.Thread,
}

CCaller :: struct {
	inner: cl.Caller,
}

cstr_str :: proc(s: cstring) -> string {
	if s == nil {
		return ""
	}
	return string(s)
}

copy_to_cstr_buf :: proc(dst: []u8, src: string) -> bool {
	if len(src) + 1 > len(dst) {
		return false
	}
	copy(dst, src)
	dst[len(src)] = 0
	return true
}

parse_target :: proc(target: cstring) -> (net.Endpoint, c.int) {
	if target == nil {
		return {}, ERR_INVALID_ARGUMENT
	}
	ep, err := trans.resolve_endpoint(cstr_str(target))
	if err != .None {
		return {}, ERR_INVALID_ARGUMENT
	}
	return ep, 0
}

service_id_from_cstr :: proc(s: cstring) -> (proto.ServiceId, c.int) {
	if s == nil {
		return {}, ERR_INVALID_ARGUMENT
	}
	id, err := proto.make_service_id(cstr_str(s))
	if err != .None {
		return {}, ERR_INVALID_SERVICE_ID
	}
	return id, 0
}

broker_endpoint_and_sni :: proc(broker, tls_server_name: string, insecure: bool) -> (net.Endpoint, string, c.int) {
	ep, err := trans.resolve_endpoint(broker)
	if err != .None {
		return {}, "", ERR_INVALID_ARGUMENT
	}
	sni := tls_server_name
	if !insecure && len(sni) == 0 {
		if host, hok := trans.endpoint_host(broker); hok {
			sni = host
		}
	}
	return ep, sni, 0
}

agent_config_from_c :: proc(cfg: ^ThirpAgentConfig) -> (ag.AgentConfig, c.int) {
	if cfg == nil {
		return {}, ERR_INVALID_ARGUMENT
	}
	insecure := cfg.insecure != 0
	ep, sni, err := broker_endpoint_and_sni(cstr_str(cfg.broker), cstr_str(cfg.tls_server_name), insecure)
	if err != 0 {
		return {}, err
	}
	return ag.AgentConfig {
			broker          = ep,
			token           = cstr_str(cfg.token),
			insecure        = insecure,
			tls_ca          = cstr_str(cfg.tls_ca),
			tls_server_name = sni,
			implementation  = cstr_str(cfg.implementation),
		},
		0
}

caller_config_from_c :: proc(cfg: ^ThirpCallerConfig) -> (cl.CallerConfig, c.int) {
	if cfg == nil {
		return {}, ERR_INVALID_ARGUMENT
	}
	insecure := cfg.insecure != 0
	ep, sni, err := broker_endpoint_and_sni(cstr_str(cfg.broker), cstr_str(cfg.tls_server_name), insecure)
	if err != 0 {
		return {}, err
	}
	return cl.CallerConfig {
			broker          = ep,
			token           = cstr_str(cfg.token),
			insecure        = insecure,
			tls_ca          = cstr_str(cfg.tls_ca),
			tls_server_name = sni,
			implementation  = cstr_str(cfg.implementation),
		},
		0
}
