package agent

import proto "../protocol"
import "core:crypto"
import "core:strings"

generate_join_code :: proc(allocator := context.allocator) -> (string, AgentError) {
	buf: [JOIN_CODE_LEN]u8
	raw: [JOIN_CODE_LEN]u8
	alphabet := JOIN_CODE_ALPHABET
	crypto.rand_bytes(raw[:])
	for i in 0 ..< JOIN_CODE_LEN {
		buf[i] = alphabet[raw[i] & 31]
	}
	crypto.zero_explicit(raw_data(raw[:]), len(raw))
	out, err := strings.clone(string(buf[:]), allocator)
	if err != .None {
		return "", .OutOfMemory
	}
	return out, .None
}

hosting_destroy :: proc(hosting: ^Hosting, allocator := context.allocator) {
	if hosting == nil {
		return
	}
	delete(string(hosting.service_id), allocator)
	delete(hosting.join_code, allocator)
	hosting^ = {}
}

host_ephemeral :: proc(
	agent: ^Agent,
	cfg: EphemeralConfig,
	allocator := context.allocator,
) -> (
	Hosting,
	AgentError,
) {
	if agent == nil || len(cfg.namespace) == 0 {
		return {}, .InvalidConfig
	}
	if validate_local_target(LocalTarget{address = cfg.local_address}) != .None {
		return {}, .InvalidConfig
	}
	for _ in 0 ..< JOIN_CODE_RETRY_CAP {
		code, gerr := generate_join_code(allocator)
		if gerr != .None {
			return {}, gerr
		}
		parts := [?]string{cfg.namespace, "/", code}
		id_str, cerr := strings.concatenate(parts[:], allocator)
		if cerr != .None {
			delete(code, allocator)
			return {}, .OutOfMemory
		}
		sid, serr := proto.make_service_id(id_str)
		if serr != .None {
			delete(id_str, allocator)
			delete(code, allocator)
			return {}, .InvalidServiceId
		}
		err := register_service(agent, sid, LocalTarget{address = cfg.local_address})
		if err == .None {
			owned, oerr := strings.clone(string(sid), allocator)
			delete(id_str, allocator)
			if oerr != .None {
				delete(code, allocator)
				return {}, .OutOfMemory
			}
			return Hosting{service_id = proto.ServiceId(owned), join_code = code}, .None
		}
		delete(id_str, allocator)
		delete(code, allocator)
		if err != .ServiceAlreadyRegistered {
			return {}, err
		}
	}
	return {}, .ServiceAlreadyRegistered
}
