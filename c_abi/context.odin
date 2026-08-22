package c_abi

import "base:runtime"

// Every exported proc "c" must set context before calling Odin code:
//   context = abi_context()
abi_context :: proc "c" () -> runtime.Context {
	return runtime.default_context()
}
