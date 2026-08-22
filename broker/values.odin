package broker

import "core:time"

MAX_IDENTITY_LEN :: 128
DEFAULT_MAX_REGISTRATIONS_PER_SESSION :: 32
DEFAULT_MAX_STREAM_BUFFER :: 256 * 1024
DEFAULT_MAX_CONNECTION_BUFFER :: 8 * 1024 * 1024
DEFAULT_MAX_STREAMS_PER_SESSION :: 256
DEFAULT_MAX_PHYSICAL_CONNECTIONS :: 4096
DEFAULT_MAX_CONNECTIONS_PER_IP :: 256
DEFAULT_AUTH_RATE_LIMIT :: 20
DEFAULT_REGISTER_RATE_LIMIT :: 60
DEFAULT_CONNECT_RATE_LIMIT :: 600
DEFAULT_MAX_BUFFERED_BYTES :: 256 * 1024 * 1024
DEFAULT_STREAM_IDLE_TIMEOUT :: 0
DEFAULT_RATE_LIMIT_WINDOW :: 60 * time.Second
READYZ_READY :: "ready"
READYZ_NOT_READY :: "not_ready"
READYZ_DRAINING :: "draining"

check_identity_string :: proc(value: string) -> IdentityError {
	if len(value) == 0 {
		return .Empty
	}
	if len(value) > MAX_IDENTITY_LEN {
		return .TooLong
	}
	return .None
}

make_principal_id :: proc(value: string) -> (PrincipalId, IdentityError) {
	if err := check_identity_string(value); err != .None {
		return {}, err
	}
	return PrincipalId(value), .None
}

make_organization_id :: proc(value: string) -> (OrganizationId, IdentityError) {
	if err := check_identity_string(value); err != .None {
		return {}, err
	}
	return OrganizationId(value), .None
}

make_principal :: proc(id: string, organization: string) -> (Principal, IdentityError) {
	pid, err := make_principal_id(id)
	if err != .None {
		return {}, err
	}
	oid: OrganizationId
	oid, err = make_organization_id(organization)
	if err != .None {
		return {}, err
	}
	return Principal{id = pid, organization = oid}, .None
}
