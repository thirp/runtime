package broker

import proto "../protocol"
import "core:mem"
import "core:sync"
import "core:time"

ServiceId :: proto.ServiceId

PrincipalId :: distinct string
OrganizationId :: distinct string
SessionId :: distinct u64

INVALID_SESSION_ID :: SessionId(0)

PrincipalCapability :: enum {
	RegisterService,
	ConnectService,
}

PrincipalCapabilities :: bit_set[PrincipalCapability]

PolicyMode :: enum {
	Development,
	Production,
}

Principal :: struct {
	id:           PrincipalId,
	organization: OrganizationId,
	capabilities: PrincipalCapabilities,
}

ServiceRegistration :: struct {
	id:            ServiceId,
	owner:         PrincipalId,
	organization:  OrganizationId,
	agent_session: SessionId,
	registered_at: time.Time,
	last_seen_at:  time.Time,
}

// Map key for one registered name. Without an environment, organization
// selects the account namespace; both empty selects the leftover global one.
// Stored keys own their strings; a probe does not.
ServiceKey :: struct {
	environment:  string,
	organization: OrganizationId,
	service_id:   ServiceId,
}

AgentSession :: struct {
	id:             SessionId,
	principal:      Principal,
	environment_id: string, // empty: account namespace; owned by the registry
	registered_at:  time.Time,
	last_seen_at:   time.Time,
	service_ids:    map[ServiceId]struct{},
}

StreamState :: enum {
	Opening,
	Open,
	CallerHalfClosed,
	AgentHalfClosed,
	Closed,
	Reset,
}

StreamPeer :: enum {
	Caller,
	Agent,
}

StreamEvent :: enum {
	OpenOk,
	OpenFailed,
	Data,
	HalfClose,
	Close,
	Reset,
	Disconnected,
}

// Do not copy a Registry after first use. sync.Mutex is not #no_copy, but
// waiters and the holder must share one lock word; pass ^Registry instead.
Registry :: struct {
	mutex:           sync.Mutex,
	allocator:       mem.Allocator,
	services:                      map[ServiceKey]ServiceRegistration,
	sessions:                      map[SessionId]AgentSession,
	next_session_id:               u64,
	max_registrations_per_session: int,
}
