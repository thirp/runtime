package broker

import proto "../protocol"
import "core:strings"
import "core:sync"
import "core:time"

registry_init :: proc(reg: ^Registry, allocator := context.allocator) -> RegistryError {
	reg^ = {}
	reg.allocator = allocator
	reg.services = make(map[ServiceId]ServiceRegistration, allocator)
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
			delete_key(&reg.services, sid)
			delete(string(sid), reg.allocator)
		}
		delete(session.service_ids)
		destroy_principal(session.principal, reg.allocator)
	}
	for sid in reg.services {
		delete(string(sid), reg.allocator)
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
	if _, exists := reg.services[service_id]; exists {
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
	now := time.now()

	session := reg.sessions[session_id]
	reg.services[owned_id] = ServiceRegistration {
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
	rec, exists := reg.services[service_id]
	if !exists {
		return .None
	}
	if rec.agent_session != session_id {
		return .NotOwned
	}

	key, _ := delete_key(&reg.services, service_id)
	delete_key(&session.service_ids, service_id)
	delete(string(key), reg.allocator)
	session.last_seen_at = time.now()
	reg.sessions[session_id] = session
	return .None
}

lookup_service :: proc(reg: ^Registry, service_id: ServiceId) -> (ServiceRegistration, bool) {
	sync.mutex_lock(&reg.mutex)
	defer sync.mutex_unlock(&reg.mutex)
	rec, ok := reg.services[service_id]
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
		key, _ := delete_key(&reg.services, sid)
		delete_key(&session.service_ids, sid)
		delete(string(key), reg.allocator)
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
