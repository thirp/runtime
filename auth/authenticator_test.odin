package auth

import "core:testing"

@(test)
test_static_token_authenticator_returns_store_principal :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-a"), AuthError.None)
	a := static_token_authenticator(&store)
	result, err := authenticate(a, transmute([]u8)string("host-dev-token"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect_value(t, result.id, "host-a")
	testing.expect_value(t, result.organization, DEFAULT_ORGANIZATION)
	testing.expect_value(t, result.credential_id, "")
	testing.expect_value(t, result.environment_id, "")
	testing.expect_value(t, result.principal_kind, "")
	testing.expect_value(t, result.policy_version, i64(0))
}

@(test)
test_authenticate_nil_proc_fails_closed :: proc(t: ^testing.T) {
	_, err := authenticate({}, transmute([]u8)string("host-dev-token"))
	testing.expect_value(t, err, AuthError.InvalidToken)

	a := Authenticator{authenticate = nil}
	_, err = authenticate(a, transmute([]u8)string("host-dev-token"))
	testing.expect_value(t, err, AuthError.InvalidToken)
}
