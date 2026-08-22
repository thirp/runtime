package agent

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:sync"

AgentError :: enum {
	None,
	InvalidConfig,
	InvalidServiceId,
	Transport,
	AuthFailed,
	RegisterFailed,
	ServiceAlreadyRegistered,
	QuotaExceeded,
	BrokerDraining,
	Stopped,
	Internal,
	OutOfMemory,
}

HandshakeResult :: enum {
	Ok,
	AuthFailed,
	Unauthorized,
	DuplicateRegistration,
	RegisterFailed,
	Tls,
	Network,
	Transport,
	Stopped,
	Configuration,
	RateLimited,
}

ReconnectClass :: enum {
	None,
	Network,
	BrokerUnavailable,
	Tls,
	Authentication,
	Authorization,
	DuplicateRegistration,
	Configuration,
	Disconnected,
	RateLimited,
}

PendingKind :: enum {
	None,
	Register,
	Unregister,
}

AgentConfig :: struct {
	broker:          net.Endpoint,
	token:           string,
	insecure:        bool,
	tls_ca:          string,
	tls_server_name: string,
	implementation:  string,
	logger:          ^log.Logger,
}

LocalTarget :: struct {
	address: net.Endpoint,
}

EphemeralConfig :: struct {
	namespace:     string,
	local_address: net.Endpoint,
}

Hosting :: struct {
	service_id: proto.ServiceId,
	join_code:  string,
}

AgentService :: struct {
	target: LocalTarget,
	live:   bool,
}

AgentLocalStream :: struct {
	local:              ^trans.Connection,
	broker_half_closed: bool,
	closed:             bool,
}

AgentPumpArg :: struct {
	relay:     ^AgentRelay,
	stream_id: proto.StreamId,
	local:     ^trans.Connection,
}

AgentRelay :: struct {
	mutex:      sync.Mutex,
	agent:      ^Agent,
	broker:     ^trans.Connection,
	streams:    map[proto.StreamId]AgentLocalStream,
	live_pumps: int,
}

ServiceSnapshot :: struct {
	id:     proto.ServiceId,
	target: LocalTarget,
}

Agent :: struct {
	mutex:       sync.Mutex,
	cond:        sync.Cond,
	config:      AgentConfig,
	stop:        bool,
	connected:   bool,
	live_conn:   ^trans.Connection,
	services:    map[proto.ServiceId]AgentService,
	pending:     PendingKind,
	pending_err: AgentError,
}
