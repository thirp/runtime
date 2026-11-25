package transport

import "core:time"

// Shared by the caller watchdog and the broker's caller overflow protection.
CALLER_DEAD_PEER_TIMEOUT :: 7 * time.Second
CALLER_SEND_STALL_TIMEOUT :: 10 * time.Second
