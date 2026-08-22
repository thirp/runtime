package auth

import "core:mem"
import "core:time"

MAX_TOKEN_LEN :: 4096
MAX_PRINCIPAL_LEN :: 128
TOKEN_DIGEST_SIZE :: 32
MAX_CREDENTIAL_FILE_LEN :: 1024 * 1024
MAX_SECRET_FILE_LEN :: MAX_TOKEN_LEN + 64

TokenCapability :: enum {
	RegisterService,
	ConnectService,
}

TokenCapabilities :: bit_set[TokenCapability]

TokenRecord :: struct {
	digest:       [TOKEN_DIGEST_SIZE]u8,
	id:           string,
	organization: string,
	capabilities: TokenCapabilities,
	label:        string,
	expires_at:   time.Time,
}

CredentialSpec :: struct {
	token:        string,
	principal_id: string,
	organization: string,
	capabilities: TokenCapabilities,
	label:        string,
	expires_at:   time.Time,
}

AuthResult :: struct {
	id:             string,
	organization:   string,
	capabilities:   TokenCapabilities,
	label:          string,
	expires_at:     time.Time,
	credential_id:  string, // optional; empty in local mode
	environment_id: string, // optional; empty in local mode
	principal_kind: string, // optional; empty in local mode
	policy_version: i64,    // optional; 0 in local mode
}

Authenticator :: struct {
	ctx:          rawptr, // Odin reserves `context`
	authenticate: proc(ctx: rawptr, token: []u8) -> (AuthResult, AuthError),
}

StaticTokenAuth :: struct {
	allocator:   mem.Allocator,
	records:     [dynamic]TokenRecord,
	default_org: string,
}
