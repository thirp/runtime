package caller

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

// Test-only fields. An empty struct in production builds, so the caller
// binary does not carry them.
when ODIN_TEST {
	Caller_Test_Config :: struct {
		// 0 = the production constants. Tests shorten the idle watchdog
		// and the caller Ping so a suite does not sleep for minutes.
		read_idle_timeout: time.Duration,
		ping_interval:     time.Duration,
	}
	Caller_Test_State :: struct {
		// Last reason the reader logged for a drop. Not cleared on
		// reconnect. Production builds do not keep it.
		last_disconnect_reason: string,
	}
} else {
	Caller_Test_Config :: struct {}
	Caller_Test_State :: struct {}
}

// A broker session that no longer takes new dials. Live streams stay on it
// until they end. The tombstone, if it is still set, is answered here
// (RESET on this socket) and does not bind a dial on the replacement.
CallerDrain :: struct {
	caller:     ^Caller,
	conn:       ^trans.Connection,
	gen:        int,
	decoder:    proto.FrameDecoder,
	streams:    map[proto.StreamId]^Conn,
	tombstone:  bool,
	last_recv:  time.Time,
	last_ping:  time.Time,
	stop:       bool,
	closed:     bool,
}

SessionRead :: enum {
	Continue,
	Stopped,
	Dropped,
	Retired,
}

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
	// 0 waits until CONNECT_OK or the session ends. thirp-connect passes
	// DEFAULT_DIAL_TIMEOUT. Left 0 for the C SDK on purpose: there is no
	// field on ThirpCallerConfig, and inventing a 10s bound there would
	// fail dials that are slow but still moving. A stuck socket is still
	// closed by send_stall_timeout.
	dial_timeout:    time.Duration,
	// 0 = DEFAULT_SEND_STALL_TIMEOUT. Negative = never close for a stall.
	// Closes the session only when a send is outstanding and the socket
	// acknowledges no new bytes for this long.
	send_stall_timeout: time.Duration,
	// Bytes received for one stream that its consumer has not read yet.
	// Past it the stream is reset at once (the session reader never waits).
	// 0 = CONN_INBOUND_CAP (8 MiB). Odin only; no C field.
	max_stream_buffer: int,
	using test_config: Caller_Test_Config,
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
	// Set when CONNECT_OK binds this stream. A dial whose slot was cleared
	// and then reused must not treat pending_err == None as success.
	accepted:     bool,
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
	// Bumps on every conn swap, including nil. A write that snapshotted the
	// previous socket must not treat a reused pointer as the new session.
	conn_gen:     int,
	decoder:      proto.FrameDecoder,
	streams:      map[proto.StreamId]^Conn,
	pending:      ^Conn,
	pending_err:  CallerError,
	// A CONNECT already left and its dial gave up. The slot stays taken
	// until that CONNECT_OK (RESET, not bound), CONNECT_FAILED, or the
	// session drops. A later dial waits behind it, on its own deadline.
	pending_tombstone:  bool,
	tombstone_capped:   bool,
	tombstone_deadline: time.Time,
	// Last frame from the broker. The read loop drops the session when this
	// is older than READ_IDLE_TIMEOUT. Poll timeouts and our own Ping do
	// not move it.
	last_recv: time.Time,
	// When the caller last sent Ping. Zero means it has not.
	last_ping: time.Time,
	// Bumps on every frame. A dial compares this to the value from before
	// its CONNECT to see whether the broker has said anything since.
	recv_gen:  int,
	// Sessions retired for new dials. Their streams keep running here.
	drains:     [dynamic]^CallerDrain,
	drain_live: int,
	stop:         bool,
	reader:       ^thread.Thread,
	connected:    bool,
	// One writer drains control frames ahead of DATA. The stall thread is
	// the only timer; dials do not start a thread and do not poll.
	write_mu:        sync.Mutex,
	write_cond:      sync.Cond,
	control_q:       [dynamic]^WriteJob,
	data_q:          [dynamic]^WriteJob,
	writing:         bool,
	write_inflight:  bool,
	// Socket the in-flight job is writing. The stall timer shuts this one
	// down, which may be a retired drain rather than the live session.
	write_conn:      ^trans.Connection,
	write_waiters:   int,
	queues_closed:   bool,
	user_send_bytes: int,
	stall_stop:      bool,
	stall_thread:    ^thread.Thread,
	// Streams finished by the last caller_fail_all. The reader logs it once.
	dropped_streams: int,
	// Set before the socket is closed when the cause is known (the stall
	// timer). The reader fills it from the read error otherwise, then logs
	// it and clears it. Empty means not yet classified.
	disconnect_reason: string,
	using test_state: Caller_Test_State,
}
