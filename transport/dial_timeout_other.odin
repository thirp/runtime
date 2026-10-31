#+build !linux
package transport

import "core:net"
import "core:time"

connection_dial_timeout :: proc(
	endpoint: net.Endpoint,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (
	^Connection,
	TransportError,
) {
	return connection_dial(endpoint, allocator)
}
