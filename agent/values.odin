package agent

import "core:time"

DEFAULT_IMPLEMENTATION :: "thirp-agent"
// One Warn line when a local dial fails. Carries the target, the error
// class, and the stream id. Never a payload, argument, or token.
LOG_EVENT_LOCAL_DIAL_FAILED :: "local_dial_failed"
// TransportError class names on that line. One string each; call sites use the name.
ERROR_CLASS_NONE :: "none"
ERROR_CLASS_CLOSED :: "closed"
ERROR_CLASS_TIMEOUT :: "timeout"
ERROR_CLASS_WOULD_BLOCK :: "would_block"
ERROR_CLASS_INVALID_ENDPOINT :: "invalid_endpoint"
ERROR_CLASS_OUT_OF_MEMORY :: "out_of_memory"
ERROR_CLASS_NETWORK :: "network"
ERROR_CLASS_TLS :: "tls"
// RATE_LIMITED on REGISTER or AUTHENTICATE. Not an auth failure.
LOG_EVENT_RATE_LIMITED :: "rate_limited"
// One line per service that is live on the broker session.
LOG_EVENT_REGISTERED :: "registered"
HEARTBEAT_INTERVAL :: 15 * time.Second
// No inbound frame for three heartbeat intervals. Our own Ping does not
// count: the broker must send a frame (including Ping or Pong).
READ_IDLE_TIMEOUT :: 45 * time.Second
LOG_REASON_IDLE :: "idle"
LOCAL_READ_BUF :: 16 * 1024
// Default no-progress limit for one stream (see AgentConfig).
DEFAULT_STREAM_STALL_TIMEOUT :: 30 * time.Second
// Default limits (AgentConfig). Without per-stream flow control in
// protocol 1.0, a stream whose backlog to a slow local service passes its
// buffer is reset: the shared relay reader never waits on one stream.
DEFAULT_AGENT_STREAM_BUFFER :: 64 * 1024 * 1024
DEFAULT_AGENT_BUFFERED_BYTES :: 256 * 1024 * 1024
DEFAULT_AGENT_MAX_STREAMS :: 128
// Local dial ceiling. Must stay under a caller's dial timeout (the ingress
// default is 10s) so an unreachable backend returns OPEN_FAILED instead of
// holding the caller's one pending slot until that dial gives up.
// 0 in AgentConfig means this. Negative means no ceiling.
DEFAULT_LOCAL_DIAL_TIMEOUT :: 5 * time.Second

RECONNECT_BASE :: 250 * time.Millisecond
RECONNECT_MAX :: 15 * time.Second
// Added to the RATE_LIMITED attempt so the first wait is reconnect_delay(2):
// 0.5–1s, then doubled, capped at RECONNECT_MAX.
REGISTER_RATE_BACKOFF_ATTEMPT :: 2

JOIN_CODE_ALPHABET :: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
JOIN_CODE_LEN :: 8
JOIN_CODE_RETRY_CAP :: 8
