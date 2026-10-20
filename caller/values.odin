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

RECONNECT_BASE :: 250 * time.Millisecond
RECONNECT_MAX :: 15 * time.Second
