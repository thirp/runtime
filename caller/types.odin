package caller

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:mem"
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
	// Bytes received for one stream that its consumer has not read yet.
	// Past it the stream is reset at once (the session reader never waits).
	// 0 = CONN_INBOUND_CAP (8 MiB). Odin only; no C field.
	max_stream_buffer: int,
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
	// The owner holds one reference (conn_destroy drops it); the session
	// reader takes one while it uses the stream, so the owner cannot free
	// it under the reader.
	refs:          int, // atomic
	allocator:     mem.Allocator,
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
