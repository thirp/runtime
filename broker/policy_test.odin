package broker

import "core:testing"

handler_for_principal :: proc(principal: Principal) -> ConnHandler {
	return ConnHandler {
		principal_id = string(principal.id),
		organization = string(principal.organization),
		capabilities = principal.capabilities,
	}
}

@(test)
test_check_register_policy_development_allow_all :: proc(t: ^testing.T) {
	server: Server
	server.policy_mode = .Development
	server.may_register = may_register_allow_all
	principal := must_principal(t, "host-a", "org/dev")
	h := handler_for_principal(principal)
	sid := must_service_id(t, "demo/echo")
	testing.expect_value(t, check_register_policy(&server, &h, sid), PolicyError.None)
}

@(test)
test_check_register_policy_development_nil_allow_all :: proc(t: ^testing.T) {
	server: Server
	server.policy_mode = .Development
	server.may_register = nil
	principal := must_principal(t, "host-a", "org/dev")
	h := handler_for_principal(principal)
	sid := must_service_id(t, "demo/echo")
	testing.expect_value(t, check_register_policy(&server, &h, sid), PolicyError.None)
}

@(test)
test_check_register_policy_development_deny_all :: proc(t: ^testing.T) {
	server: Server
	server.policy_mode = .Development
	server.may_register = may_register_deny_all
	principal := must_principal(t, "host-a", "org/dev")
	h := handler_for_principal(principal)
	sid := must_service_id(t, "demo/echo")
	testing.expect_value(t, check_register_policy(&server, &h, sid), PolicyError.Unauthorized)
}

@(test)
test_check_connect_policy_development_deny_all :: proc(t: ^testing.T) {
	server: Server
	server.policy_mode = .Development
	server.may_connect = may_connect_deny_all
	principal := must_principal(t, "client-a", "org/dev")
	h := handler_for_principal(principal)
	rec := ServiceRegistration{id = must_service_id(t, "demo/echo")}
	_, err := check_connect_policy(&server, &h, rec)
	testing.expect_value(t, err, PolicyError.Unauthorized)
}

@(test)
test_check_register_policy_production_ignores_allow_all :: proc(t: ^testing.T) {
	server: Server
	testing.expect_value(t, policy_init(&server.policy), PolicyError.None)
	defer policy_destroy(&server.policy)
	server.policy_mode = .Production
	server.may_register = may_register_allow_all
	principal := must_principal(t, "host-a", "org/dev")
	principal.capabilities = {.RegisterService}
	h := handler_for_principal(principal)
	sid := must_service_id(t, "demo/echo")
	testing.expect_value(t, check_register_policy(&server, &h, sid), PolicyError.NamespaceDenied)
}

@(test)
test_check_register_policy_production_grant_allows_only_granted :: proc(t: ^testing.T) {
	server: Server
	testing.expect_value(t, policy_init(&server.policy), PolicyError.None)
	defer policy_destroy(&server.policy)
	server.policy_mode = .Production
	server.may_register = may_register_allow_all
	testing.expect_value(t, policy_set_capabilities(&server.policy, "host-a", {.RegisterService}), PolicyError.None)
	testing.expect_value(t, policy_add_namespace_grant(&server.policy, "host-a", "acme/site-17/*"), PolicyError.None)

	principal := must_principal(t, "host-a", "org/dev")
	principal.capabilities = policy_capabilities(&server.policy, "host-a")
	h := handler_for_principal(principal)
	ok := must_service_id(t, "acme/site-17/reporting-api")
	testing.expect_value(t, check_register_policy(&server, &h, ok), PolicyError.None)
	denied := must_service_id(t, "acme/other")
	testing.expect_value(t, check_register_policy(&server, &h, denied), PolicyError.NamespaceDenied)
}

@(test)
test_check_connect_policy_production_ignores_allow_all :: proc(t: ^testing.T) {
	server: Server
	testing.expect_value(t, policy_init(&server.policy), PolicyError.None)
	defer policy_destroy(&server.policy)
	server.policy_mode = .Production
	server.may_connect = may_connect_allow_all
	principal := must_principal(t, "client-a", "org/dev")
	principal.capabilities = {.ConnectService}
	h := handler_for_principal(principal)
	rec := ServiceRegistration{id = must_service_id(t, "demo/echo")}
	_, err := check_connect_policy(&server, &h, rec)
	testing.expect_value(t, err, PolicyError.NamespaceDenied)
}
