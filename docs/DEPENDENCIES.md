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
- **Install:** official Windows binaries from [wiki.openssl.org](https://wiki.openssl.org/index.php/Binaries) or via package manager (vcpkg, Chocolatey)
- **Link:** `foreign import "system:libssl"` and `"system:libcrypto"` (note the `lib` prefix on Windows)
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

`libthirp.so`, `libthirp.dylib`, and `libthirp.dll` link the system OpenSSL 3 through `transport`. No extra third-party library is added for the shared object.
