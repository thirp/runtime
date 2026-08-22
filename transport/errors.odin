package transport

TransportError :: enum {
	None,
	Closed,
	Timeout,
	WouldBlock,
	InvalidEndpoint,
	OutOfMemory,
	Network,
	Tls,
}
