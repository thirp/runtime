package auth

static_token_authenticator :: proc(store: ^StaticTokenAuth) -> Authenticator {
	return Authenticator {
		ctx          = store,
		authenticate = authenticate_static,
	}
}

authenticate_static :: proc(ctx: rawptr, token: []u8) -> (AuthResult, AuthError) {
	return authenticate_token((^StaticTokenAuth)(ctx), token)
}

authenticate :: proc(a: Authenticator, token: []u8) -> (AuthResult, AuthError) {
	if a.authenticate == nil {
		return {}, .InvalidToken
	}
	return a.authenticate(a.ctx, token)
}
