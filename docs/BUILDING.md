# Building, testing, and packaging

This document covers source builds and the Linux release pipeline. If you only
want to see Runtime relay a service, begin with the
[local TLS quickstart](QUICKSTART.md).

## Supported build environment

The current release tooling targets Linux and requires:

- [Odin](https://odin-lang.org/) `dev-2026-07` or later
- OpenSSL 3 development files (`libssl` and `libcrypto`)
- a C compiler for the C ABI smoke test
- standard Unix release tools used by `scripts/release.sh`

The release script records the exact Odin and OpenSSL versions in generated
provenance. See [DEPENDENCIES.md](DEPENDENCIES.md) for the dependency inventory.

## Build command-line components

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

## Build the C ABI

```bash
odin build c_abi -build-mode:shared -out:libthirp.so
cc -o thirp-c-smoke c_abi/smoke.c -I c_abi -L. -lthirp -Wl,-rpath,$PWD
```

`libthirp.so` is currently Linux-only and links the system OpenSSL 3 libraries.
The public header is `c_abi/thirp.h`. Consumer-oriented layout and link examples
are documented in [SDK.md](SDK.md#c-abi).

## Run the test suite

```bash
odin test . -all-packages
```

The full command runs the protocol, transport, authentication, Broker, Agent,
Caller, configuration, logging, version, C ABI, and Web Ingress tests.

A test run is not successful if it logs `+++ leak`, even when the process exits
with status 0. Known concurrency hazards and their required invariants are
documented in [RACES.md](RACES.md).

## Build SDK examples

The examples use the same `thirp:` collection paths supported by packaged SDKs:

```bash
odin build examples/sdk/odin/ephemeral_host -collection:thirp=.
odin build examples/sdk/odin/join_code_client -collection:thirp=.
```

See [SDK.md](SDK.md) for lifecycle and API guidance.

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
- Agent/Caller SDK and Broker Odin collection tarballs
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

## Artifact contracts

One project version produces two developer-facing Odin artifacts in addition
to the operator binaries:

- `thirp-runtime-sdk-<VERSION>.tar.gz` contains Agent and Caller source
  packages, their compile closure, the Linux C ABI, and SDK examples.
- `thirp-runtime-broker-<VERSION>.tar.gz` contains the Broker-capable Odin
  collection, including authentication and authorization packages.

The exact contents and collection mappings are defined in
[SDK.md](SDK.md#two-artifacts). Compatibility commitments are in
[COMPATIBILITY.md](COMPATIBILITY.md).
