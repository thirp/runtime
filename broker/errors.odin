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
