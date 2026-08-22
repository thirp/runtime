package broker

import "core:testing"

must_init_policy :: proc(t: ^testing.T, policy: ^StaticPolicy, loc := #caller_location) {
	testing.expect_value(t, policy_init(policy), PolicyError.None, loc)
}

@(test)
test_service_id_matches_exact_and_prefix :: proc(t: ^testing.T) {
	sid := must_service_id(t, "acme/site-17/reporting-api")
	testing.expect(t, service_id_matches_pattern(sid, "acme/site-17/reporting-api"))
	testing.expect(t, service_id_matches_pattern(sid, "acme/site-17/*"))
	testing.expect(t, !service_id_matches_pattern(sid, "acme/other"))
	testing.expect(t, !service_id_matches_pattern(sid, "acme/other/*"))
	other := must_service_id(t, "acme/other")
	testing.expect(t, !service_id_matches_pattern(other, "acme/site-17/*"))
}

@(test)
test_check_grant_pattern_rejects_mid_star :: proc(t: ^testing.T) {
	testing.expect_value(t, check_grant_pattern("acme/*/reporting-api"), PolicyError.InvalidPattern)
	testing.expect_value(t, check_grant_pattern("acme*"), PolicyError.InvalidPattern)
	testing.expect_value(t, check_grant_pattern("*"), PolicyError.InvalidPattern)
	testing.expect_value(t, check_grant_pattern("/*"), PolicyError.InvalidPattern)
	testing.expect_value(t, check_grant_pattern("acme/site-17/*"), PolicyError.None)
	testing.expect_value(t, check_grant_pattern("acme/site-17/reporting-api"), PolicyError.None)
}

@(test)
test_check_register_empty_policy_denies :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	principal := must_principal(t, "host-a", "org/dev")
	principal.capabilities = {.RegisterService}
	sid := must_service_id(t, "acme/site-17/reporting-api")
	testing.expect_value(t, check_register(&policy, principal, sid), PolicyError.NamespaceDenied)
}

@(test)
test_check_register_capability_without_grant_denies :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	testing.expect_value(t, policy_set_capabilities(&policy, "host-a", {.RegisterService}), PolicyError.None)
	principal := must_principal(t, "host-a", "org/dev")
	principal.capabilities = policy_capabilities(&policy, "host-a")
	sid := must_service_id(t, "acme/site-17/reporting-api")
	testing.expect_value(t, check_register(&policy, principal, sid), PolicyError.NamespaceDenied)
}

@(test)
test_check_register_grant_without_capability_denies :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	testing.expect_value(t, policy_add_namespace_grant(&policy, "host-a", "acme/site-17/*"), PolicyError.None)
	principal := must_principal(t, "host-a", "org/dev")
	sid := must_service_id(t, "acme/site-17/reporting-api")
	testing.expect_value(t, check_register(&policy, principal, sid), PolicyError.MissingCapability)
}

@(test)
test_check_register_cap_and_grant_allows :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	testing.expect_value(t, policy_set_capabilities(&policy, "host-a", {.RegisterService}), PolicyError.None)
	testing.expect_value(t, policy_add_namespace_grant(&policy, "host-a", "acme/site-17/*"), PolicyError.None)
	principal := must_principal(t, "host-a", "org/dev")
	principal.capabilities = policy_capabilities(&policy, "host-a")
	sid := must_service_id(t, "acme/site-17/reporting-api")
	testing.expect_value(t, check_register(&policy, principal, sid), PolicyError.None)
	other := must_service_id(t, "acme/other")
	testing.expect_value(t, check_register(&policy, principal, other), PolicyError.NamespaceDenied)
}

@(test)
test_check_register_org_grant_and_principal_grant :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	testing.expect_value(t, policy_set_capabilities(&policy, "host-a", {.RegisterService}), PolicyError.None)
	testing.expect_value(t, policy_add_namespace_grant(&policy, "host-a", "acme/site-17/*"), PolicyError.None)
	testing.expect_value(t, policy_add_org_namespace(&policy, "acme", "acme/*"), PolicyError.None)

	inside := must_principal(t, "host-a", "acme")
	inside.capabilities = policy_capabilities(&policy, "host-a")
	sid := must_service_id(t, "acme/site-17/reporting-api")
	testing.expect_value(t, check_register(&policy, inside, sid), PolicyError.None)
}

@(test)
test_check_register_principal_grant_outside_org_ownership_denies :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	testing.expect_value(t, policy_set_capabilities(&policy, "host-a", {.RegisterService}), PolicyError.None)
	testing.expect_value(t, policy_add_namespace_grant(&policy, "host-a", "evil/*"), PolicyError.None)
	testing.expect_value(t, policy_add_org_namespace(&policy, "acme", "acme/*"), PolicyError.None)

	principal := must_principal(t, "host-a", "acme")
	principal.capabilities = policy_capabilities(&policy, "host-a")
	sid := must_service_id(t, "evil/x")
	testing.expect_value(t, check_register(&policy, principal, sid), PolicyError.NamespaceDenied)
}

@(test)
test_check_unregister_is_capability_only :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	none := must_principal(t, "host-a", "org/dev")
	testing.expect_value(t, check_unregister(&policy, none), PolicyError.MissingCapability)

	testing.expect_value(t, policy_set_capabilities(&policy, "host-a", {.RegisterService}), PolicyError.None)
	has := must_principal(t, "host-a", "org/dev")
	has.capabilities = policy_capabilities(&policy, "host-a")
	testing.expect_value(t, check_unregister(&policy, has), PolicyError.None)
}

@(test)
test_check_connect_requires_capability_and_grant :: proc(t: ^testing.T) {
	policy: StaticPolicy
	must_init_policy(t, &policy)
	defer policy_destroy(&policy)

	rec := ServiceRegistration{id = must_service_id(t, "acme/site-17/reporting-api")}
	none := must_principal(t, "client-a", "org/dev")
	testing.expect_value(t, check_connect(&policy, none, rec), PolicyError.MissingCapability)

	testing.expect_value(t, policy_set_capabilities(&policy, "client-a", {.ConnectService}), PolicyError.None)
	cap_only := must_principal(t, "client-a", "org/dev")
	cap_only.capabilities = policy_capabilities(&policy, "client-a")
	testing.expect_value(t, check_connect(&policy, cap_only, rec), PolicyError.NamespaceDenied)

	testing.expect_value(t, policy_add_connect_grant(&policy, "client-a", "acme/site-17/reporting-api"), PolicyError.None)
	ok := must_principal(t, "client-a", "org/dev")
	ok.capabilities = policy_capabilities(&policy, "client-a")
	testing.expect_value(t, check_connect(&policy, ok, rec), PolicyError.None)

	sibling := ServiceRegistration{id = must_service_id(t, "acme/site-17/other")}
	testing.expect_value(t, check_connect(&policy, ok, sibling), PolicyError.NamespaceDenied)
}
