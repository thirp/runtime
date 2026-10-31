package caller

import "core:time"

DEFAULT_IMPLEMENTATION :: "thirp-connect"
LOCAL_READ_BUF :: 16 * 1024
// Default per-stream inbound buffer (CallerConfig.max_stream_buffer). The
// session reader appends to it without waiting, so one slow consumer does
// not hold up the other streams. There is no per-stream flow control in the
// protocol: a stream whose backlog would pass the cap is reset at once.
CONN_INBOUND_CAP :: 8 * 1024 * 1024
CALLER_POLL_INTERVAL :: 50 * time.Millisecond
// Default no-progress limit for thirp-connect's writes to a local client
// (--stream-stall-timeout). The session reader itself never waits.
DEFAULT_STREAM_STALL_TIMEOUT :: 30 * time.Second
// thirp-connect fails a dial that has not finished in this time. It does not
// by itself close the session: a slow upload that is still sending stays up.
// 0 in CallerConfig waits until CONNECT_OK or the session ends. The CLI sets
// this. The C SDK does not: ThirpCallerConfig has no dial field, and a hidden
// 10s would fail dials an embedder expects to block until the broker answers.
// Same bound as the web ingress.
DEFAULT_DIAL_TIMEOUT :: 10 * time.Second
// No bytes acknowledged on the session socket for this long, while a send is
// outstanding, closes the socket so the reader reconnects. 0 in CallerConfig
// means this default. Negative disables it. Progress is peer ACKs, not the
// wall clock since a CONNECT was queued.
DEFAULT_SEND_STALL_TIMEOUT :: 10 * time.Second

RECONNECT_BASE :: 250 * time.Millisecond
RECONNECT_MAX :: 15 * time.Second

// Log event and reason names. Call sites use these, not the string literals.
LOG_EVENT_STREAM_RESET :: "stream_reset"
LOG_REASON_STREAM_BUFFER_FULL :: "stream_buffer_full"
LOG_REASON_PEER :: "peer"
LOG_EVENT_CONNECT_TIMEOUT :: "connect_timeout"
LOG_REASON_DIAL_TIMEOUT :: "dial_timeout"
// The dial's session was already gone. Not the dial's own clock.
LOG_REASON_SESSION_LOST :: "session_lost"
LOG_EVENT_DISCONNECTED :: "disconnected"
// Why the session socket closed. The reader logs exactly one of these.
LOG_REASON_STALL :: "stall"
LOG_REASON_PEER_CLOSE :: "peer_close"
LOG_REASON_ERROR :: "error"
// A CONNECT that already left, whose dial gave up, kept the pending slot
// this long past the dial timeout. The reply is not coming. The wait is
// at least TOMBSTONE_CAP_FLOOR so it outlives the agent local dial.
LOG_REASON_TOMBSTONE :: "tombstone"
TOMBSTONE_DIAL_TIMEOUTS :: 2
// agent.DEFAULT_LOCAL_DIAL_TIMEOUT (5s) plus a margin. A shorter cap
// retires the session before OPEN_FAILED arrives.
TOMBSTONE_CAP_FLOOR :: 7 * time.Second
// Ingress and thirp-connect log once at startup when dial_timeout is
// below this. The cap floor is what actually keeps the session up.
DIAL_TIMEOUT_WARN_BELOW :: 6 * time.Second
LOG_EVENT_DIAL_TIMEOUT_SHORT :: "dial_timeout_short"
// After this long with no frame, the caller sends Ping. The broker
// answers. Deployed brokers heartbeat every 15s; a slower one must not
// look idle. On Linux an unacked Ping is aborted by TCP_USER_TIMEOUT
// and logged dead_peer. READ_IDLE_TIMEOUT is the fallback when the
// kernel does not abort (a proxy that still ACKs, or a non-Linux host).
CALLER_PING_INTERVAL :: 15 * time.Second
// Nothing arrived from the broker for this long. Our own Ping does not
// count. Three missed broker intervals, or a Ping with no Pong.
READ_IDLE_TIMEOUT :: 45 * time.Second
LOG_REASON_IDLE :: "idle"
// A dial timed out and the broker socket was retransmitting with nothing
// read back since the CONNECT was sent.
LOG_REASON_DEAD_PEER :: "dead_peer"
DEAD_PEER_MIN_WAIT :: 1 * time.Second
LOG_EVENT_SESSION_RETIRED :: "session_retired"
// Oldest retired session dropped because this caller already had
// MAX_RETIRED_SESSIONS parked. Its streams end.
MAX_RETIRED_SESSIONS :: 2
LOG_EVENT_DRAIN_DROPPED :: "drain_dropped"
LOG_REASON_RETIRED_LIMIT :: "retired_limit"
// Unacknowledged transmits on the broker socket are aborted after this.
// On Linux that abort is ETIMEDOUT and the caller logs dead_peer. Longer
// than DEFAULT_SEND_STALL_TIMEOUT so the stall timer still owns a stuck
// write the kernel has not given up on.
TCP_USER_TIMEOUT :: 20 * time.Second
