package auth

import "core:testing"
import "core:time"

@(test)
test_authenticate_token_known_token_returns_principal :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-a"), AuthError.None)
	result, err := authenticate_token(&store, transmute([]u8)string("host-dev-token"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect_value(t, result.id, "host-a")
	testing.expect_value(t, result.organization, DEFAULT_ORGANIZATION)
	testing.expect_value(t, result.capabilities, TokenCapabilities{})
	testing.expect_value(t, result.label, "")
	testing.expect_value(t, result.credential_id, "")
	testing.expect_value(t, result.environment_id, "")
	testing.expect_value(t, result.principal_kind, "")
	testing.expect_value(t, result.policy_version, i64(0))
}

@(test)
test_authenticate_token_unknown_and_empty_fail :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-a"), AuthError.None)

	_, err := authenticate_token(&store, transmute([]u8)string("wrong-token"))
	testing.expect_value(t, err, AuthError.InvalidToken)

	_, err = authenticate_token(&store, nil)
	testing.expect_value(t, err, AuthError.InvalidToken)

	_, err = authenticate_token(&store, {})
	testing.expect_value(t, err, AuthError.InvalidToken)
}

@(test)
test_authenticate_token_does_not_use_token_as_principal_id :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-a", "org/dev"), AuthError.None)
	result, err := authenticate_token(&store, transmute([]u8)string("host-dev-token"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect(t, result.id != "host-dev-token")
	testing.expect_value(t, result.id, "host-a")
}

@(test)
test_auth_add_token_rejects_empty_principal :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "tok", ""), AuthError.InvalidPrincipal)
	testing.expect_value(t, auth_add_token(&store, "", "host-a"), AuthError.InvalidToken)
}

@(test)
test_auth_add_token_rejects_duplicate :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-a"), AuthError.None)
	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-b"), AuthError.InvalidToken)
}

@(test)
test_authenticate_token_equal_length_wrong_token_fails :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-a"), AuthError.None)
	_, err := authenticate_token(&store, transmute([]u8)string("host-dev-tokeX"))
	testing.expect_value(t, err, AuthError.InvalidToken)
}

@(test)
test_authenticate_token_two_tokens_map_to_distinct_principals :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "host-dev-token", "host-a"), AuthError.None)
	testing.expect_value(t, auth_add_token(&store, "caller-dev-token", "client-a"), AuthError.None)

	result, err := authenticate_token(&store, transmute([]u8)string("host-dev-token"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect_value(t, result.id, "host-a")

	result, err = authenticate_token(&store, transmute([]u8)string("caller-dev-token"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect_value(t, result.id, "client-a")
}

@(test)
test_auth_add_credential_stores_caps_label_expiry :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	expires := time.time_add(time.now(), 24 * time.Hour)
	testing.expect_value(
		t,
		auth_add_credential(
			&store,
			CredentialSpec {
				token        = "host-site-17",
				principal_id = "agent-site-17",
				organization = "acme",
				capabilities = {.RegisterService},
				label        = "site-17-agent",
				expires_at   = expires,
			},
		),
		AuthError.None,
	)
	result, err := authenticate_token(&store, transmute([]u8)string("host-site-17"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect_value(t, result.id, "agent-site-17")
	testing.expect_value(t, result.organization, "acme")
	testing.expect_value(t, result.capabilities, TokenCapabilities{.RegisterService})
	testing.expect_value(t, result.label, "site-17-agent")
	testing.expect_value(t, result.expires_at, expires)
}

@(test)
test_authenticate_token_overlapping_tokens_same_principal :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "old-host-token", "host-a"), AuthError.None)
	testing.expect_value(t, auth_add_token(&store, "new-host-token", "host-a"), AuthError.None)

	old, oerr := authenticate_token(&store, transmute([]u8)string("old-host-token"))
	testing.expect_value(t, oerr, AuthError.None)
	testing.expect_value(t, old.id, "host-a")

	next, nerr := authenticate_token(&store, transmute([]u8)string("new-host-token"))
	testing.expect_value(t, nerr, AuthError.None)
	testing.expect_value(t, next.id, "host-a")
}

@(test)
test_authenticate_token_expired_credential_fails :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(
		t,
		auth_add_credential(
			&store,
			CredentialSpec {
				token        = "expired-token",
				principal_id = "host-a",
				expires_at   = time.time_add(time.now(), -time.Hour),
			},
		),
		AuthError.None,
	)
	_, err := authenticate_token(&store, transmute([]u8)string("expired-token"))
	testing.expect_value(t, err, AuthError.Expired)
}

@(test)
test_authenticate_token_future_expiry_succeeds :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(
		t,
		auth_add_credential(
			&store,
			CredentialSpec {
				token        = "fresh-token",
				principal_id = "host-a",
				expires_at   = time.time_add(time.now(), 24 * time.Hour),
			},
		),
		AuthError.None,
	)
	result, err := authenticate_token(&store, transmute([]u8)string("fresh-token"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect_value(t, result.id, "host-a")
}

@(test)
test_authenticate_token_does_not_infer_capabilities_from_spelling :: proc(t: ^testing.T) {
	store: StaticTokenAuth
	testing.expect_value(t, auth_init(&store), AuthError.None)
	defer auth_destroy(&store)

	testing.expect_value(t, auth_add_token(&store, "agent-site-17", "host-a"), AuthError.None)
	result, err := authenticate_token(&store, transmute([]u8)string("agent-site-17"))
	testing.expect_value(t, err, AuthError.None)
	testing.expect_value(t, result.capabilities, TokenCapabilities{})
}
