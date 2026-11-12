# Dependencies

This inventory is the source of truth for the release SBOM (`scripts/sbom.spdx.json.in`, emitted by `scripts/release.sh`).

## Odin (build-time)

- **What:** [Odin](https://odin-lang.org/) compiler and its `core:` library
- **Used for:** compiling the broker, agent, caller, Web Ingress, and shared libraries
- **License:** BSD-3-Clause (compiler). Not linked into release binaries.
- **Minimum:** `dev-2026-07` (known-good commit `7c2b219`). Later monthly releases are accepted until something breaks; then raise this floor.
- **Provenance:** the compiler that cut a release is recorded in `PROVENANCE.txt` (`odin version`)

## OpenSSL 3

### Linux

- **What:** system `libssl` and `libcrypto`
- **Used for:** TLS 1.2+ under `transport` (`SSL_accept` / `SSL_connect` / `SSL_read` / `SSL_write`)
- **License:** Apache-2.0
- **Install:** distro package (Fedora: `openssl` / `openssl-devel`, Ubuntu: `libssl-dev`)
- **Provenance:** distro OpenSSL 3. Linked at build time via Odin `foreign import "system:ssl"` and `"system:crypto"`. Not vendored.
- **Build:** `pkg-config --libs openssl` should report `-lssl -lcrypto`

### macOS

- **What:** Homebrew `openssl@3`
- **Used for:** same TLS operations as Linux
- **License:** Apache-2.0
- **Install:** `brew install openssl@3`
- **Build:** requires `-extra-linker-flags:"-L$(brew --prefix openssl@3)/lib"` so the linker finds OpenSSL 3 instead of Apple's LibreSSL
- **CA verification:** `SSL_CTX_set_default_verify_paths` first; falls back to `/etc/ssl/cert.pem` if default paths fail

### Windows

- **What:** OpenSSL 3 for Windows
- **Used for:** same TLS operations as Linux
- **License:** Apache-2.0
- **Install for builds:** OpenSSL 3 Windows binaries from a provider listed at [wiki.openssl.org](https://wiki.openssl.org/index.php/Binaries) or via package manager. Windows release CI installs OpenSSL 3.5.9 from the Win64 OpenSSL installer at a pinned SHA-256; an unpinned Chocolatey `openssl` install now selects OpenSSL 4, which is the wrong ABI.
- **Link:** `foreign import "system:libssl.lib"` and `"system:libcrypto.lib"` (MSVC needs the `.lib` suffix; without it the linker looks for `libssl.obj`). `scripts/build_windows.bat` adds the directory containing `libssl.lib` to `LIB` (`OPENSSL_ROOT_DIR`, then `C:\Program Files\OpenSSL`, then `C:\Program Files\OpenSSL-Win64`; including `lib\VC\x64\MD`). The default roots are considered only when they contain `bin\openssl.exe`.
- **Distribution:** the Windows data-plane zip vendors `libssl-3-x64.dll` and `libcrypto-3-x64.dll` beside the executables. `scripts/release_windows.ps1` copies both from the selected build tree's `bin\`, includes them in `SHA256SUMS`, and records that tree's `openssl version` in `PROVENANCE.txt`. Missing OpenSSL 3 DLLs fail the release; OpenSSL 4 DLLs are not substitutes. A released zip needs no system OpenSSL or OpenSSL DLLs on `PATH` at runtime.
- **Signing:** OpenSSL DLLs are preserved as supplied by the OpenSSL build; they are not signed with `THIRP_WINDOWS_PFX`.
- **CA verification:** Windows ROOT certificate store via `CertOpenSystemStoreW` / `d2i_X509` / `X509_STORE_add_cert` (`crypt32.lib`, a Windows system library)

## Platform-specific system libraries

### Linux

- POSIX poll, sigwait, pthread for signal handling and socket I/O

### macOS

- POSIX poll, sigwait, pthread (same as Linux)

### Windows

- `ws2_32.lib` (`WSAPoll` for TLS socket wait; `recv`/`MSG_PEEK` for TCP peek)
- `crypt32.lib` (Windows ROOT certificate store)
- SetConsoleCtrlHandler for Ctrl-C handling (no SIGTERM on Windows)

## Summary

`libthirp.so`, `libthirp.dylib`, and `libthirp.dll` dynamically link OpenSSL 3 through `transport`. Linux uses distro OpenSSL and macOS uses Homebrew OpenSSL; neither archive vendors it. The Windows data-plane zip carries the two OpenSSL 3 DLLs used at build time. Standalone SDK consumers must still supply OpenSSL 3 for their target.
