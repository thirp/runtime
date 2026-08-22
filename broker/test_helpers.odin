package broker

import proto "../protocol"
import "core:fmt"
import "core:testing"

must_service_id :: proc(t: ^testing.T, value: string, loc := #caller_location) -> ServiceId {
	id, err := proto.make_service_id(value)
	testing.expect_value(t, err, proto.ServiceIdError.None, loc)
	return id
}

must_principal :: proc(t: ^testing.T, id: string, org: string, loc := #caller_location) -> Principal {
	p, err := make_principal(id, org)
	testing.expect_value(t, err, IdentityError.None, loc)
	return p
}

must_init_registry :: proc(t: ^testing.T, reg: ^Registry, loc := #caller_location) {
	err := registry_init(reg)
	testing.expect_value(t, err, RegistryError.None, loc)
}

must_add_session :: proc(t: ^testing.T, reg: ^Registry, principal: Principal, loc := #caller_location) -> SessionId {
	sid, err := registry_add_session(reg, principal)
	testing.expect_value(t, err, RegistryError.None, loc)
	testing.expect(t, sid != INVALID_SESSION_ID, loc = loc)
	return sid
}

json_event :: proc(event: string) -> string {
	return fmt.tprintf("\"event\":\"%s\"", event)
}

json_reason :: proc(reason: string) -> string {
	return fmt.tprintf("\"reason\":\"%s\"", reason)
}
