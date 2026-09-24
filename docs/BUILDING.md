# Building, testing, and packaging

This document covers source builds and the release pipeline. If you only want to
see Runtime relay a service, begin with the [local TLS quickstart](QUICKSTART.md).

## Supported build environments

### Linux (full release artifacts)

The Linux release tooling produces the complete operator artifact set
(checksums always; GPG detached signature when the publish key is available) and
requires:

- [Odin](https://odin-lang.org/) `dev-2026-07` or later
- OpenSSL 3 development files (`libssl` and `libcrypto`)
- a C compiler for the C ABI smoke test
- standard Unix release tools used by `scripts/release.sh`

The release script records the exact Odin and OpenSSL versions in generated
provenance. See [DEPENDENCIES.md](DEPENDENCIES.md) for the dependency inventory.

### macOS

macOS builds are supported for CLIs and `libthirp.dylib`. Requirements:

- [Odin](https://odin-lang.org/) `dev-2026-07` or later
- OpenSSL 3 via Homebrew: `brew install openssl@3`
- Xcode Command Line Tools

### Windows

Windows builds are supported for CLIs and `libthirp.dll`. Requirements:

- [Odin](https://odin-lang.org/) `dev-2026-07` or later
- OpenSSL 3 for Windows ([download](https://wiki.openssl.org/index.php/Binaries))
- Visual Studio Build Tools or MSVC

## Build command-line components

### Linux

Run from the repository root:

```bash
odin build broker_cli -out:thirp-broker
odin build agent_cli -out:thirp-agent
odin build caller_cli -out:thirp-connect
odin build web_ingress_cli -out:thirp-web-ingress
```

Local test fixtures:

```bash
odin build echo_cli -out:thirp-echo
odin build echo_http_cli -out:thirp-echo-http
```

The installed command names are deliberately distinct from their source
directories.

### macOS

```bash
# Ensure OpenSSL 3 is installed
brew install openssl@3

# Build with linker flags pointing to Homebrew OpenSSL
OPENSSL_LIB="$(brew --prefix openssl@3)/lib"
odin build broker_cli -out:thirp-broker -extra-linker-flags:"-L${OPENSSL_LIB}"
odin build agent_cli -out:thirp-agent -extra-linker-flags:"-L${OPENSSL_LIB}"
odin build caller_cli -out:thirp-connect -extra-linker-flags:"-L${OPENSSL_LIB}"
odin build web_ingress_cli -out:thirp-web-ingress -extra-linker-flags:"-L${OPENSSL_LIB}"
```

Or use the convenience script:

```bash
scripts/build_macos.sh
```

### Windows

```cmd
REM Ensure OpenSSL 3 is installed and in PATH
odin build broker_cli -out:thirp-broker.exe
odin build agent_cli -out:thirp-agent.exe
odin build caller_cli -out:thirp-connect.exe
odin build web_ingress_cli -out:thirp-web-ingress.exe
```

Or use the convenience script:

```cmd
scripts\build_windows.bat
```

`build_windows.bat` finds `libssl.lib` under `OPENSSL_ROOT_DIR` (or `C:\Program Files\OpenSSL`, then `OpenSSL-Win64`) and prepends that directory to `LIB`. Chocolatey OpenSSL 4 installs at `C:\Program Files\OpenSSL`.

## Build the C ABI

### Linux

```bash
odin build c_abi -build-mode:shared -out:libthirp.so
cc -o thirp-c-smoke c_abi/smoke.c -I c_abi -L. -lthirp -Wl,-rpath,$PWD
```

`libthirp.so` is the Linux operator library and links the system OpenSSL 3
libraries. The public header is `c_abi/thirp.h`. The published SDK tarball
contains this library plus the macOS and Windows shared libraries. Those are
produced by the data-plane release scripts and packed by
`scripts/assemble_sdk.sh`. Consumer-oriented layout and link examples are
documented in [SDK.md](SDK.md#c-abi).

### macOS

```bash
OPENSSL_LIB="$(brew --prefix openssl@3)/lib"
odin build c_abi -build-mode:shared -out:libthirp.dylib -extra-linker-flags:"-L${OPENSSL_LIB}"
cc -o thirp-c-smoke c_abi/smoke.c -I c_abi -L. -lthirp -Wl,-rpath,$PWD
```

`libthirp.dylib` links Homebrew OpenSSL 3.

### Windows

```cmd
odin build c_abi -build-mode:shared -out:libthirp.dll
cl /Fe:thirp-c-smoke.exe c_abi\smoke.c /I c_abi libthirp.lib
```

`libthirp.dll` links system OpenSSL 3 libraries.

## Run the test suite

### All platforms

```bash
odin test . -all-packages
```

The full command runs the protocol, transport, authentication, Broker, Agent,
Caller, configuration, logging, version, C ABI, and Web Ingress tests.

On macOS, add the OpenSSL linker flags:

```bash
OPENSSL_LIB="$(brew --prefix openssl@3)/lib"
odin test . -all-packages -extra-linker-flags:"-L${OPENSSL_LIB}"
```

On Windows, ensure OpenSSL 3 DLLs are in PATH.

A test run is not successful if it logs `+++ leak`, even when the process exits
with status 0.

## Build SDK examples

The examples use the same `thirp:` collection paths supported by packaged SDKs.
On Linux:

```bash
odin build examples/sdk/odin/ephemeral_host -collection:thirp=.
odin build examples/sdk/odin/join_code_client -collection:thirp=.
```

On macOS, add OpenSSL linker flags:

```bash
OPENSSL_LIB="$(brew --prefix openssl@3)/lib"
odin build examples/sdk/odin/ephemeral_host -collection:thirp=. -extra-linker-flags:"-L${OPENSSL_LIB}"
odin build examples/sdk/odin/join_code_client -collection:thirp=. -extra-linker-flags:"-L${OPENSSL_LIB}"
```

See [SDK.md](SDK.md) for lifecycle and API guidance.

## Cross-platform status

- **Linux**: Operator release from `scripts/release.sh` (`thirp-broker`, `thirp-agent`, `thirp-connect`, `thirp-web-ingress`, `libthirp.so`, SDK and Broker tarballs, source, SBOM, provenance). Attached to `v<VERSION>` by `scripts/publish_github.sh --release`.
- **macOS**: Data-plane release tree (`thirp-agent`, `thirp-connect`, `libthirp.dylib`) via `scripts/release_macos.sh` on **arm64** (`macos-latest`) and **x86_64 (Intel)** (`macos-15-intel`). The workflow attaches both archives to the same `v<VERSION>` Release.
- **Windows**: Data-plane release tree (`thirp-agent.exe`, `thirp-connect.exe`, `libthirp.dll`) via `scripts/release_windows.ps1` (AMD64), attached to that same Release.

macOS and Windows agents and callers connect outbound to a Linux broker over TLS.
Broker / Web Ingress / full operator stacks remain Linux-primary in published
operator Releases. Convenience Broker/Web Ingress binaries still build from
`scripts/build_macos.sh` and `scripts/build_windows.bat` without the `dataplane`
argument; they are not part of the published data-plane trees.

The `dataplane-release` GitHub Actions workflow (Origin-compatible GHA YAML in
`.github/workflows/dataplane-release.yml`) runs `scripts/release_dataplane_test.sh`
on Ubuntu and the native release scripts on `macos-latest` (arm64),
`macos-15-intel` (x86_64), and `windows-latest`.

## Produce a Linux release tree

`scripts/release.sh` builds and verifies the complete artifact set:

```bash
scripts/release.sh
```

The output directory is:

```text
dist/thirp-runtime-<VERSION>/
```

It contains:

- `thirp-broker`, `thirp-agent`, `thirp-connect`, and `thirp-web-ingress`
- `libthirp.so` and `thirp.h`
- the public source archive
- a host SDK tarball (the `libthirp` this machine just built) and the Broker Odin collection tarball. The host SDK is what `scripts/verify_sdk.sh` links. It is not listed in `SHA256SUMS` and it is not the published SDK. The published SDK is `scripts/assemble_sdk.sh`, which packs linux-x86_64, darwin-arm64, darwin-x86_64, and windows-amd64.
- the SPDX SBOM
- `LICENSE`, `NOTICE`, changelog, dependency inventory, and provenance
- Web Ingress deployment examples
- `SHA256SUMS` and, when the publish key is available, `SHA256SUMS.asc`

The script also:

- checks that the Odin compiler meets the documented minimum
- inventories the supported SDK API
- verifies SDK and Broker artifacts in clean layouts
- verifies every generated checksum
- confirms that built version output includes the project version and commit
- validates required SBOM and provenance fields
- packs the source archive from the public allowlist, not the private git tree

If the Thirp publish key is in the local GPG agent, `scripts/release.sh` detaches `SHA256SUMS.asc` automatically. Override with `THIRP_GPG_KEY=<key-id>`. The published fingerprint and verification command are in [SECURITY.md](SECURITY.md#release-signing).

## macOS and Windows data-plane release

These scripts produce the same kind of checksummed tree as Linux, limited to
the data plane: Agent CLI, Caller CLI, and `libthirp`. Protocol 1.0 is unchanged.

### macOS

Must run on Darwin with Homebrew OpenSSL 3 and Odin `dev-2026-07` or later:

```bash
scripts/release_macos.sh
```

Output:

```text
dist/thirp-runtime-macos-<arch>-<VERSION>/
dist/thirp-runtime-macos-<arch>-<VERSION>.tar.gz
```

The directory contains `thirp-agent`, `thirp-connect`, `libthirp.dylib`,
`thirp.h`, `LICENSE`, `NOTICE`, changelog, dependency inventory, `PROVENANCE.txt`,
and `SHA256SUMS`. `SHA256SUMS.asc` is added when the Thirp publish key is in the
agent (`THIRP_GPG_KEY`, same fingerprint as Linux). CI uploads
`thirp-runtime-macos-arm64-<VERSION>.tar.gz` and
`thirp-runtime-macos-x86_64-<VERSION>.tar.gz` onto the `v<VERSION>` Release.

Apple Developer ID signing is optional and skipped unless
`THIRP_MACOS_CODESIGN_IDENTITY` is set. Notarization is skipped unless
`THIRP_MACOS_NOTARY_PROFILE` names a `notarytool` keychain profile. Without
those secrets the archives are checksummed and not OS-signed.

### Windows

Must run on Windows with OpenSSL 3, MSVC, and Odin `dev-2026-07` or later:

```cmd
scripts\release_windows.bat
```

or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\release_windows.ps1
```

Output:

```text
dist\thirp-runtime-windows-<VERSION>\
dist\thirp-runtime-windows-<arch>-<VERSION>.zip
```

Authenticode signing is skipped unless `THIRP_WINDOWS_PFX` (and optional
`THIRP_WINDOWS_PFX_PASSWORD`) is set and `signtool.exe` is on `PATH`.

### Verify a downloaded tree

```bash
# macOS or Linux host checking a darwin tree
sha256sum -c SHA256SUMS
gpg --verify SHA256SUMS.asc SHA256SUMS   # when the detached signature is present
bash scripts/verify_dataplane_release.sh dist/thirp-runtime-macos-<arch>-<VERSION> darwin
```

```powershell
# Windows: Get-FileHash against each SHA256SUMS line
```

The GPG fingerprint is in [SECURITY.md](SECURITY.md#release-signing). Unsigned
checksums are still usable.

### How artifacts are published

1. `scripts/publish_github.sh` is a dry-run until `--push`. It stages the
   public tree, scans it, and writes `PUBLISH_MANIFEST.txt` plus
   `RELEASE_NOTES.md` under `dist/publish-github/`.
2. `--push --release` (with `--qualified`) fast-forwards `thirp/runtime` and
   attaches the Linux operator tree from `dist/thirp-runtime-<VERSION>/`,
   including `thirp-web-ingress` and the Broker collection. `--release`
   requires `SHA256SUMS.asc`. It does not attach the embed SDK tarball.
3. The tag push `v<VERSION>` runs `.github/workflows/dataplane-release.yml`.
   The `check`, `linux-lib`, `macos` (arm64 and x86_64), and `windows` jobs
   build on hosted runners. Native jobs upload `libthirp.so`,
   `thirp-runtime-macos-arm64-*.tar.gz`, `thirp-runtime-macos-x86_64-*.tar.gz`,
   and `thirp-runtime-windows-*.zip`. The unpacked Windows directory stays off
   the artifact. It shares names with the Linux operator release.
4. The workflow `publish` job downloads those artifacts, runs
   `scripts/assemble_sdk.sh`, and attaches four archives to the same GitHub
   Release: the SDK tarball, both macOS tarballs, and the Windows zip. It does
   not upload loose files from those trees and it does not replace operator
   assets. The dry-run does not upload those files.
5. If `dist/thirp-runtime-macos-<arch>-<VERSION>.tar.gz` or
   `dist/thirp-runtime-windows-<arch>-<VERSION>.zip` already exist locally,
   `scripts/publish_github.sh --release` attaches those archives too.

`scripts/release_dataplane_test.sh` checks script syntax, allowlists, workflow
wiring, and fixture trees. It does not compile `.dylib` / `.dll`.

### Signing blockers (certs pending)

Data-plane CI uploads checksummed archives without OS-level signatures until
these secrets are set. The scripts skip signing when they are absent:

| Blocker | Env / secret | Effect if missing |
|---|---|---|
| Thirp publish GPG private key in CI | `THIRP_GPG_PRIVATE_KEY`, optional `THIRP_GPG_PASSPHRASE`; local override `THIRP_GPG_KEY` | `SHA256SUMS` is still produced; no `SHA256SUMS.asc` |
| Apple Developer ID Application certificate | `THIRP_MACOS_CODESIGN_IDENTITY`, `THIRP_MACOS_CERT_P12`, `THIRP_MACOS_CERT_PASSWORD` | Gatekeeper warns; users can still run or build from source |
| Apple notarization credentials | `THIRP_MACOS_NOTARY_PROFILE` (after `xcrun notarytool store-credentials`) | Signed but not notarized; first launch still needs explicit allow |
| Windows Authenticode certificate | `WINDOWS_CERT_PFX` / `THIRP_WINDOWS_PFX`, `WINDOWS_CERT_PASSWORD` / `THIRP_WINDOWS_PFX_PASSWORD` | SmartScreen warns; users can still run or build from source |

Do not invent or commit those keys. The GPG fingerprint that CI must match is
the one already published in [SECURITY.md](SECURITY.md#release-signing). Hosted
`macos-latest` / `macos-15-intel` / `windows-latest` runners for
`dataplane-release` must be available on `thirp/runtime`.

## Artifact contracts

One project version produces two developer-facing Odin artifacts in addition
to the operator binaries:

- `thirp-runtime-sdk-<VERSION>.tar.gz` contains Agent and Caller source
  packages, their compile closure, `libthirp` for linux-x86_64, darwin-arm64,
  darwin-x86_64, and windows-amd64, and SDK examples.
- `thirp-runtime-broker-<VERSION>.tar.gz` contains the Broker-capable Odin
  collection, including authentication and authorization packages.

The exact contents and collection mappings are defined in
[SDK.md](SDK.md#two-artifacts). Compatibility commitments are in
[COMPATIBILITY.md](COMPATIBILITY.md).
