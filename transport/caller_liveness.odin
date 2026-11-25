package transport

import "core:time"

// Receive deadline for the caller watchdog.
CALLER_DEAD_PEER_TIMEOUT :: 45 * time.Second
CALLER_SEND_STALL_TIMEOUT :: 10 * time.Second
