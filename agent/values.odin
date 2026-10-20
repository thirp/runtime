package agent

import "core:time"

DEFAULT_IMPLEMENTATION :: "thirp-agent"
HEARTBEAT_INTERVAL :: 15 * time.Second
LOCAL_READ_BUF :: 16 * 1024
// Default no-progress limit for one stream (see AgentConfig).
DEFAULT_STREAM_STALL_TIMEOUT :: 30 * time.Second
// Default limits (AgentConfig). Without per-stream flow control in
// protocol 1.0, a stream whose backlog to a slow local service passes its
// buffer is reset: the shared relay reader never waits on one stream.
DEFAULT_AGENT_STREAM_BUFFER :: 64 * 1024 * 1024
DEFAULT_AGENT_BUFFERED_BYTES :: 256 * 1024 * 1024
DEFAULT_AGENT_MAX_STREAMS :: 128

RECONNECT_BASE :: 250 * time.Millisecond
RECONNECT_MAX :: 15 * time.Second

JOIN_CODE_ALPHABET :: "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
JOIN_CODE_LEN :: 8
JOIN_CODE_RETRY_CAP :: 8
