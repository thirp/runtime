package agent

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:sync"
import "core:time"

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
	// No-progress limit for one stream's broker->local writes. 0 =
	// DEFAULT_STREAM_STALL_TIMEOUT; negative = never reset. Odin-only.
	stream_stall_timeout: time.Duration,
	// Odin-only limits (no C field). 0 = default, negative = no limit.
	// max_stream_buffer: one stream's queued DATA to its local service;
	//   a stream that would pass it is RESET (DEFAULT_AGENT_STREAM_BUFFER).
	// max_buffered_bytes: all streams together; the largest is RESET
	//   (DEFAULT_AGENT_BUFFERED_BYTES).
	// max_streams: open streams (two threads each); further OPENs get
	//   OPEN_FAILED QuotaExceeded (DEFAULT_AGENT_MAX_STREAMS).
	max_stream_buffer:  int,
	max_buffered_bytes: int,
	max_streams:        int,
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
	tx:                 ^AgentTx,
	local_eof:          bool, // local service closed its side; HALF_CLOSE sent
	broker_half_closed: bool,
	closed:             bool,
}

AgentPumpArg :: struct {
	relay:     ^AgentRelay,
	stream_id: proto.StreamId,
	local:     ^trans.Connection,
}

// OPEN is dialed off the relay reader so inbound DATA/control for other
// streams is not stalled behind a synchronous local dial.
AgentOpenArg :: struct {
	relay:     ^AgentRelay,
	stream_id: proto.StreamId,
	target:    LocalTarget,
}

AgentRelay :: struct {
	mutex:      sync.Mutex,
	agent:      ^Agent,
	broker:     ^trans.Connection,
	streams:    map[proto.StreamId]AgentLocalStream,
	live_pumps: int,
	opening:    int, // atomic; OPENs accepted but not yet in streams
	queued_bytes: int, // atomic; DATA queued to local services, all streams
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
	// Observability (atomic): agent-wide queued DATA now and its peak.
	buffered_bytes: int,
	buffered_peak:  int,
}
