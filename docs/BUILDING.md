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
- OpenSSL 3 build prefix with host-architecture `libssl.a` and `libcrypto.a` (Homebrew or MacPorts; see `OPENSSL_PREFIX` below)
- Xcode Command Line Tools

### Windows

Windows builds are supported for Broker, Agent, Caller and `libthirp.dll`.
Build the Web Ingress CLI on Linux or macOS because it uses POSIX signal
handling. A Windows build requires these tools.

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

Both echo fixtures take a required `--listen HOST:PORT` with a numeric IP
address. Use `-h` or `--help` to print usage and exit.

### macOS

```bash
# Homebrew example on Apple silicon:
export OPENSSL_PREFIX=/opt/homebrew/opt/openssl@3
# MacPorts alternative:
# export OPENSSL_PREFIX=/opt/local/libexec/openssl3
bash scripts/build_macos.sh all        # also Broker and Web Ingress
# bash scripts/build_macos.sh dataplane # Agent, Connect, libthirp.dylib
```

The binaries are written to `dist/thirp-runtime-macos-<arch>-<VERSION>/`.
An explicit prefix takes priority; when unset the scripts try
`brew --prefix openssl@3`, then fail with instructions. They never install
software. Both static archives must contain the host architecture (checked with
`lipo -info`). The shared helper stages them relative to the importing
`transport` package, in gitignored `transport/build/openssl-darwin-arm64` or
`openssl-darwin-amd64`. Every build passes `-define:OPENSSL_STATIC=true`.
MacPorts' private `-lz` uses system zlib. The build rejects unsupported
private OpenSSL dependencies. To select an existing compiler, set
`ODIN=/path/to/odin` for the build, or put it on PATH.

For a manual build, source the same staging helper from the repo root:

```bash
source scripts/macos_openssl.sh
macos_prepare_openssl
odin build agent_cli -out:thirp-agent -define:OPENSSL_STATIC=true -extra-linker-flags:"$OPENSSL_LINK_FLAGS"
```

### Windows

```cmd
REM From an x64 Developer Command Prompt, point LIB and PATH at OpenSSL 3
set "LIB=C:\Program Files\OpenSSL\lib\VC\x64\MD;%LIB%"
set "PATH=C:\Program Files\OpenSSL\bin;%PATH%"
odin build broker_cli -out:thirp-broker.exe
odin build agent_cli -out:thirp-agent.exe
odin build caller_cli -out:thirp-connect.exe
```

Or build Agent, Caller and the shared library with the script from an x64
Developer Command Prompt. It writes binaries
to `dist\thirp-runtime-windows-<VERSION>\`:

```cmd
scripts\build_windows.bat dataplane
```

`build_windows.bat` finds `libssl.lib` under `OPENSSL_ROOT_DIR` (or `C:\Program Files\OpenSSL`, then `C:\Program Files\OpenSSL-Win64`, when `bin\openssl.exe` exists) and prepends that directory to `LIB`. Use an AMD64 OpenSSL 3 installation. Adjust the example paths to match that installation.

## Build the C ABI

### Linux

```bash
odin build c_abi -build-mode:shared -out:libthirp.so
cc -o thirp-c-smoke c_abi/smoke.c -I c_abi -L. -lthirp -Wl,-rpath,$PWD
```

`libthirp.so` is the Linux operator library and links the system OpenSSL 3
libraries. The public header is `c_abi/thirp.h`. The combined SDK tarball
contains this library plus the macOS and Windows shared libraries. The
data-plane release scripts build those libraries for packaging by
`scripts/assemble_sdk.sh`. Consumer-oriented layout and link examples are
documented in [SDK.md](SDK.md#c-abi).

### macOS

```bash
source scripts/macos_openssl.sh
macos_prepare_openssl
odin build c_abi -build-mode:shared -out:libthirp.dylib -define:OPENSSL_STATIC=true -extra-linker-flags:"$OPENSSL_LINK_FLAGS"
cc -o thirp-c-smoke c_abi/smoke.c -I c_abi -L. -lthirp -Wl,-rpath,$PWD
```

`libthirp.dylib` statically links OpenSSL 3 inside the shared library. SDK consumers need no separate OpenSSL install on macOS.

### Windows

```cmd
odin build c_abi -build-mode:shared -out:libthirp.dll
```

`libthirp.dll` dynamically links OpenSSL 3. The Windows data-plane zip
includes the matching DLLs. A standalone build or SDK consumer must supply
them. The standalone C smoke program uses POSIX calls. On Windows, the
Odin suite includes tests for the C ABI.

## Run the test suite

### All platforms

```bash
odin test . -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
```

The full command runs the protocol, transport, authentication, Broker, Agent,
Caller, configuration, logging, version, C ABI, and Web Ingress tests.
The SDK package-boundary test uses system Bash on Linux and macOS, including
macOS's Bash 3.2. On Windows it uses Git for Windows Bash from its default
installation directory or `bash.exe` on `PATH` for a custom installation.

Odin's test runner tracks allocations but, by default, only prints `+++ leak`
and still exits 0 (`ODIN_TEST_FAIL_ON_BAD_MEMORY` defaults to false in
`core:testing`). The define above turns those into test failures. A package
cannot change that default.

On macOS, stage and use the same static OpenSSL archives for tests:

```bash
source scripts/macos_openssl.sh
macos_prepare_openssl
odin test . -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:OPENSSL_STATIC=true -extra-linker-flags:"$OPENSSL_LINK_FLAGS"
```

On Windows, use the same Developer Command Prompt and OpenSSL 3 `LIB` and
`PATH` settings as the command-line builds. The Windows data-plane release
zip includes the OpenSSL DLLs beside its executables.

A test run is not successful if it logs `+++ leak`, even when the process exits
with status 0.

Run a built CLI with `--version` and compare its project version with
`VERSION.txt`. Release builds also include the source commit.

## Build SDK examples

The local example pair uses a POSIX signal handler in the host. Run that
host on Linux or macOS. The Odin client can run on Windows as well.

The examples use the same `thirp:` collection paths supported by packaged SDKs.
On Linux:

```bash
odin build examples/sdk/odin/ephemeral_host -collection:thirp=.
odin build examples/sdk/odin/join_code_client -collection:thirp=.
```

On macOS, use the staged static archives:

```bash
source scripts/macos_openssl.sh
macos_prepare_openssl
odin build examples/sdk/odin/ephemeral_host -collection:thirp=. -define:OPENSSL_STATIC=true -extra-linker-flags:"$OPENSSL_LINK_FLAGS"
odin build examples/sdk/odin/join_code_client -collection:thirp=. -define:OPENSSL_STATIC=true -extra-linker-flags:"$OPENSSL_LINK_FLAGS"
```

On Windows, set up the OpenSSL 3 import libraries and DLLs as for the
command-line builds, then build the client:

```cmd
odin build examples/sdk/odin/join_code_client -collection:thirp=. -out:join_code_client.exe
```

See [SDK.md](SDK.md) for lifecycle and API guidance.

## Release archives

Find the archives available for each tag on the releases page.
[GitHub Releases](https://github.com/thirp/runtime/releases)

| Platform | Archive name | Contents |
|---|---|---|
| Linux x86_64 | `thirp-runtime-linux-x86_64-<VERSION>.tar.gz` | Broker, Agent, Caller, Web Ingress, `libthirp.so`, Broker collection and source archive |
| macOS arm64 | `thirp-runtime-macos-arm64-<VERSION>.tar.gz` | Agent, Caller and `libthirp.dylib` |
| macOS x86_64 (Intel) | `thirp-runtime-macos-x86_64-<VERSION>.tar.gz` | Agent, Caller and `libthirp.dylib` |
| Windows AMD64 | `thirp-runtime-windows-AMD64-<VERSION>.zip` | Agent, Caller, `libthirp.dll` and the OpenSSL 3 DLLs |

The platform archives include checksums and build provenance. See the SDK
guide for the separate embed SDK and Broker collection layouts.
[Verify a downloaded tree](#verify-a-downloaded-tree) · [SDK](SDK.md#two-artifacts)

## Produce a Linux release tree

`scripts/release.sh` builds and verifies the complete artifact set:

```bash
scripts/release.sh
```

The build tree is:

```text
dist/thirp-runtime-<VERSION>/
```

It contains:

- `thirp-broker`, `thirp-agent`, `thirp-connect`, and `thirp-web-ingress`
- `libthirp.so` and `thirp.h`
- the public source archive
- a host SDK tarball for local verification and the Broker Odin collection
- the SPDX SBOM
- `LICENSE`, `NOTICE`, changelog, dependency inventory, and provenance
- Web Ingress deployment examples
- `SHA256SUMS` and, when the publish key is available, `SHA256SUMS.asc`

The operator archive is `dist/thirp-runtime-linux-<arch>-<VERSION>.tar.gz`.
Build the combined, four-target embed SDK with `scripts/assemble_sdk.sh`.

The script also:

- checks that the Odin compiler meets the documented minimum
- inventories the supported SDK API
- verifies SDK and Broker artifacts in clean layouts
- verifies every generated checksum
- confirms that built version output includes the project version and commit
- validates required SBOM and provenance fields
- packs the public source archive

If the Thirp publish key is in the local GPG agent, `scripts/release.sh` detaches `SHA256SUMS.asc` automatically. Override with `THIRP_GPG_KEY=<key-id>`. The published fingerprint and verification command are in [SECURITY.md](SECURITY.md#release-signing).

## macOS and Windows data-plane release

These scripts produce the same kind of checksummed tree as Linux, limited to
the data plane: Agent CLI, Caller CLI, and `libthirp`, plus the OpenSSL 3 DLLs
on Windows. Protocol 1.0 is unchanged.

### macOS

Run on macOS with an OpenSSL 3 static-archive prefix and Odin
`dev-2026-07` or later. The hosted build uses `macos-latest` for arm64 and
`macos-15-intel` for x86_64.

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
and `SHA256SUMS`. A detached signature is included if a signing key is
configured. [Release signing](SECURITY.md#release-signing)

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

The tree and zip include `libssl-3-x64.dll` and `libcrypto-3-x64.dll` beside
`thirp-agent.exe`, `thirp-connect.exe`, and `libthirp.dll`. The release script
selects the same OpenSSL 3 root as `build_windows.bat` and copies only those two
DLLs from its `bin\` directory. Both are required and included in `SHA256SUMS`;
that root's `openssl version` is recorded in `PROVENANCE.txt`. OpenSSL 4 is
rejected. With `-SkipBuild`, select the OpenSSL 3 tree used for the existing
binaries. Linux dynamically links distro OpenSSL; macOS statically links the
build prefix’s OpenSSL 3 archives.

Authenticode signing of the three Thirp binaries is skipped unless
`THIRP_WINDOWS_PFX` (and optional `THIRP_WINDOWS_PFX_PASSWORD`) is set and
`signtool.exe` is on `PATH`. The third-party OpenSSL DLLs are kept as supplied
and are not signed with the Thirp PFX.

### Verify a downloaded tree

Run the checksum command from the extracted archive directory.

```bash
# Linux
sha256sum -c SHA256SUMS
# macOS
shasum -a 256 -c SHA256SUMS
```

```powershell
$checksums = @(Get-Content -LiteralPath SHA256SUMS -ErrorAction Stop)
if ($checksums.Count -eq 0) {
    throw 'SHA256SUMS is empty'
}
foreach ($line in $checksums) {
    if ($line -notmatch '^([0-9a-fA-F]{64}) {2}(.+)$') {
        throw "Invalid checksum line: $line"
    }
    $expected = $Matches[1]
    $path = $Matches[2]
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path -ErrorAction Stop).Hash
    if ($actual -ne $expected) { throw "Checksum mismatch: $path" }
}
```

When the archive includes a detached signature, verify it with the release
key. [Release signing](SECURITY.md#release-signing)

The data-plane verifier also checks the archive layout. For macOS it checks
all Mach-O slices for dependencies on package-manager libraries.

```bash
bash scripts/verify_dataplane_release.sh /path/to/extracted/archive darwin
```

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
