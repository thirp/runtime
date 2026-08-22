package agent

import proto "../protocol"
import trans "../transport"
import "core:strings"
import "core:sync"

validate_local_target :: proc(target: LocalTarget) -> AgentError {
	if target.address.port == 0 {
		return .InvalidConfig
	}
	return .None
}

register_service :: proc(agent: ^Agent, service_id: proto.ServiceId, target: LocalTarget) -> AgentError {
	if agent == nil {
		return .InvalidConfig
	}
	if proto.check_service_id(string(service_id)) != .None {
		return .InvalidServiceId
	}
	if validate_local_target(target) != .None {
		return .InvalidConfig
	}

	sync.mutex_lock(&agent.mutex)
	if sync.atomic_load(&agent.stop) {
		sync.mutex_unlock(&agent.mutex)
		return .Stopped
	}
	if _, exists := agent.services[service_id]; exists {
		sync.mutex_unlock(&agent.mutex)
		return .ServiceAlreadyRegistered
	}

	if !agent.connected {
		err := agent_services_put(&agent.services, service_id, AgentService{target = target, live = false})
		sync.mutex_unlock(&agent.mutex)
		return err
	}

	for agent.pending != .None && !sync.atomic_load(&agent.stop) {
		sync.cond_wait(&agent.cond, &agent.mutex)
	}
	if sync.atomic_load(&agent.stop) {
		sync.mutex_unlock(&agent.mutex)
		return .Stopped
	}

	agent.pending = .Register
	agent.pending_err = .None
	conn := agent.live_conn
	sync.mutex_unlock(&agent.mutex)

	payload, perr := proto.encode_register(proto.Register{service_id = service_id})
	if perr != .None {
		agent_clear_pending(agent, .Internal)
		return .Internal
	}
	ok := agent_write(conn, .Register, payload)
	delete(payload)
	if !ok {
		agent_clear_pending(agent, .Transport)
		return .Transport
	}

	sync.mutex_lock(&agent.mutex)
	for agent.pending != .None && !sync.atomic_load(&agent.stop) {
		sync.cond_wait(&agent.cond, &agent.mutex)
	}
	err := agent.pending_err
	if sync.atomic_load(&agent.stop) && agent.pending != .None {
		agent.pending = .None
		err = .Stopped
	}
	if err == .None {
		err = agent_services_put(&agent.services, service_id, AgentService{target = target, live = true})
	}
	sync.mutex_unlock(&agent.mutex)
	return err
}

unregister_service :: proc(agent: ^Agent, service_id: proto.ServiceId) -> AgentError {
	if agent == nil {
		return .InvalidConfig
	}

	sync.mutex_lock(&agent.mutex)
	_, exists := agent.services[service_id]
	if !exists {
		sync.mutex_unlock(&agent.mutex)
		return .None
	}

	if !agent.connected {
		key, _ := delete_key(&agent.services, service_id)
		sync.mutex_unlock(&agent.mutex)
		delete(string(key))
		return .None
	}

	for agent.pending != .None && !sync.atomic_load(&agent.stop) {
		sync.cond_wait(&agent.cond, &agent.mutex)
	}
	if sync.atomic_load(&agent.stop) {
		key, _ := delete_key(&agent.services, service_id)
		sync.mutex_unlock(&agent.mutex)
		delete(string(key))
		return .Stopped
	}
	_, still := agent.services[service_id]
	if !still {
		sync.mutex_unlock(&agent.mutex)
		return .None
	}
	key, _ := delete_key(&agent.services, service_id)
	agent.pending = .Unregister
	agent.pending_err = .None
	conn := agent.live_conn
	sync.mutex_unlock(&agent.mutex)
	delete(string(key))

	if conn == nil {
		agent_clear_pending(agent, .None)
		return .None
	}
	payload, perr := proto.encode_unregister(proto.Unregister{service_id = service_id})
	if perr != .None {
		agent_clear_pending(agent, .Internal)
		return .Internal
	}
	ok := agent_write(conn, .Unregister, payload)
	delete(payload)
	if !ok {
		agent_clear_pending(agent, .Transport)
		return .Transport
	}

	sync.mutex_lock(&agent.mutex)
	for agent.pending != .None && !sync.atomic_load(&agent.stop) {
		sync.cond_wait(&agent.cond, &agent.mutex)
	}
	err := agent.pending_err
	if sync.atomic_load(&agent.stop) && agent.pending != .None {
		agent.pending = .None
		err = .Stopped
	}
	sync.mutex_unlock(&agent.mutex)
	return err
}

agent_has_service :: proc(agent: ^Agent, service_id: proto.ServiceId) -> bool {
	if agent == nil {
		return false
	}
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	_, ok := agent.services[service_id]
	return ok
}

agent_services_put :: proc(
	services: ^map[proto.ServiceId]AgentService,
	service_id: proto.ServiceId,
	svc: AgentService,
) -> AgentError {
	owned, err := strings.clone(string(service_id))
	if err != .None {
		return .OutOfMemory
	}
	services[proto.ServiceId(owned)] = svc
	return .None
}

agent_clear_pending :: proc(agent: ^Agent, err: AgentError) {
	sync.mutex_lock(&agent.mutex)
	agent.pending = .None
	agent.pending_err = err
	sync.cond_broadcast(&agent.cond)
	sync.mutex_unlock(&agent.mutex)
}

agent_finish_pending :: proc(agent: ^Agent, err: AgentError) {
	agent.pending = .None
	agent.pending_err = err
	sync.cond_broadcast(&agent.cond)
}

agent_lookup_target :: proc(agent: ^Agent, service_id: proto.ServiceId) -> (LocalTarget, bool) {
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	svc, ok := agent.services[service_id]
	if !ok {
		return {}, false
	}
	return svc.target, true
}

agent_snapshot_all :: proc(agent: ^Agent) -> [dynamic]ServiceSnapshot {
	out: [dynamic]ServiceSnapshot
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	for id, svc in agent.services {
		owned, err := strings.clone(string(id))
		if err != .None {
			continue
		}
		append(&out, ServiceSnapshot{id = proto.ServiceId(owned), target = svc.target})
	}
	return out
}

agent_snapshot_unregistered :: proc(agent: ^Agent) -> [dynamic]ServiceSnapshot {
	out: [dynamic]ServiceSnapshot
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	for id, svc in agent.services {
		if svc.live {
			continue
		}
		owned, err := strings.clone(string(id))
		if err != .None {
			continue
		}
		append(&out, ServiceSnapshot{id = proto.ServiceId(owned), target = svc.target})
	}
	return out
}

agent_mark_live :: proc(agent: ^Agent, service_id: proto.ServiceId) {
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	svc, ok := agent.services[service_id]
	if !ok {
		return
	}
	svc.live = true
	agent.services[service_id] = svc
}

agent_clear_live :: proc(agent: ^Agent) {
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	for id, svc in agent.services {
		entry := svc
		entry.live = false
		agent.services[id] = entry
	}
}

agent_all_live :: proc(agent: ^Agent) -> bool {
	sync.mutex_lock(&agent.mutex)
	defer sync.mutex_unlock(&agent.mutex)
	for _, svc in agent.services {
		if !svc.live {
			return false
		}
	}
	return true
}

free_snapshots :: proc(items: [dynamic]ServiceSnapshot) {
	for item in items {
		delete(string(item.id))
	}
	delete(items)
}

wire_to_register_error :: proc(code: proto.WireError) -> AgentError {
	switch code {
	case .None:
		return .None
	case .ServiceAlreadyRegistered:
		return .ServiceAlreadyRegistered
	case .BrokerDraining:
		return .BrokerDraining
	case .InvalidServiceId:
		return .InvalidServiceId
	case .QuotaExceeded:
		return .QuotaExceeded
	case .AuthenticationFailed, .Unauthorized:
		return .AuthFailed
	case .ProtocolError, .UnsupportedVersion, .ServiceNotFound, .AgentUnavailable,
	     .LocalServiceUnavailable, .RateLimited, .StreamNotFound, .StreamAlreadyExists,
	     .FrameTooLarge, .Timeout, .InternalError:
		return .RegisterFailed
	}
	return .RegisterFailed
}
