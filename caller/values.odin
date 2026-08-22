package caller

import "core:time"

DEFAULT_IMPLEMENTATION :: "thirp-connect"
LOCAL_READ_BUF :: 16 * 1024
CONN_INBOUND_CAP :: 256 * 1024
CALLER_POLL_INTERVAL :: 50 * time.Millisecond

RECONNECT_BASE :: 250 * time.Millisecond
RECONNECT_MAX :: 15 * time.Second
