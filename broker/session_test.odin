package broker

import "core:testing"

@(test)
test_make_principal_id_rejects_empty :: proc(t: ^testing.T) {
	_, err := make_principal_id("")
	testing.expect_value(t, err, IdentityError.Empty)
}

@(test)
test_make_principal_id_rejects_too_long :: proc(t: ^testing.T) {
	buf: [MAX_IDENTITY_LEN + 1]u8
	for i in 0 ..< len(buf) {
		buf[i] = 'a'
	}
	_, err := make_principal_id(string(buf[:]))
	testing.expect_value(t, err, IdentityError.TooLong)
	_, err = make_principal_id(string(buf[:MAX_IDENTITY_LEN]))
	testing.expect_value(t, err, IdentityError.None)
}

@(test)
test_make_organization_id_rejects_empty :: proc(t: ^testing.T) {
	_, err := make_organization_id("")
	testing.expect_value(t, err, IdentityError.Empty)
}

@(test)
test_make_principal_accepts_dev_org :: proc(t: ^testing.T) {
	p, err := make_principal("host-a", "org/dev")
	testing.expect_value(t, err, IdentityError.None)
	testing.expect_value(t, string(p.id), "host-a")
	testing.expect_value(t, string(p.organization), "org/dev")
}

@(test)
test_registry_add_session_assigns_nonzero_id :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	p := must_principal(t, "host-a", "org/dev")
	sid := must_add_session(t, &reg, p)
	testing.expect(t, sid != INVALID_SESSION_ID)
}

@(test)
test_registry_add_session_rejects_empty_principal :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	sid, err := registry_add_session(&reg, Principal{})
	testing.expect_value(t, err, RegistryError.InvalidPrincipal)
	testing.expect_value(t, sid, INVALID_SESSION_ID)
}

@(test)
test_registry_remove_session_unknown :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	err := registry_remove_session(&reg, SessionId(99))
	testing.expect_value(t, err, RegistryError.SessionNotFound)
}

@(test)
test_registry_touch_session_updates_existing :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	p := must_principal(t, "host-a", "org/dev")
	sid := must_add_session(t, &reg, p)
	testing.expect_value(t, registry_touch_session(&reg, sid), RegistryError.None)
	testing.expect_value(t, registry_touch_session(&reg, SessionId(99)), RegistryError.SessionNotFound)
}

@(test)
test_remove_session_services_leaves_session :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	p := must_principal(t, "host-a", "org/dev")
	sid := must_add_session(t, &reg, p)
	svc := must_service_id(t, "game/7QF3P9")
	testing.expect_value(t, register_service(&reg, sid, svc), RegistryError.None)
	testing.expect_value(t, remove_session_services(&reg, sid), RegistryError.None)
	_, found := lookup_service(&reg, svc)
	testing.expect(t, !found)
	testing.expect_value(t, service_count(&reg), 0)
	testing.expect_value(t, register_service(&reg, sid, svc), RegistryError.None)
	rec, ok := lookup_service(&reg, svc)
	testing.expect(t, ok)
	testing.expect_value(t, rec.agent_session, sid)
}
