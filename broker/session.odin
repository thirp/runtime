package broker

import "core:strings"
import "core:sync"
import "core:time"

clone_principal :: proc(principal: Principal, allocator := context.allocator) -> (Principal, RegistryError) {
	id_str, id_err := strings.clone(string(principal.id), allocator)
	if id_err != .None {
		return {}, .OutOfMemory
	}
	org_str, org_err := strings.clone(string(principal.organization), allocator)
	if org_err != .None {
		delete(id_str, allocator)
		return {}, .OutOfMemory
	}
	return Principal{
		id           = PrincipalId(id_str),
		organization = OrganizationId(org_str),
		capabilities = principal.capabilities,
	}, .None
}

destroy_principal :: proc(principal: Principal, allocator := context.allocator) {
	if len(principal.id) > 0 {
		delete(string(principal.id), allocator)
	}
	if len(principal.organization) > 0 {
		delete(string(principal.organization), allocator)
	}
}

registry_add_session :: proc(reg: ^Registry, principal: Principal) -> (SessionId, RegistryError) {
	if check_identity_string(string(principal.id)) != .None ||
	   check_identity_string(string(principal.organization)) != .None {
		return INVALID_SESSION_ID, .InvalidPrincipal
	}

	cloned, clone_err := clone_principal(principal, reg.allocator)
	if clone_err != .None {
		return INVALID_SESSION_ID, clone_err
	}

	service_ids := make(map[ServiceId]struct{}, reg.allocator)
	now := time.now()

	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)

	sid := SessionId(reg.next_session_id)
	reg.next_session_id += 1
	reg.sessions[sid] = AgentSession {
		id            = sid,
		principal     = cloned,
		registered_at = now,
		last_seen_at  = now,
		service_ids   = service_ids,
	}
	return sid, .None
}

registry_remove_session :: proc(reg: ^Registry, session_id: SessionId) -> RegistryError {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	return registry_remove_session_locked(reg, session_id)
}

registry_remove_session_locked :: proc(reg: ^Registry, session_id: SessionId) -> RegistryError {
	if err := remove_session_services_locked(reg, session_id); err != .None {
		return err
	}
	_, session := delete_key(&reg.sessions, session_id)
	delete(session.service_ids)
	destroy_principal(session.principal, reg.allocator)
	return .None
}

registry_touch_session :: proc(reg: ^Registry, session_id: SessionId) -> RegistryError {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)

	session, ok := reg.sessions[session_id]
	if !ok {
		return .SessionNotFound
	}
	session.last_seen_at = time.now()
	reg.sessions[session_id] = session
	return .None
}
