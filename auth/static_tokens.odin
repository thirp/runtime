package auth

import "core:crypto"
import crypto_hash "core:crypto/hash"
import "core:strings"
import "core:time"

DEFAULT_ORGANIZATION :: "org/dev"

auth_init :: proc(auth: ^StaticTokenAuth, allocator := context.allocator) -> AuthError {
	auth^ = {}
	auth.allocator = allocator
	auth.records = make([dynamic]TokenRecord, allocator)
	org, oerr := strings.clone(DEFAULT_ORGANIZATION, allocator)
	if oerr != .None {
		delete(auth.records)
		auth^ = {}
		return .OutOfMemory
	}
	auth.default_org = org
	return .None
}

auth_destroy :: proc(auth: ^StaticTokenAuth) {
	if auth == nil {
		return
	}
	for rec in auth.records {
		delete(rec.id, auth.allocator)
		delete(rec.organization, auth.allocator)
		delete(rec.label, auth.allocator)
	}
	delete(auth.records)
	delete(auth.default_org, auth.allocator)
	auth^ = {}
}

token_digest :: proc(token: []u8) -> [TOKEN_DIGEST_SIZE]u8 {
	digest: [TOKEN_DIGEST_SIZE]u8
	crypto_hash.hash_bytes_to_buffer(.SHA256, token, digest[:])
	return digest
}

auth_find_digest :: proc(auth: ^StaticTokenAuth, digest: []u8) -> (index: int, found: bool) {
	matched := false
	matched_index := -1
	for i in 0 ..< len(auth.records) {
		rec := &auth.records[i]
		if crypto.compare_constant_time(digest, rec.digest[:]) == 1 {
			matched = true
			matched_index = i
		}
	}
	return matched_index, matched
}

auth_add_token :: proc(auth: ^StaticTokenAuth, token: string, principal_id: string, organization := "") -> AuthError {
	return auth_add_credential(
		auth,
		CredentialSpec{token = token, principal_id = principal_id, organization = organization},
	)
}

auth_add_credential :: proc(auth: ^StaticTokenAuth, spec: CredentialSpec) -> AuthError {
	if auth == nil {
		return .InvalidToken
	}
	if len(spec.token) == 0 || len(spec.token) > MAX_TOKEN_LEN {
		return .InvalidToken
	}
	if len(spec.principal_id) == 0 || len(spec.principal_id) > MAX_PRINCIPAL_LEN {
		return .InvalidPrincipal
	}
	org := spec.organization
	if len(org) == 0 {
		org = auth.default_org
	}
	if len(org) == 0 || len(org) > MAX_PRINCIPAL_LEN {
		return .InvalidPrincipal
	}
	if !check_label(spec.label) {
		return .InvalidPrincipal
	}
	digest := token_digest(transmute([]u8)spec.token)
	_, exists := auth_find_digest(auth, digest[:])
	if exists {
		crypto.zero_explicit(raw_data(digest[:]), TOKEN_DIGEST_SIZE)
		return .InvalidToken
	}

	id, ierr := strings.clone(spec.principal_id, auth.allocator)
	if ierr != .None {
		crypto.zero_explicit(raw_data(digest[:]), TOKEN_DIGEST_SIZE)
		return .OutOfMemory
	}
	org_owned, oerr := strings.clone(org, auth.allocator)
	if oerr != .None {
		delete(id, auth.allocator)
		crypto.zero_explicit(raw_data(digest[:]), TOKEN_DIGEST_SIZE)
		return .OutOfMemory
	}
	label_owned: string
	if len(spec.label) > 0 {
		cloned, lerr := strings.clone(spec.label, auth.allocator)
		if lerr != .None {
			delete(id, auth.allocator)
			delete(org_owned, auth.allocator)
			crypto.zero_explicit(raw_data(digest[:]), TOKEN_DIGEST_SIZE)
			return .OutOfMemory
		}
		label_owned = cloned
	}
	_, aerr := append(
		&auth.records,
		TokenRecord {
			digest       = digest,
			id           = id,
			organization = org_owned,
			capabilities = spec.capabilities,
			label        = label_owned,
			expires_at   = spec.expires_at,
		},
	)
	if aerr != .None {
		delete(id, auth.allocator)
		delete(org_owned, auth.allocator)
		delete(label_owned, auth.allocator)
		crypto.zero_explicit(raw_data(digest[:]), TOKEN_DIGEST_SIZE)
		return .OutOfMemory
	}
	crypto.zero_explicit(raw_data(digest[:]), TOKEN_DIGEST_SIZE)
	return .None
}

// authenticate_token looks up an opaque token. Returned strings are owned by
// auth and remain valid until the token is removed or auth is destroyed.
authenticate_token :: proc(auth: ^StaticTokenAuth, token: []u8) -> (result: AuthResult, err: AuthError) {
	if auth == nil || len(token) == 0 {
		return {}, .InvalidToken
	}
	digest := token_digest(token)
	index, found := auth_find_digest(auth, digest[:])
	crypto.zero_explicit(raw_data(digest[:]), TOKEN_DIGEST_SIZE)
	if !found {
		return {}, .InvalidToken
	}
	rec := auth.records[index]
	if rec.expires_at != {} && time.since(rec.expires_at) >= 0 {
		return {}, .Expired
	}
	return AuthResult {
			id           = rec.id,
			organization = rec.organization,
			capabilities = rec.capabilities,
			label        = rec.label,
			expires_at   = rec.expires_at,
		},
		.None
}
