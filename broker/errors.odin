package broker

RegistryError :: enum {
	None,
	SessionNotFound,
	ServiceNotFound,
	NotOwned,
	ServiceAlreadyRegistered,
	InvalidServiceId,
	InvalidPrincipal,
	QuotaExceeded,
	OutOfMemory,
}

StreamError :: enum {
	None,
	IllegalEvent,
	NotFound,
	// CLOSE for a stream that is already closed, or already half-closed by
	// the sender. Internal only: not a wire code, and not IllegalEvent,
	// which aborts the stream.
	Ignored,
}

IdentityError :: enum {
	None,
	Empty,
	TooLong,
}

RelayOpenError :: enum {
	None,
	AgentUnavailable,
	QuotaExceeded,
	OutOfMemory,
}

ConnectionSlotResult :: enum {
	Ok,
	PhysicalConnections,
	ConnectionsPerIp,
	GlobalBuffer,
}

OutboxEnqueueError :: enum {
	None,
	Closed,
	StreamLimit,
	ConnectionLimit,
	GlobalLimit,
	OutOfMemory,
}

RoleError :: enum {
	None,
	RoleViolation,
}

PolicyError :: enum {
	None,
	Unauthorized,
	MissingCapability,
	NamespaceDenied,
	QuotaExceeded,
	InvalidPattern,
	InvalidPrincipal,
	OutOfMemory,
}
