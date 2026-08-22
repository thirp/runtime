package auth

AuthError :: enum {
	None,
	InvalidToken,
	InvalidPrincipal,
	OutOfMemory,
	Expired,
}
