# Dependencies

This inventory is the source of truth for the release SBOM (`scripts/sbom.spdx.json.in`, emitted by `scripts/release.sh`).

## Odin (build-time)

- **What:** [Odin](https://odin-lang.org/) compiler and its `core:` library
- **Used for:** compiling the broker, agent, caller, Web Ingress, and `libthirp.so`
- **License:** BSD-3-Clause (compiler). Not linked into release binaries.
- **Minimum:** `dev-2026-07` (known-good commit `7c2b219`). Later monthly releases are accepted until something breaks; then raise this floor.
- **Provenance:** the compiler that cut a release is recorded in `PROVENANCE.txt` (`odin version`)

## OpenSSL 3

- **What:** system `libssl` and `libcrypto`
- **Used for:** TLS 1.2+ under `transport` (`SSL_accept` / `SSL_connect` / `SSL_read` / `SSL_write`)
- **License:** Apache-2.0
- **Provenance:** distro OpenSSL 3 (Fedora: `openssl` / `openssl-devel`). Linked at build time via Odin `foreign import "system:ssl"` and `"system:crypto"`. Not vendored.
- **Build:** `pkg-config --libs openssl` should report `-lssl -lcrypto`

`libthirp.so` (C ABI) links the same system `libssl` / `libcrypto` through `transport`. No extra third-party library is added for the shared object.

No other third-party libraries are linked. Protocol, registry, and relay code do not call OpenSSL. The SPDX document lists `thirp-runtime` (Apache-2.0) and `OpenSSL` (Apache-2.0) only.
