# Compatibility

Project version (`VERSION.txt`, `--version`, `THIRP_VERSION_STRING`) is **not** the wire protocol version. This document states what is compatible today. The wire contract is [PROTOCOL.md](PROTOCOL.md).

## Protocol

Supported protocol major version: **1** only.

- Header `version != 1` or `HELLO.major != 1` → `UNSUPPORTED_VERSION` (numeric `2`) and the connection closes.
- The broker does not reject an unknown `HELLO.minor`. It replies with `minor = 0`.
- Version 1.0 sends `capability_bits = 0`. Peers must not treat unknown bits as ignorable until a version defines that behavior ([PROTOCOL.md](PROTOCOL.md) §9).
- Breaking wire changes increment the protocol major version. Backward-compatible additions may increment `PROTOCOL_MINOR` or assign capability bits.

[PROTOCOL.md](PROTOCOL.md) is normative for framing, opcodes, and error codes.

## Client and broker

Any agent or caller that speaks protocol 1.0 can talk to a protocol 1.0 broker. Project `0.x` releases that all speak protocol 1.0 are wire-compatible with each other.

Do not infer protocol compatibility from the executable version. `--version` always prints both, for example:

```text
thirp-broker 0.16.4 (commit <sha>, protocol 1.0)
```

A single-broker restart interrupts active sessions. Drain rejects new `REGISTER` / `CONNECT`, lets existing streams finish within `shutdown_grace`, then exits. Agents reconnect and re-register the desired set. `thirp-connect` reconnects the broker session; lost local sockets still close. See [OPERATIONS.md](OPERATIONS.md).

`thirp-web-ingress` is an additional public Caller adapter. It speaks protocol 1.0 as a Caller. `thirp-connect` remains the installed caller-side loopback bridge.

## C ABI

[c_abi/thirp.h](../c_abi/thirp.h) is the contract. 0.16.0 renamed every C symbol, type, and macro; numeric `WireError` values 0–17 and overlay 100–106 are unchanged.

- After 0.16.0, existing function signatures and numeric error codes do not change silently.
- Project `0.x` may add functions. Removals or signature changes require a [CHANGELOG.md](CHANGELOG.md) entry.
- Handles are opaque. Do not depend on Odin struct layout, allocators, or `context`.
- The published SDK tarball contains `libthirp.so`, both `libthirp.dylib` builds, and `libthirp.dll` under `c/lib/<target>/`. Data-plane release trees also carry the shared library next to the Agent and Caller CLIs. Each library links system OpenSSL (`libssl` / `libcrypto`), same as [DEPENDENCIES.md](DEPENDENCIES.md).
- `THIRP_VERSION_STRING` is the project version, not the protocol version. Identify a built `.so` with `SHA256SUMS` and `PROVENANCE.txt`.
- `thirp_conn_read` / `thirp_conn_write` block. Language bindings that cannot block the main thread must call them from a worker thread.

## Odin source API

[sdk-public-api.txt](sdk-public-api.txt) is the supported consumer surface. Import paths:

```odin
import thirp_agent "thirp:agent"
import thirp_caller "thirp:caller"
```

- Collection root is the repository root in sibling checkout, or `odin/thirp/` in either tarball. Same imports in both modes.
- The Broker collection also exports `thirp:auth` and `thirp:broker`. Those packages are not in the embed SDK.
- Project `0.x` may add documented procedures and types. Removals or signature changes of inventoried names require a [CHANGELOG.md](CHANGELOG.md) entry and an inventory update.
- Unlisted procedures in those packages are unsupported internals. Odin cannot hide them; do not depend on them.
- Minimum compiler: Odin `dev-2026-07` ([DEPENDENCIES.md](DEPENDENCIES.md)).
- `agent_run` blocks. `caller_init` connects immediately; `caller_destroy` is shutdown (there is no `caller_stop`).
- The library takes a token string. Token files are an application/CLI concern.

## Artifact and target matrix

`v0.16.4` publishes the Linux operator as `thirp-runtime-linux-x86_64-0.16.4.tar.gz`. Inside it: `thirp-broker`, `thirp-agent`, `thirp-connect`, `thirp-web-ingress`, `libthirp.so`, and the Broker Odin collection tarball. The same Release carries one embed SDK tarball with `libthirp` for **linux-x86_64**, **darwin-arm64**, **darwin-x86_64**, and **windows-amd64**, plus data-plane archives with `thirp-agent`, `thirp-connect`, and the shared library for **macOS arm64**, **macOS x86_64 (Intel)**, and **Windows AMD64** (see [BUILDING.md](BUILDING.md#macos-and-windows-data-plane-release)). GitHub Actions builds those libraries and packs the SDK; the publisher dry-run does not. Broker and Web Ingress remain Linux-primary. No static `libthirp.a`. OpenSSL 3 (`libssl` / `libcrypto`) is required at runtime for TLS. CI pins the Odin compiler to `dev-2026-07`.

The embed SDK (`thirp-runtime-sdk-<VERSION>.tar.gz`) does not include Broker or `auth`. The Broker collection (`thirp-runtime-broker-<VERSION>.tar.gz`) adds those Odin packages and does not include the C ABI. There is no third foundation tarball. Sibling checkout is still the repository root.

## Join codes

An ephemeral join code is an identifier in `namespace/code`. It is not a credential. AUTH still uses the token. Callers use `dial_join_code` with the same namespace.

## Streams and reconnect

Broker sessions may reconnect. Relay streams do not resume. A lost stream fails; a later dial opens a new stream.

## Configuration

Broker and agent config is line-oriented `key = value` ([OPERATIONS.md](OPERATIONS.md)). Web Ingress has its own file; do not put public TLS keys or host route tables in Broker or Agent configuration.

- Unknown keys and duplicate non-repeatable keys fail validation. The process does not start.
- New keys may appear in later `0.x` releases.
- Existing keys keep their meaning. A breaking change is called out in [CHANGELOG.md](CHANGELOG.md) with a migration example where feasible.
- Security rules are never reinterpreted silently: grant prefix syntax, credential line grammar, `policy_mode`, and TLS-required-unless-insecure.
- Flags-only launch (no `--config`) remains the development path. `thirp-connect` has no config file.

## Rolling restart

Open-source deployments are one broker process. There is no zero-downtime broker upgrade. Install new binaries, restart the broker (drain), restart agents if their binary changed. See [OPERATIONS.md](OPERATIONS.md).
