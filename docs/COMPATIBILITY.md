# Compatibility

The Runtime release version appears in `VERSION.txt`, `--version` and
`THIRP_VERSION_STRING`. The wire protocol has its own version.
[Protocol](PROTOCOL.md)

## Protocol

Supported protocol major version: **1** only.

- Header `version != 1` or `HELLO.major != 1` → `UNSUPPORTED_VERSION` (numeric `2`) and the connection closes.
- The broker does not reject an unknown `HELLO.minor`. It replies with `minor = 0`.
- Version 1.0 sends `capability_bits = 0`. Peers must not treat unknown bits as ignorable until a version defines that behavior ([PROTOCOL.md](PROTOCOL.md) §9).
- Breaking wire changes increment the protocol major version. Backward-compatible additions may increment `PROTOCOL_MINOR` or assign capability bits.

[PROTOCOL.md](PROTOCOL.md) is normative for framing, opcodes, and error codes.

## Client and broker

Any agent or caller that speaks protocol 1.0 can talk to a protocol 1.0 broker. Project `0.x` releases that all speak protocol 1.0 are wire-compatible with each other.

`--version` prints both the project version and the wire protocol version.

`thirp-web-ingress` is an additional public Caller adapter. It speaks protocol 1.0 as a Caller. `thirp-connect` remains the installed caller-side loopback bridge.

## C ABI

[c_abi/thirp.h](https://github.com/thirp/runtime/blob/main/c_abi/thirp.h) defines signatures and numeric error codes.

- Project `0.x` may add functions. Removals or signature changes require a [CHANGELOG.md](https://github.com/thirp/runtime/blob/main/docs/CHANGELOG.md) entry.
- Handles are opaque. Do not depend on Odin struct layout, allocators, or `context`.
- [SDK library layout and dependencies](SDK.md#c-abi)
- Identify a built shared library with `SHA256SUMS` and `PROVENANCE.txt`.
- `thirp_conn_read` / `thirp_conn_write` block. Language bindings that cannot block the main thread must call them from a worker thread.

## Odin source API

[sdk-public-api.txt](sdk-public-api.txt) is the supported consumer surface. Import paths:

```odin
import thirp_agent "thirp:agent"
import thirp_caller "thirp:caller"
```

- Collection root is the repository root in sibling checkout, or `odin/thirp/` in either tarball. Same imports in both modes.
- The Broker collection also exports `thirp:auth` and `thirp:broker`. Those packages are not in the embed SDK.
- Project `0.x` may add documented procedures and types. Removals or signature changes of inventoried names require a [CHANGELOG.md](https://github.com/thirp/runtime/blob/main/docs/CHANGELOG.md) entry and an inventory update.
- Unlisted procedures in those packages are unsupported internals. Odin cannot hide them; do not depend on them.
- Minimum compiler: Odin `dev-2026-07` ([DEPENDENCIES.md](https://github.com/thirp/runtime/blob/main/docs/DEPENDENCIES.md)).
- `agent_run` blocks. `caller_init` connects immediately. `caller_destroy` closes the session and releases internal resources. The application owns the `Caller` struct storage.
- The library takes a token string. Token files are an application/CLI concern.

## Release targets

See the platform archive list and the SDK collection layout.
[Release archives](https://github.com/thirp/runtime/blob/main/docs/BUILDING.md#release-archives) · [SDK artifacts](SDK.md#two-artifacts)

## Service ids

A live registration is unique by `service_id` within its environment, or
within its organization if there is no environment. Registrations with
neither use the global namespace. `REGISTER` and `CONNECT` carry the
`service_id`. The Broker uses the authenticated session's environment or
organization to select the namespace.

## Join codes

An ephemeral join code is an identifier in `namespace/code`. It is not a credential. AUTH still uses the token. Callers use `dial_join_code` with the same namespace.

## Streams and reconnect

See session recovery for the effect of a broker restart on live streams.
[Operations](https://github.com/thirp/runtime/blob/main/docs/OPERATIONS.md#session-recovery)

## Configuration

Broker and agent config is line-oriented `key = value` ([OPERATIONS.md](https://github.com/thirp/runtime/blob/main/docs/OPERATIONS.md)). Web Ingress has its own file; do not put public TLS keys or host route tables in Broker or Agent configuration.

- Unknown keys and duplicate non-repeatable keys fail validation. The process does not start.
- New keys may appear in later `0.x` releases.
- Existing keys keep their meaning. A breaking change is called out in [CHANGELOG.md](https://github.com/thirp/runtime/blob/main/docs/CHANGELOG.md) with a migration example where feasible.
- Security rules are never reinterpreted silently: grant prefix syntax, credential line grammar, `policy_mode`, and TLS-required-unless-insecure.
- Caller flag and configuration compatibility is described in the command
  reference. [Caller options](https://github.com/thirp/runtime/blob/main/caller_cli/README.md#usage)
