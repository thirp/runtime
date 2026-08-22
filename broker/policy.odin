package broker

may_register_allow_all :: proc(principal: Principal, service_id: ServiceId) -> bool {
	_ = principal
	_ = service_id
	return true
}

may_register_deny_all :: proc(principal: Principal, service_id: ServiceId) -> bool {
	_ = principal
	_ = service_id
	return false
}

MayRegisterProc :: proc(principal: Principal, service_id: ServiceId) -> bool

may_connect_allow_all :: proc(principal: Principal, rec: ServiceRegistration) -> bool {
	_ = principal
	_ = rec
	return true
}

may_connect_deny_all :: proc(principal: Principal, rec: ServiceRegistration) -> bool {
	_ = principal
	_ = rec
	return false
}

MayConnectProc :: proc(principal: Principal, rec: ServiceRegistration) -> bool

production_principal :: proc(server: ^Server, principal: Principal) -> Principal {
	next := principal
	next.capabilities = principal.capabilities + policy_capabilities(&server.policy, string(principal.id))
	return next
}

check_register_policy :: proc(server: ^Server, h: ^ConnHandler, service_id: ServiceId) -> PolicyError {
	principal := conn_handler_principal(h)
	if server != nil && server.authorizer.authorize_register != nil {
		req := RegisterAuthzRequest {
			principal           = principal,
			credential_id       = h.credential_id,
			environment_id      = h.environment_id,
			principal_kind      = h.principal_kind,
			auth_policy_version = h.auth_policy_version,
			service_id          = service_id,
		}
		d, err := authorize_register(server.authorizer, req)
		return authz_to_policy_error(d, err)
	}
	if server != nil && server.policy_mode == .Production {
		return check_register(&server.policy, production_principal(server, principal), service_id)
	}
	may := server != nil ? server.may_register : nil
	if may == nil {
		may = may_register_allow_all
	}
	if !may(principal, service_id) {
		return .Unauthorized
	}
	return .None
}

check_unregister_policy :: proc(server: ^Server, principal: Principal) -> PolicyError {
	if server != nil && server.policy_mode == .Production {
		return check_unregister(&server.policy, production_principal(server, principal))
	}
	return .None
}

check_connect_policy :: proc(
	server: ^Server,
	h: ^ConnHandler,
	rec: ServiceRegistration,
) -> (
	AuthzDecision,
	PolicyError,
) {
	principal := conn_handler_principal(h)
	if server != nil && server.authorizer.authorize_connect != nil {
		req := ConnectAuthzRequest {
			principal           = principal,
			credential_id       = h.credential_id,
			environment_id      = h.environment_id,
			principal_kind      = h.principal_kind,
			auth_policy_version = h.auth_policy_version,
			service             = rec,
		}
		d, err := authorize_connect(server.authorizer, req)
		return d, authz_to_policy_error(d, err)
	}
	if server != nil && server.policy_mode == .Production {
		return {}, check_connect(&server.policy, production_principal(server, principal), rec)
	}
	may := server != nil ? server.may_connect : nil
	if may == nil {
		may = may_connect_allow_all
	}
	if !may(principal, rec) {
		return {}, .Unauthorized
	}
	return {}, .None
}
