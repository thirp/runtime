package c_abi

import ag "../agent"
import "core:c"
import "core:thread"

@(export, link_name = "thirp_agent_create")
thirp_agent_create :: proc "c" (config: ^ThirpAgentConfig, out: ^^CAgent) -> c.int {
	context = abi_context()
	return agent_create(config, out)
}

@(export, link_name = "thirp_register_service")
thirp_register_service :: proc "c" (agent: ^CAgent, service_id: cstring, target: cstring) -> c.int {
	context = abi_context()
	return agent_register(agent, service_id, target)
}

@(export, link_name = "thirp_unregister_service")
thirp_unregister_service :: proc "c" (agent: ^CAgent, service_id: cstring) -> c.int {
	context = abi_context()
	return agent_unregister(agent, service_id)
}

@(export, link_name = "thirp_host_ephemeral")
thirp_host_ephemeral :: proc "c" (
	agent: ^CAgent,
	namespace: cstring,
	target: cstring,
	out: ^ThirpHosting,
) -> c.int {
	context = abi_context()
	return agent_host_ephemeral(agent, namespace, target, out)
}

@(export, link_name = "thirp_agent_stop")
thirp_agent_stop :: proc "c" (agent: ^CAgent) {
	context = abi_context()
	agent_stop(agent)
}

@(export, link_name = "thirp_agent_destroy")
thirp_agent_destroy :: proc "c" (agent: ^CAgent) {
	context = abi_context()
	agent_destroy(agent)
}

agent_create :: proc(config: ^ThirpAgentConfig, out: ^^CAgent) -> c.int {
	if out == nil {
		return ERR_INVALID_ARGUMENT
	}
	out^ = nil
	cfg, cerr := agent_config_from_c(config)
	if cerr != 0 {
		return cerr
	}
	handle, aerr := new(CAgent)
	if aerr != .None {
		return ERR_OUT_OF_MEMORY
	}
	err := ag.agent_init(&handle.inner, cfg)
	if err != .None {
		free(handle)
		return agent_error_to_c(err)
	}
	handle.thread = thread.create_and_start_with_poly_data(handle, c_agent_run)
	if handle.thread == nil {
		ag.agent_destroy(&handle.inner)
		free(handle)
		return ERR_OUT_OF_MEMORY
	}
	out^ = handle
	return ERR_OK
}

c_agent_run :: proc(handle: ^CAgent) {
	_ = ag.agent_run(&handle.inner)
}

agent_register :: proc(agent: ^CAgent, service_id: cstring, target: cstring) -> c.int {
	if agent == nil {
		return ERR_INVALID_ARGUMENT
	}
	id, ierr := service_id_from_cstr(service_id)
	if ierr != 0 {
		return ierr
	}
	ep, terr := parse_target(target)
	if terr != 0 {
		return terr
	}
	return agent_error_to_c(ag.register_service(&agent.inner, id, ag.LocalTarget{address = ep}))
}

agent_unregister :: proc(agent: ^CAgent, service_id: cstring) -> c.int {
	if agent == nil {
		return ERR_INVALID_ARGUMENT
	}
	id, ierr := service_id_from_cstr(service_id)
	if ierr != 0 {
		return ierr
	}
	return agent_error_to_c(ag.unregister_service(&agent.inner, id))
}

agent_host_ephemeral :: proc(
	agent: ^CAgent,
	namespace: cstring,
	target: cstring,
	out: ^ThirpHosting,
) -> c.int {
	if agent == nil || out == nil {
		return ERR_INVALID_ARGUMENT
	}
	if namespace == nil || len(cstr_str(namespace)) == 0 {
		return ERR_INVALID_ARGUMENT
	}
	ep, terr := parse_target(target)
	if terr != 0 {
		return terr
	}
	hosting, err := ag.host_ephemeral(
		&agent.inner,
		ag.EphemeralConfig{namespace = cstr_str(namespace), local_address = ep},
	)
	if err != .None {
		return agent_error_to_c(err)
	}
	defer ag.hosting_destroy(&hosting)
	out^ = {}
	if !copy_to_cstr_buf(out.service_id[:], string(hosting.service_id)) {
		return ERR_INTERNAL_ERROR
	}
	if !copy_to_cstr_buf(out.join_code[:], hosting.join_code) {
		return ERR_INTERNAL_ERROR
	}
	return ERR_OK
}

agent_stop :: proc(agent: ^CAgent) {
	if agent == nil {
		return
	}
	ag.agent_stop(&agent.inner)
}

agent_destroy :: proc(agent: ^CAgent) {
	if agent == nil {
		return
	}
	ag.agent_stop(&agent.inner)
	if agent.thread != nil {
		thread.join(agent.thread)
		thread.destroy(agent.thread)
		agent.thread = nil
	}
	ag.agent_destroy(&agent.inner)
	free(agent)
}
