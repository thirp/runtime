package broker

import proto "../protocol"
import "core:mem"
import "core:strings"

PolicyGrant :: struct {
	key:     string,
	pattern: string,
}

StaticPolicy :: struct {
	allocator:       mem.Allocator,
	capabilities:    map[string]PrincipalCapabilities,
	register_grants: [dynamic]PolicyGrant,
	connect_grants:  [dynamic]PolicyGrant,
	org_grants:      [dynamic]PolicyGrant,
}

policy_init :: proc(policy: ^StaticPolicy, allocator := context.allocator) -> PolicyError {
	policy^ = {}
	policy.allocator = allocator
	policy.capabilities = make(map[string]PrincipalCapabilities, allocator)
	policy.register_grants = make([dynamic]PolicyGrant, allocator)
	policy.connect_grants = make([dynamic]PolicyGrant, allocator)
	policy.org_grants = make([dynamic]PolicyGrant, allocator)
	return .None
}

policy_destroy :: proc(policy: ^StaticPolicy) {
	if policy == nil {
		return
	}
	for key in policy.capabilities {
		delete(key, policy.allocator)
	}
	delete(policy.capabilities)
	destroy_grants(policy.register_grants, policy.allocator)
	destroy_grants(policy.connect_grants, policy.allocator)
	destroy_grants(policy.org_grants, policy.allocator)
	policy^ = {}
}

destroy_grants :: proc(grants: [dynamic]PolicyGrant, allocator: mem.Allocator) {
	for grant in grants {
		delete(grant.key, allocator)
		delete(grant.pattern, allocator)
	}
	delete(grants)
}

check_grant_pattern :: proc(pattern: string) -> PolicyError {
	if len(pattern) == 0 {
		return .InvalidPattern
	}
	if strings.has_suffix(pattern, "/*") {
		stem := pattern[:len(pattern) - 2]
		if len(stem) == 0 || strings.contains(stem, "*") {
			return .InvalidPattern
		}
		if proto.check_service_id(stem) != .None {
			return .InvalidPattern
		}
		return .None
	}
	if strings.contains(pattern, "*") {
		return .InvalidPattern
	}
	if proto.check_service_id(pattern) != .None {
		return .InvalidPattern
	}
	return .None
}

service_id_matches_pattern :: proc(service_id: ServiceId, pattern: string) -> bool {
	name := string(service_id)
	if strings.has_suffix(pattern, "/*") {
		prefix := pattern[:len(pattern) - 1]
		return strings.has_prefix(name, prefix)
	}
	return name == pattern
}

policy_set_capabilities :: proc(
	policy: ^StaticPolicy,
	principal_id: string,
	caps: PrincipalCapabilities,
) -> PolicyError {
	if policy == nil || check_identity_string(principal_id) != .None {
		return .InvalidPrincipal
	}
	if _, found := policy.capabilities[principal_id]; found {
		policy.capabilities[principal_id] = caps
		return .None
	}
	owned, oerr := strings.clone(principal_id, policy.allocator)
	if oerr != .None {
		return .OutOfMemory
	}
	policy.capabilities[owned] = caps
	return .None
}

policy_capabilities :: proc(policy: ^StaticPolicy, principal_id: string) -> PrincipalCapabilities {
	if policy == nil {
		return {}
	}
	caps, ok := policy.capabilities[principal_id]
	if !ok {
		return {}
	}
	return caps
}

policy_add_grant :: proc(
	policy: ^StaticPolicy,
	grants: ^[dynamic]PolicyGrant,
	key: string,
	pattern: string,
) -> PolicyError {
	if policy == nil || check_identity_string(key) != .None {
		return .InvalidPrincipal
	}
	if err := check_grant_pattern(pattern); err != .None {
		return err
	}
	owned_key, kerr := strings.clone(key, policy.allocator)
	if kerr != .None {
		return .OutOfMemory
	}
	owned_pattern, perr := strings.clone(pattern, policy.allocator)
	if perr != .None {
		delete(owned_key, policy.allocator)
		return .OutOfMemory
	}
	_, aerr := append(grants, PolicyGrant{key = owned_key, pattern = owned_pattern})
	if aerr != .None {
		delete(owned_key, policy.allocator)
		delete(owned_pattern, policy.allocator)
		return .OutOfMemory
	}
	return .None
}

policy_add_namespace_grant :: proc(
	policy: ^StaticPolicy,
	principal_id: string,
	pattern: string,
) -> PolicyError {
	return policy_add_grant(policy, &policy.register_grants, principal_id, pattern)
}

policy_add_connect_grant :: proc(
	policy: ^StaticPolicy,
	principal_id: string,
	pattern: string,
) -> PolicyError {
	return policy_add_grant(policy, &policy.connect_grants, principal_id, pattern)
}

policy_add_org_namespace :: proc(
	policy: ^StaticPolicy,
	organization: string,
	pattern: string,
) -> PolicyError {
	return policy_add_grant(policy, &policy.org_grants, organization, pattern)
}

grant_matches :: proc(grants: []PolicyGrant, key: string, service_id: ServiceId) -> bool {
	for grant in grants {
		if grant.key == key && service_id_matches_pattern(service_id, grant.pattern) {
			return true
		}
	}
	return false
}

org_has_namespace_grants :: proc(grants: []PolicyGrant, organization: string) -> bool {
	for grant in grants {
		if grant.key == organization {
			return true
		}
	}
	return false
}

check_register :: proc(policy: ^StaticPolicy, principal: Principal, service_id: ServiceId) -> PolicyError {
	if policy == nil || .RegisterService not_in principal.capabilities {
		return .MissingCapability
	}
	if !grant_matches(policy.register_grants[:], string(principal.id), service_id) {
		return .NamespaceDenied
	}
	org := string(principal.organization)
	if org_has_namespace_grants(policy.org_grants[:], org) {
		if !grant_matches(policy.org_grants[:], org, service_id) {
			return .NamespaceDenied
		}
	}
	return .None
}

check_unregister :: proc(policy: ^StaticPolicy, principal: Principal) -> PolicyError {
	if policy == nil || .RegisterService not_in principal.capabilities {
		return .MissingCapability
	}
	return .None
}

check_connect :: proc(policy: ^StaticPolicy, principal: Principal, rec: ServiceRegistration) -> PolicyError {
	if policy == nil || .ConnectService not_in principal.capabilities {
		return .MissingCapability
	}
	if !grant_matches(policy.connect_grants[:], string(principal.id), rec.id) {
		return .NamespaceDenied
	}
	return .None
}
