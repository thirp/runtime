package transport

// Odin 2026-09 Darwin switched linker spawn from system() to posix_spawnp.
// Combined with `-Wl,-init,'__odin_entry_point'` (quoted; only for
// DynamicLibrary in the compiler), GHA clang/ld can still demand
// `__odin_entry_point` for `odin build` of an EXE. base:runtime only
// defines that symbol when ODIN_BUILD_MODE == .Dynamic.
//
// Weak so a shared-library build still prefers the runtime's strong
// definition when that object is linked.
@(link_name = "_odin_entry_point", linkage = "weak", require)
darwin_odin_entry_point :: proc "c" () {}
