package broker

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

@(test)
test_register_service_then_lookup_matches_snapshot :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	p := must_principal(t, "host-a", "org/dev")
	sid := must_add_session(t, &reg, p)
	svc := must_service_id(t, "game/7QF3P9")

	testing.expect_value(t, register_service(&reg, sid, svc), RegistryError.None)
	testing.expect_value(t, service_count(&reg), 1)

	rec, ok := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, ok)
	testing.expect_value(t, string(rec.id), "game/7QF3P9")
	testing.expect_value(t, string(rec.owner), "host-a")
	testing.expect_value(t, string(rec.organization), "org/dev")
	testing.expect_value(t, rec.agent_session, sid)
}

@(test)
test_unregister_service_drops_lookup_and_count :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	p := must_principal(t, "host-a", "org/dev")
	sid := must_add_session(t, &reg, p)
	svc := must_service_id(t, "acme/atlanta/reporting-api")

	testing.expect_value(t, register_service(&reg, sid, svc), RegistryError.None)
	testing.expect_value(t, unregister_service(&reg, sid, svc), RegistryError.None)
	_, found := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, !found)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_register_service_duplicate_rejected :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	p := must_principal(t, "host-a", "org/dev")
	sid := must_add_session(t, &reg, p)
	svc := must_service_id(t, "game/7QF3P9")

	testing.expect_value(t, register_service(&reg, sid, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, sid, svc), RegistryError.ServiceAlreadyRegistered)

	other := must_principal(t, "host-b", "org/dev")
	sid2 := must_add_session(t, &reg, other)
	testing.expect_value(t, register_service(&reg, sid2, svc), RegistryError.ServiceAlreadyRegistered)

	rec, ok := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, ok)
	testing.expect_value(t, rec.agent_session, sid)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_register_service_two_sessions_two_ids :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	a := must_add_session(t, &reg, must_principal(t, "host-a", "org/dev"))
	b := must_add_session(t, &reg, must_principal(t, "host-b", "org/dev"))
	svc_a := must_service_id(t, "game/aaa")
	svc_b := must_service_id(t, "game/bbb")

	testing.expect_value(t, register_service(&reg, a, svc_a), RegistryError.None)
	testing.expect_value(t, register_service(&reg, b, svc_b), RegistryError.None)
	testing.expect_value(t, service_count(&reg), 2)

	rec_a, ok_a := lookup_service_for_environment(&reg, "", svc_a, "org/dev")
	rec_b, ok_b := lookup_service_for_environment(&reg, "", svc_b, "org/dev")
	testing.expect(t, ok_a)
	testing.expect(t, ok_b)
	testing.expect_value(t, rec_a.agent_session, a)
	testing.expect_value(t, rec_b.agent_session, b)
}

@(test)
test_registry_remove_session_cleans_only_that_session :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	a := must_add_session(t, &reg, must_principal(t, "host-a", "org/dev"))
	b := must_add_session(t, &reg, must_principal(t, "host-b", "org/dev"))
	svc_a := must_service_id(t, "game/aaa")
	svc_b := must_service_id(t, "game/bbb")
	testing.expect_value(t, register_service(&reg, a, svc_a), RegistryError.None)
	testing.expect_value(t, register_service(&reg, b, svc_b), RegistryError.None)

	testing.expect_value(t, registry_remove_session(&reg, a), RegistryError.None)
	_, found_a := lookup_service_for_environment(&reg, "", svc_a, "org/dev")
	testing.expect(t, !found_a)
	rec_b, found_b := lookup_service_for_environment(&reg, "", svc_b, "org/dev")
	testing.expect(t, found_b)
	testing.expect_value(t, rec_b.agent_session, b)
	testing.expect_value(t, service_count(&reg), 1)
	testing.expect_value(t, register_service(&reg, a, svc_a), RegistryError.SessionNotFound)
}

@(test)
test_unregister_service_unknown_or_wrong_session :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	a := must_add_session(t, &reg, must_principal(t, "host-a", "org/dev"))
	b := must_add_session(t, &reg, must_principal(t, "host-b", "org/dev"))
	svc := must_service_id(t, "game/7QF3P9")
	missing := must_service_id(t, "game/missing")

	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, unregister_service(&reg, a, missing), RegistryError.None)
	testing.expect_value(t, unregister_service(&reg, b, svc), RegistryError.NotOwned)

	rec, ok := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, ok)
	testing.expect_value(t, rec.agent_session, a)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_register_service_unknown_session :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	svc := must_service_id(t, "game/7QF3P9")
	testing.expect_value(t, register_service(&reg, SessionId(1), svc), RegistryError.SessionNotFound)
	testing.expect_value(t, check_register_service(&reg, SessionId(1), svc), RegistryError.SessionNotFound)
	testing.expect_value(t, service_count(&reg), 0)
}

@(test)
test_register_service_invalid_service_id :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	sid := must_add_session(t, &reg, must_principal(t, "host-a", "org/dev"))
	testing.expect_value(t, register_service(&reg, sid, ServiceId("")), RegistryError.InvalidServiceId)
	testing.expect_value(t, register_service(&reg, sid, ServiceId("bad id")), RegistryError.InvalidServiceId)
}

@(test)
test_register_service_quota_exceeded :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	reg.max_registrations_per_session = 1
	sid := must_add_session(t, &reg, must_principal(t, "host-a", "org/dev"))
	first := must_service_id(t, "game/one")
	second := must_service_id(t, "game/two")
	testing.expect_value(t, register_service(&reg, sid, first), RegistryError.None)
	testing.expect_value(t, register_service(&reg, sid, second), RegistryError.QuotaExceeded)
	testing.expect_value(t, service_count(&reg), 1)
	_, ok := lookup_service_for_environment(&reg, "", first, "org/dev")
	testing.expect(t, ok)
}

ConcurrentWorker :: struct {
	reg:         ^Registry,
	session:     SessionId,
	ids:         []ServiceId,
	unexpected:  ^int,
	live:        ^int,
	loops:       int,
}

concurrent_worker_proc :: proc(w: ^ConcurrentWorker) {
	for _ in 0 ..< w.loops {
		for id in w.ids {
			rerr := register_service(w.reg, w.session, id)
			switch rerr {
			case .None:
				sync.atomic_add(w.live, 1)
			case .ServiceAlreadyRegistered:
			case .SessionNotFound, .ServiceNotFound, .NotOwned, .InvalidServiceId, .InvalidPrincipal, .QuotaExceeded, .OutOfMemory:
				sync.atomic_add(w.unexpected, 1)
			}
			lookup_service_for_environment(w.reg, "", id, "org/dev")
			uerr := unregister_service(w.reg, w.session, id)
			switch uerr {
			case .None:
				sync.atomic_sub(w.live, 1)
			case .ServiceNotFound:
			case .SessionNotFound, .NotOwned, .ServiceAlreadyRegistered, .InvalidServiceId, .InvalidPrincipal, .QuotaExceeded, .OutOfMemory:
				sync.atomic_add(w.unexpected, 1)
			}
		}
	}
	for id in w.ids {
		rerr := register_service(w.reg, w.session, id)
		switch rerr {
		case .None:
			sync.atomic_add(w.live, 1)
		case .ServiceAlreadyRegistered:
		case .SessionNotFound, .ServiceNotFound, .NotOwned, .InvalidServiceId, .InvalidPrincipal, .QuotaExceeded, .OutOfMemory:
			sync.atomic_add(w.unexpected, 1)
		}
	}
}

@(test)
test_register_service_concurrent_duplicate_one_winner :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	sid := must_add_session(t, &reg, must_principal(t, "host-a", "org/dev"))
	svc := must_service_id(t, "game/dup")

	WORKER_COUNT :: 8
	wins: int
	unexpected: int
	workers: [WORKER_COUNT]struct {
		reg:         ^Registry,
		session:     SessionId,
		id:          ServiceId,
		wins:        ^int,
		unexpected:  ^int,
	}
	threads: [WORKER_COUNT]^thread.Thread

	dup_proc :: proc(w: ^struct {
		reg:         ^Registry,
		session:     SessionId,
		id:          ServiceId,
		wins:        ^int,
		unexpected:  ^int,
	}) {
		err := register_service(w.reg, w.session, w.id)
		switch err {
		case .None:
			sync.atomic_add(w.wins, 1)
		case .ServiceAlreadyRegistered:
		case .SessionNotFound, .ServiceNotFound, .NotOwned, .InvalidServiceId, .InvalidPrincipal, .QuotaExceeded, .OutOfMemory:
			sync.atomic_add(w.unexpected, 1)
		}
	}

	for i in 0 ..< WORKER_COUNT {
		workers[i] = {reg = &reg, session = sid, id = svc, wins = &wins, unexpected = &unexpected}
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], dup_proc)
		testing.expect(t, threads[i] != nil)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	testing.expect_value(t, unexpected, 0)
	testing.expect_value(t, wins, 1)
	testing.expect_value(t, service_count(&reg), 1)
	_, ok := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, ok)
}

@(test)
test_registry_concurrent_lookup_register_unregister :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	WORKER_COUNT :: 4
	IDS_PER :: 8
	sid := must_add_session(t, &reg, must_principal(t, "host-a", "org/dev"))

	storage: [WORKER_COUNT][IDS_PER][32]u8
	ids: [WORKER_COUNT][IDS_PER]ServiceId
	for w in 0 ..< WORKER_COUNT {
		for i in 0 ..< IDS_PER {
			s := fmt.bprintf(storage[w][i][:], "svc/%d/%d", w, i)
			ids[w][i] = must_service_id(t, s)
		}
	}

	live: int
	unexpected: int
	workers: [WORKER_COUNT]ConcurrentWorker
	threads: [WORKER_COUNT]^thread.Thread
	for w in 0 ..< WORKER_COUNT {
		workers[w] = ConcurrentWorker {
			reg         = &reg,
			session     = sid,
			ids         = ids[w][:],
			unexpected  = &unexpected,
			live        = &live,
			loops       = 32,
		}
		threads[w] = thread.create_and_start_with_poly_data(&workers[w], concurrent_worker_proc)
		testing.expect(t, threads[w] != nil)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	testing.expect_value(t, unexpected, 0)
	testing.expect_value(t, live, WORKER_COUNT * IDS_PER)
	testing.expect_value(t, service_count(&reg), WORKER_COUNT * IDS_PER)
	for w in 0 ..< WORKER_COUNT {
		for i in 0 ..< IDS_PER {
			_, ok := lookup_service_for_environment(&reg, "", ids[w][i], "org/dev")
			testing.expect(t, ok)
		}
	}
}

@(test)
test_same_service_id_two_environments :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	svc := must_service_id(t, "api")
	a := must_add_session_env(t, &reg, must_principal(t, "host-a", "org/dev"), "env-a")
	b := must_add_session_env(t, &reg, must_principal(t, "host-b", "org/dev"), "env-b")
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, b, svc), RegistryError.None)
	testing.expect_value(t, service_count(&reg), 2)

	rec_a, ok_a := lookup_service_for_environment(&reg, "env-a", svc)
	rec_b, ok_b := lookup_service_for_environment(&reg, "env-b", svc)
	testing.expect(t, ok_a)
	testing.expect(t, ok_b)
	testing.expect_value(t, rec_a.agent_session, a)
	testing.expect_value(t, rec_b.agent_session, b)

	_, global := lookup_service(&reg, svc)
	testing.expect(t, !global)
}

@(test)
test_account_service_requires_organization_lookup :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	svc := must_service_id(t, "api")
	legacy := must_add_session(t, &reg, must_principal(t, "host-legacy", "org/dev"))
	other := must_add_session(t, &reg, must_principal(t, "host-other", "org/dev"))
	testing.expect_value(t, register_service(&reg, legacy, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, other, svc), RegistryError.ServiceAlreadyRegistered)

	rec, ok := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, ok)
	testing.expect_value(t, rec.agent_session, legacy)

	_, global_ok := lookup_service(&reg, svc)
	testing.expect(t, !global_ok)
	_, scoped_ok := lookup_service_for_environment(&reg, "env-a", svc, "org/dev")
	testing.expect(t, !scoped_ok)
	_, empty_ok := lookup_service_for_environment(&reg, "", svc)
	testing.expect(t, !empty_ok)
}

@(test)
test_same_environment_duplicate_service_id_refused :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	svc := must_service_id(t, "api")
	a := must_add_session_env(t, &reg, must_principal(t, "host-a", "org/dev"), "env-a")
	a2 := must_add_session_env(t, &reg, must_principal(t, "host-a2", "org/dev"), "env-a")
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.ServiceAlreadyRegistered)
	testing.expect_value(t, register_service(&reg, a2, svc), RegistryError.ServiceAlreadyRegistered)
	testing.expect_value(t, service_count(&reg), 1)
	rec, ok := lookup_service_for_environment(&reg, "env-a", svc)
	testing.expect(t, ok)
	testing.expect_value(t, rec.agent_session, a)
}

@(test)
test_scoped_unregister_and_teardown_stay_in_namespace :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	svc := must_service_id(t, "api")
	global := must_add_session(t, &reg, must_principal(t, "host-global", "org/dev"))
	a := must_add_session_env(t, &reg, must_principal(t, "host-a", "org/dev"), "env-a")
	b := must_add_session_env(t, &reg, must_principal(t, "host-b", "org/dev"), "env-b")
	testing.expect_value(t, register_service(&reg, global, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, b, svc), RegistryError.None)

	testing.expect_value(t, unregister_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, unregister_service(&reg, a, svc), RegistryError.None)
	rec_b, ok_b := lookup_service_for_environment(&reg, "env-b", svc)
	testing.expect(t, ok_b)
	testing.expect_value(t, rec_b.agent_session, b)
	_, ok_fallback := lookup_service_for_environment(&reg, "env-a", svc, "org/dev")
	testing.expect(t, !ok_fallback)

	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, registry_remove_session(&reg, a), RegistryError.None)
	_, again_ok := lookup_service_for_environment(&reg, "env-a", svc, "org/dev")
	testing.expect(t, !again_ok)
	still_b, still_ok := lookup_service_for_environment(&reg, "env-b", svc)
	testing.expect(t, still_ok)
	testing.expect_value(t, still_b.agent_session, b)
	account, account_ok := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, account_ok)
	testing.expect_value(t, account.agent_session, global)
}

@(test)
test_environment_and_account_names_stay_separate :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	svc := must_service_id(t, "api")
	global := must_add_session(t, &reg, must_principal(t, "host-global", "org/dev"))
	a := must_add_session_env(t, &reg, must_principal(t, "host-a", "org/dev"), "env-a")
	testing.expect_value(t, register_service(&reg, global, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)

	scoped, scoped_ok := lookup_service_for_environment(&reg, "env-a", svc)
	testing.expect(t, scoped_ok)
	testing.expect_value(t, scoped.agent_session, a)
	_, other_ok := lookup_service_for_environment(&reg, "env-b", svc, "org/dev")
	testing.expect(t, !other_ok)
	legacy, legacy_ok := lookup_service_for_environment(&reg, "", svc, "org/dev")
	testing.expect(t, legacy_ok)
	testing.expect_value(t, legacy.agent_session, global)
}

@(test)
test_account_names_isolate_unregister_and_session_teardown :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	svc := must_service_id(t, "api")
	a := must_add_session(t, &reg, must_principal(t, "host-a", "org/a"))
	b := must_add_session(t, &reg, must_principal(t, "host-b", "org/b"))
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, check_register_service(&reg, b, svc), RegistryError.None)
	testing.expect_value(t, register_service(&reg, b, svc), RegistryError.None)
	testing.expect_value(t, service_count(&reg), 2)
	rec_a, ok_a := lookup_service_for_environment(&reg, "", svc, "org/a")
	rec_b, ok_b := lookup_service_for_environment(&reg, "", svc, "org/b")
	testing.expect(t, ok_a && ok_b)
	testing.expect_value(t, rec_a.agent_session, a)
	testing.expect_value(t, rec_b.agent_session, b)
	testing.expect_value(t, reg.sessions[a].environment_id, "")
	for key in reg.services {
		testing.expect_value(t, key.environment, "")
		testing.expect(t, len(key.organization) > 0)
	}
	_, anonymous := lookup_service_for_environment(&reg, "", svc)
	testing.expect(t, !anonymous)
	_, other_org := lookup_service_for_environment(&reg, "", svc, "org/other")
	testing.expect(t, !other_org)
	// Even an environment whose text equals an organization is a distinct key.
	_, synthetic := lookup_service_for_environment(&reg, "org/a", svc, "org/b")
	testing.expect(t, !synthetic)
	_, scoped := lookup_service_for_environment(&reg, "env-a", svc, "org/b")
	testing.expect(t, !scoped)

	testing.expect_value(t, unregister_service(&reg, a, svc), RegistryError.None)
	_, gone := lookup_service_for_environment(&reg, "", svc, "org/a")
	testing.expect(t, !gone)
	still_b, still_ok := lookup_service_for_environment(&reg, "", svc, "org/b")
	testing.expect(t, still_ok)
	testing.expect_value(t, still_b.agent_session, b)
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	testing.expect_value(t, registry_remove_session(&reg, a), RegistryError.None)
	_, removed := lookup_service_for_environment(&reg, "", svc, "org/a")
	testing.expect(t, !removed)
	after, after_ok := lookup_service_for_environment(&reg, "", svc, "org/b")
	testing.expect(t, after_ok)
	testing.expect_value(t, after.agent_session, b)
	testing.expect_value(t, service_count(&reg), 1)
}

@(test)
test_leftover_global_fallback_and_scoped_precedence :: proc(t: ^testing.T) {
	reg: Registry
	must_init_registry(t, &reg)
	defer registry_destroy(&reg)

	// Valid sessions always have an organization, so only an explicit fixture
	// inserts a leftover global record. Ordinary registration never creates it.
	owned, err := strings.clone("api", reg.allocator)
	testing.expect(t, err == .None)
	svc := ServiceId(owned)
	reg.services[service_key("", svc)] = ServiceRegistration{id = svc, owner = "leftover"}
	a := must_add_session_env(t, &reg, must_principal(t, "host-a", "org/a"), "env-a")
	testing.expect_value(t, register_service(&reg, a, svc), RegistryError.None)
	scoped, scoped_ok := lookup_service_for_environment(&reg, "env-a", svc, "org/a")
	testing.expect(t, scoped_ok)
	testing.expect_value(t, scoped.agent_session, a)
	global, global_ok := lookup_service(&reg, svc)
	testing.expect(t, global_ok)
	testing.expect_value(t, global.owner, PrincipalId("leftover"))
	environments := [?]string{"", "env-b"}
	for environment in environments {
		fallback, ok := lookup_service_for_environment(&reg, environment, svc, "org/b")
		testing.expect(t, ok)
		testing.expect_value(t, fallback.owner, PrincipalId("leftover"))
	}
}
