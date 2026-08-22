package broker

import proto "../protocol"
import "core:time"

AuthzError :: enum {
	None,
	Denied,
	Unavailable,
	OutOfMemory,
}

RegisterAuthzRequest :: struct {
	principal:           Principal,
	credential_id:       string,
	environment_id:      string,
	principal_kind:      string,
	auth_policy_version: i64,
	service_id:          ServiceId,
}

ConnectAuthzRequest :: struct {
	principal:           Principal,
	credential_id:       string,
	environment_id:      string,
	principal_kind:      string,
	auth_policy_version: i64,
	service:             ServiceRegistration,
}

AuthzDecision :: struct {
	allowed:                   bool,
	reason:                    AuthzReason,
	organization_id:           string,
	environment_id:            string,
	access_grant_id:           string,
	valid_until:               time.Time,
	authorization_lease_until: time.Time,
	policy_version:            i64,
}

Authorizer :: struct {
	ctx:                rawptr,
	authorize_register: proc(ctx: rawptr, req: RegisterAuthzRequest) -> (AuthzDecision, AuthzError),
	authorize_connect:  proc(ctx: rawptr, req: ConnectAuthzRequest) -> (AuthzDecision, AuthzError),
}

RegistrationEventKind :: enum {
	Registered,
	Unregistered,
}

RegistrationEvent :: struct {
	kind:             RegistrationEventKind,
	service_id:       ServiceId,
	principal_id:     string,
	organization_id:  string,
	environment_id:   string,
	credential_id:    string,
	session_id:       SessionId,
}

RegistrationObserverProc :: proc(ctx: rawptr, ev: RegistrationEvent)

ConnectionEventKind :: enum {
	Authorized,
	Denied,
	Opened,
	Closed,
	Reset,
}

ConnectionEvent :: struct {
	kind:                   ConnectionEventKind,
	stream_id:              proto.StreamId,
	service_id:             ServiceId,
	grant_id:               string,
	credential_id:          string,
	principal_id:           string,
	organization_id:        string,
	environment_id:         string,
	session_id:             SessionId,
	termination_reason:     string,
	bytes_caller_to_agent:  u64,
	bytes_agent_to_caller:  u64,
}

ConnectionObserverProc :: proc(ctx: rawptr, ev: ConnectionEvent)

authz_time_is_set :: proc(t: time.Time) -> bool {
	return t != {}
}

authorize_register :: proc(a: Authorizer, req: RegisterAuthzRequest) -> (AuthzDecision, AuthzError) {
	if a.authorize_register == nil {
		return {}, .Unavailable
	}
	return a.authorize_register(a.ctx, req)
}

authorize_connect :: proc(a: Authorizer, req: ConnectAuthzRequest) -> (AuthzDecision, AuthzError) {
	if a.authorize_connect == nil {
		return {}, .Unavailable
	}
	return a.authorize_connect(a.ctx, req)
}

static_policy_authorizer :: proc(policy: ^StaticPolicy) -> Authorizer {
	return Authorizer {
		ctx                = policy,
		authorize_register = static_authorize_register,
		authorize_connect  = static_authorize_connect,
	}
}

static_authorize_register :: proc(ctx: rawptr, req: RegisterAuthzRequest) -> (AuthzDecision, AuthzError) {
	policy := (^StaticPolicy)(ctx)
	principal := req.principal
	if policy != nil {
		principal.capabilities = principal.capabilities + policy_capabilities(policy, string(principal.id))
	}
	perr := check_register(policy, principal, req.service_id)
	return policy_error_to_decision(perr, string(principal.organization), req.environment_id), .None
}

static_authorize_connect :: proc(ctx: rawptr, req: ConnectAuthzRequest) -> (AuthzDecision, AuthzError) {
	policy := (^StaticPolicy)(ctx)
	principal := req.principal
	if policy != nil {
		principal.capabilities = principal.capabilities + policy_capabilities(policy, string(principal.id))
	}
	perr := check_connect(policy, principal, req.service)
	return policy_error_to_decision(perr, string(principal.organization), req.environment_id), .None
}

policy_error_to_decision :: proc(err: PolicyError, organization_id: string, environment_id: string) -> AuthzDecision {
	d: AuthzDecision
	d.organization_id = organization_id
	d.environment_id = environment_id
	if err == .None {
		d.allowed = true
		return d
	}
	d.reason = policy_error_to_authz(err)
	return d
}

authz_to_policy_error :: proc(d: AuthzDecision, err: AuthzError) -> PolicyError {
	if err == .OutOfMemory {
		return .OutOfMemory
	}
	if err == .Unavailable {
		return .Unauthorized
	}
	if err == .Denied || !d.allowed {
		switch d.reason {
		case .Capability:
			return .MissingCapability
		case .Namespace:
			return .NamespaceDenied
		case .Quota:
			return .QuotaExceeded
		case .NotOwned, .Unauthorized:
			return .Unauthorized
		}
		return .Unauthorized
	}
	if err != .None {
		return .Unauthorized
	}
	return .None
}
