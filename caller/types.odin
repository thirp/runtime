package caller

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

CallerError :: enum {
	None,
	InvalidConfig,
	InvalidServiceId,
	Transport,
	AuthFailed,
	ServiceNotFound,
	Unauthorized,
	AgentUnavailable,
	QuotaExceeded,
	BrokerDraining,
	Closed,
	Timeout,
	Internal,
	OutOfMemory,
	RateLimited,
	LocalServiceUnavailable,
}

ConnError :: enum {
	None,
	Closed,
	Reset,
	Transport,
	Timeout,
}

CallerConfig :: struct {
	broker:          net.Endpoint,
	token:           string,
	insecure:        bool,
	tls_ca:          string,
	tls_server_name: string,
	implementation:  string,
	logger:          ^log.Logger,
	dial_timeout:    time.Duration,
}

Conn :: struct {
	mutex:     sync.Mutex,
	cond:      sync.Cond,
	caller:    ^Caller,
	stream_id: proto.StreamId,
	inbound:      [dynamic]u8,
	closed:       bool,
	reset:        bool,
	eof:          bool,
	write_closed: bool,
}

Caller :: struct {
	mutex:        sync.Mutex,
	cond:         sync.Cond,
	config:       CallerConfig,
	conn:         ^trans.Connection,
	decoder:      proto.FrameDecoder,
	streams:      map[proto.StreamId]^Conn,
	pending:      ^Conn,
	pending_err:  CallerError,
	stop:         bool,
	reader:       ^thread.Thread,
	connected:    bool,
}
