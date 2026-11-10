package broker

import proto "../protocol"
import "core:strings"
import "core:sync"
import "core:time"

service_key :: proc(environment: string, service_id: ServiceId, organization: OrganizationId = "") -> ServiceKey {
	// Environment namespaces retain their existing identity. Organization is
	// a separate component used only for account services without an environment.
	key := ServiceKey {
		environment = environment,
		service_id  = service_id,
	}
	if len(environment) == 0 {
		key.organization = organization
	}
	return key
}

free_service_key :: proc(key: ServiceKey, allocator := context.allocator) {
	if len(key.environment) > 0 {
		delete(key.environment, allocator)
	}
	if len(key.organization) > 0 {
		delete(string(key.organization), allocator)
	}
	if len(key.service_id) > 0 {
		delete(string(key.service_id), allocator)
	}
}

registry_init :: proc(reg: ^Registry, allocator := context.allocator) -> RegistryError {
	reg^ = {}
	reg.allocator = allocator
	reg.services = make(map[ServiceKey]ServiceRegistration, allocator)
	reg.sessions = make(map[SessionId]AgentSession, allocator)
	reg.next_session_id = 1
	reg.max_registrations_per_session = DEFAULT_MAX_REGISTRATIONS_PER_SESSION
	return .None
}

registry_destroy :: proc(reg: ^Registry) {
	if reg == nil {
		return
	}
	for _, session in reg.sessions {
		for sid in session.service_ids {
			stored, _ := delete_key(&reg.services, service_key(session.environment_id, sid, session.principal.organization))
			if len(stored.service_id) > 0 {
				free_service_key(stored, reg.allocator)
			} else {
				delete(string(sid), reg.allocator)
			}
		}
		delete(session.service_ids)
		if len(session.environment_id) > 0 {
			delete(session.environment_id, reg.allocator)
		}
		destroy_principal(session.principal, reg.allocator)
	}
	for key in reg.services {
		free_service_key(key, reg.allocator)
	}
	delete(reg.sessions)
	delete(reg.services)
	reg^ = {}
}

check_register_service :: proc(reg: ^Registry, session_id: SessionId, service_id: ServiceId) -> RegistryError {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	return check_register_service_locked(reg, session_id, service_id)
}

check_register_service_locked :: proc(reg: ^Registry, session_id: SessionId, service_id: ServiceId) -> RegistryError {
	if proto.check_service_id(string(service_id)) != .None {
		return .InvalidServiceId
	}
	session, ok := reg.sessions[session_id]
	if !ok {
		return .SessionNotFound
	}
	// Unique inside the environment, or the account when there is no environment.
	if _, exists := reg.services[service_key(session.environment_id, service_id, session.principal.organization)]; exists {
		return .ServiceAlreadyRegistered
	}
	if reg.max_registrations_per_session > 0 &&
	   len(session.service_ids) >= reg.max_registrations_per_session {
		return .QuotaExceeded
	}
	return .None
}

register_service :: proc(reg: ^Registry, session_id: SessionId, service_id: ServiceId) -> RegistryError {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)

	if err := check_register_service_locked(reg, session_id, service_id); err != .None {
		return err
	}

	owned, clone_err := strings.clone(string(service_id), reg.allocator)
	if clone_err != .None {
		return .OutOfMemory
	}
	owned_id := ServiceId(owned)
	session := reg.sessions[session_id]
	env_owned: string
	org_owned: OrganizationId
	if len(session.environment_id) > 0 {
		cloned_env, env_err := strings.clone(session.environment_id, reg.allocator)
		if env_err != .None {
			delete(owned, reg.allocator)
			return .OutOfMemory
		}
		env_owned = cloned_env
	} else {
		cloned_org, org_err := strings.clone(string(session.principal.organization), reg.allocator)
		if org_err != .None {
			delete(owned, reg.allocator)
			return .OutOfMemory
		}
		org_owned = OrganizationId(cloned_org)
	}
	now := time.now()

	reg.services[service_key(env_owned, owned_id, org_owned)] = ServiceRegistration {
		id            = owned_id,
		owner         = session.principal.id,
		organization  = session.principal.organization,
		agent_session = session_id,
		registered_at = now,
		last_seen_at  = now,
	}
	session.service_ids[owned_id] = {}
	session.last_seen_at = now
	reg.sessions[session_id] = session
	return .None
}

unregister_service :: proc(reg: ^Registry, session_id: SessionId, service_id: ServiceId) -> RegistryError {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)

	session, ok := reg.sessions[session_id]
	if !ok {
		return .SessionNotFound
	}
	probe := service_key(session.environment_id, service_id, session.principal.organization)
	rec, exists := reg.services[probe]
	if !exists {
		return .None
	}
	if rec.agent_session != session_id {
		return .NotOwned
	}

	stored, _ := delete_key(&reg.services, probe)
	delete_key(&session.service_ids, service_id)
	free_service_key(stored, reg.allocator)
	session.last_seen_at = time.now()
	reg.sessions[session_id] = session
	return .None
}

// Leftover global namespace only. Account and environment registrations
// are not visible here.
lookup_service :: proc(reg: ^Registry, service_id: ServiceId) -> (ServiceRegistration, bool) {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	rec, ok := reg.services[service_key("", service_id)]
	return rec, ok
}

// Environment name first, or account name when only organization is supplied,
// then the leftover global name. Environment lookups never probe account keys.
// With neither environment nor organization, only the global key is visible.
lookup_service_for_environment :: proc(
	reg: ^Registry,
	environment: string,
	service_id: ServiceId,
	organization: OrganizationId = "",
) -> (
	ServiceRegistration,
	bool,
) {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	if len(environment) > 0 || len(organization) > 0 {
		if rec, ok := reg.services[service_key(environment, service_id, organization)]; ok {
			return rec, true
		}
	}
	rec, ok := reg.services[service_key("", service_id)]
	return rec, ok
}

copy_session_service_ids :: proc(
	reg: ^Registry,
	session_id: SessionId,
	allocator := context.allocator,
) -> []ServiceId {
	if reg == nil || session_id == INVALID_SESSION_ID {
		return nil
	}
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	session, ok := reg.sessions[session_id]
	if !ok || len(session.service_ids) == 0 {
		return nil
	}
	out := make([]ServiceId, len(session.service_ids), allocator)
	i := 0
	for sid in session.service_ids {
		cloned, err := strings.clone(string(sid), allocator)
		if err != .None {
			for j in 0 ..< i {
				delete(string(out[j]), allocator)
			}
			delete(out)
			return nil
		}
		out[i] = ServiceId(cloned)
		i += 1
	}
	return out
}

remove_session_services :: proc(reg: ^Registry, session_id: SessionId) -> RegistryError {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	return remove_session_services_locked(reg, session_id)
}

remove_session_services_locked :: proc(reg: ^Registry, session_id: SessionId) -> RegistryError {
	session, ok := reg.sessions[session_id]
	if !ok {
		return .SessionNotFound
	}
	for sid in session.service_ids {
		stored, _ := delete_key(&reg.services, service_key(session.environment_id, sid, session.principal.organization))
		delete_key(&session.service_ids, sid)
		if len(stored.service_id) > 0 {
			free_service_key(stored, reg.allocator)
		} else {
			delete(string(sid), reg.allocator)
		}
	}
	session.last_seen_at = time.now()
	reg.sessions[session_id] = session
	return .None
}

service_count :: proc(reg: ^Registry) -> int {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	return len(reg.services)
}

registry_metrics :: proc(reg: ^Registry) -> (services: int, sessions: int, organizations: int) {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	services = len(reg.services)
	sessions = len(reg.sessions)
	seen := make(map[OrganizationId]struct{}, reg.allocator)
	defer delete(seen)
	for _, session in reg.sessions {
		seen[session.principal.organization] = {}
	}
	organizations = len(seen)
	return
}
