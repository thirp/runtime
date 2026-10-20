# Changelog

Project version is independent of the wire protocol version. This tree speaks protocol 1.0. See [COMPATIBILITY.md](COMPATIBILITY.md).

## 0.16.5

Caller, Agent and Broker data-path fixes, plus the transport close/IO race fix. Protocol 1.0, the C ABI, and the wire are unchanged. This tag carries the Linux operator archive built locally (no GitHub Actions); the macOS, Windows, and multi-OS SDK archives from 0.16.4 are not rebuilt for it.

- Transport: closing a connection no longer releases a socket another thread is still reading or writing. An in-flight read or write holds a reference, so a closed connection's bytes can no longer land on another connection that reused the descriptor (a race present since 0.8.0; on Windows it could crash the process). The Agent holds a connection reference across register, unregister and stop.

Earlier data-path fixes in this release: Protocol 1.0, the C ABI, and the wire are unchanged. New Odin-only settings (no C field): `CallerConfig.max_stream_buffer` (8 MiB; also `thirp-connect --max-stream-buffer-mib`), `AgentConfig.stream_stall_timeout` (0 = 30 s, negative = never), `AgentConfig.max_stream_buffer` (64 MiB), `AgentConfig.max_buffered_bytes` (256 MiB), `AgentConfig.max_streams` (128) (also `thirp-agent --max-stream-buffer-mib`, `--max-buffered-mib`, `--max-streams`; each flag takes 1..1048576), and Broker `Server.stream_stall_timeout` (30 s). `thirp-connect` gains `--stream-stall-timeout SECONDS` (default 30, 0 = never; bounds writes to a local client) and `--max-stream-buffer-mib N` (1..1048576, default 8).

**Trade-off (protocol 1.0 has no per-stream flow control).** One TCP connection carries every stream of a session, so no hop can slow one stream's sender without stopping all of them. The Agent therefore buffers each stream's DATA to its local service and never makes its shared reader wait:
- A stream whose backlog would pass `max_stream_buffer` (64 MiB) is **reset at once**. A large upload to a service that reads slower than the sender fails once ~64 MiB is queued (for example a multi-hundred-MB upload to a slow disk). Raise `max_stream_buffer` (`--max-stream-buffer-mib`) for such services, at the cost of memory.
- When all streams together would pass `max_buffered_bytes` (256 MiB), the stream with the largest backlog is reset (then the new data's stream if needed). The session is never dropped.
- OPENs past `max_streams` (each stream uses two threads) fail with `QUOTA_EXCEEDED`; open streams are unaffected.
- The Caller (download direction: SDK, C ABI, Web Ingress and thirp-connect) works the same way. A stream whose unread backlog would pass `CallerConfig.max_stream_buffer` (8 MiB) is **reset at once**; the session reader never waits. A slow download (a client reading slower than the service sends, or a paused client such as a pager) fails once it is ~8 MiB behind, matching the Agent's 64 MiB upload trade-off. Waiting instead would fill the Broker's queue for that stream and make the Broker stop reading the Agent session, freezing every caller of that service (measured: 29 s).
- Per-stream flow control (a WINDOW message) is on the backlog for a later protocol version.

- `thirp-connect --token-file` no longer frees the token before the broker login (the broker logged `auth_failed reason=caller`).
- `thirp-connect` binds `--listen` before dialing the broker. A busy port exits 1 with a clear message. `caller_destroy` wakes the session reader with `shutdown` instead of freeing TLS under it (SIGSEGV on exit with TLS).
- One slow or stalled stream no longer holds up the others on a session. The Agent's relay reader queues DATA per stream (writer thread per stream) instead of writing to the local service inline, with the caps above; the Caller's session reader buffers per stream (8 MiB) and resets at the cap without waiting. Field repro: a 50 MB upload to a server reading ~320 KB/s blocked every other request.
- Stall limits are no-progress based (default 30 s) for the Agent's and thirp-connect's local writes and the Broker's wait for a full stream queue. Slow but steady readers are not reset below the caps. The old fixed 5 s Caller limit and the Agent's 5 s local write limit are gone.
- `caller_destroy` takes streams out of the table before finishing them (it left them there, and owners plus the reader then double-freed them).
- Plain-TCP send and recv retry on `EINTR` instead of ending the stream.
- The Agent closes its socket to the local service when that service closed first and the caller then finished (it stayed in CLOSE-WAIT).
- The Caller session reader holds a reference on a stream while it uses it, so the owner's `conn_destroy` cannot free it underneath.
- `thirp-connect` dials off the accept loop, passes local EOF as `HALF_CLOSE`, closes the local socket when the stream ends, polls local reads so it can stop bridges without relying on `shutdown` waking a blocked `recv` (Windows), caps concurrent connections at 256, and no longer sends a `CLOSE` after both sides half-closed.

## 0.16.4

One GitHub Release of archives: the Linux operator tarball (including Web Ingress), the multi-OS data-plane archives, and one embed SDK tarball. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged. CI pins Odin to `dev-2026-07`.

- `v0.16.4` replaces the split `v0.16.3` dataplane tags. The Linux operator archive from `scripts/release.sh` is `thirp-runtime-linux-x86_64-<version>.tar.gz` and includes `thirp-web-ingress`. macOS arm64, macOS x86_64, and Windows AMD64 Agent/Caller/`libthirp` archives are attached by the data-plane workflow. OS-level signing is not claimed.
- The published SDK tarball carries `libthirp` for linux-x86_64, darwin-arm64, darwin-x86_64, and windows-amd64. Broker and Web Ingress stay Linux-primary.
- Caller and Agent no longer RESET finished or unknown streams. The Broker drops leftover DATA before the terminal CLOSE/RESET. `STREAM_NOT_FOUND` Info logs are rate-limited.
- Agent OPEN is dialed off the relay reader. A failed DATA write sends RESET and finishes the stream. TLS writes no longer reuse the recv timeout.

## 0.16.3

Broker hostnames and TLS certificate chains. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- Agent, Connect, Web Ingress, C ABI, and SDK examples resolve `HOST:PORT` with DNS (`resolve_endpoint`; A preferred over AAAA). Listen addresses stay IP-only `parse_endpoint`.
- When TLS is on and `--tls-server-name` is empty, SNI is the broker hostname.
- TLS servers load a full PEM chain (`SSL_CTX_use_certificate_chain_file`) so Let's Encrypt intermediates are sent.

## 0.16.2

Keep HELLO `implementation` for observers; Agent/Connect send `version_line`. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- HELLO `implementation` is kept on `ConnHandler` and copied onto observer `RegistrationEvent.peer_implementation` / `ConnectionEvent.caller_implementation` and `agent_implementation`. Not a wire change.
- `thirp-agent` and `thirp-connect` send `version_line` as HELLO `implementation`.

## 0.16.1

Agent session survival after stream RESET. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- On `RESET`/`CLOSE`, the Agent no longer replies `StreamNotFound`. That echo ping-ponged with the Broker until the Agent session died, so a later CONNECT saw the Service as unregistered.
- The local pump shuts down the origin socket before destroy so it leaves `recv` instead of writing `HalfClose` onto a stream the Broker already dropped.
- `thirp-agent --token-file` kept the secret until process exit. Odin `defer` is block-scoped; the previous `defer delete` inside the read `if` freed the token before AUTH.

## 0.16.0

Breaking rename from rendez to Thirp Runtime. Protocol 1.0 is unchanged. Mixed 0.15.0 / 0.16.0 **wire** remains compatible. Source, C ABI, metrics, config paths, systemd units, and command names are not. No compatibility aliases.

- Collection `rendez` → `thirp`. Imports are `thirp:agent`, `thirp:caller`, `thirp:auth`, `thirp:broker`.
- Binaries `rendez-*` → `thirp-*` (`thirp-broker`, `thirp-agent`, `thirp-connect`, `thirp-web-ingress`).
- C ABI `rendez.h` / `librendez.so` / `RENDEZ_*` / `rendez_*` / `Rendez*` → `thirp.h` / `libthirp.so` / `THIRP_*` / `thirp_*` / `Thirp*`. Numeric WireError values 0–17 and overlay 100–106 stay.
- Metrics `rendez_*` → `thirp_*`, `rendez_web_ingress_*` → `thirp_web_ingress_*`.
- Default config directory `/etc/rendez` → `/etc/thirp`. systemd `User=thirp`. Units `thirp-broker.service`, `thirp-agent.service`, `thirp-web-ingress.service`.
- Release tree `dist/thirp-runtime-<VERSION>/` plus `thirp-runtime-sdk-<VERSION>.tar.gz` and `thirp-runtime-broker-<VERSION>.tar.gz`. Collection root `odin/thirp`. Manifest `"project": "thirp-runtime"`.
- HELLO `implementation` strings are `thirp-broker`, `thirp-agent`, `thirp-connect`, `thirp-web-ingress`.
- Signing env `RENDEZ_GPG_KEY` → `THIRP_GPG_KEY`.
- Source archive `thirp-runtime-<VERSION>.tar.gz` is the public allowlisted tree.
- GitHub Releases attach every file listed in `SHA256SUMS`, plus `SHA256SUMS` and `SHA256SUMS.asc`.

## 0.15.0

Per-stream DATA byte counters on the connection observer, and `AuthzReason.Quota`. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- `RelayStream` counts `bytes_caller_to_agent` and `bytes_agent_to_caller` on successful DATA enqueue. `ConnectionEvent` copies those totals on Closed and Reset. Authorized, Denied, and Opened leave them zero.
- `AuthzReason.Quota` maps to existing wire `QuotaExceeded` (code 10). Metric label is `quota`.

## 0.14.0

Grant and lease context on relay streams. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- `check_connect_policy` returns `AuthzDecision`. CONNECT copies grant id, credential, principal, org/env, `valid_until`, `authorization_lease_until`, and `policy_version` onto `RelayStream`.
- `server_reset_grant` RESET streams for one grant (`Unauthorized` / `GrantRevoked`). Empty grant id never matches. Other grants are untouched.
- `server_set_grant_lease` refreshes `authorization_lease_until`. Conn poll RESET when a non-zero `valid_until` or lease is reached (`Timeout` / `GrantExpired` or `LeaseExpired`). Zero times skip enforcement (local mode).
- `connection_observer` reports Authorized, Denied, Opened, Closed, and Reset. Local mode may leave it nil.

## 0.13.0

Replaceable Broker `Authorizer`. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- `broker.Server` takes an optional `Authorizer` (`authorize_register` / `authorize_connect`). Nil procs keep Production `StaticPolicy` and Development `may_*`. A set proc that returns `Unavailable` fails closed.
- `AuthzDecision` carries allowed/reason, org/env, grant id, validity, lease, and `policy_version`. They are not on the wire; REGISTER/CONNECT failures stay `UNAUTHORIZED`.
- AUTH clones `credential_id`, `environment_id`, `principal_kind`, and `policy_version` onto `ConnHandler`.
- `registration_observer` reports REGISTER/UNREGISTER and session teardown. `server_disconnect_credential` closes matching Agent sessions.
- `static_policy_authorizer` wraps file-backed grants for local mode.

## 0.12.0

Broker Odin collection tarball. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- `scripts/release.sh` emits `rendez-broker-<VERSION>.tar.gz` next to `rendez-sdk-<VERSION>.tar.gz`. Same `VERSION.txt`.
- Broker artifact is the embed SDK Odin packages plus `auth` and `broker` (non-test sources). No C ABI, CLIs, tests, `config`, `web_ingress`, or `version`.
- `BROKER_MANIFEST.json` records public packages `agent`, `caller`, `auth`, `broker`. Collection root remains `odin/rendez`.
- Clean-room verification is `scripts/verify_broker.sh`.
- Two artifacts, not three. Foundation (`protocol`, `transport`, `logging`) is a layer inside both. Sibling checkout is still the repository root.

## 0.11.0

Replaceable Broker `Authenticator`. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- `broker.Server` takes `auth.Authenticator` by value. Local `rendez-broker` wraps the existing static token store. A nil authenticate proc fails closed (`AUTHENTICATION_FAILED`).
- `AuthResult` adds optional `credential_id`, `environment_id`, `principal_kind`, and `policy_version`. They are not on the wire; `AUTHENTICATE_OK` is still `principal_id` only.
- AUTH clones principal id, organization, and label so a managed authenticator need not keep store-backed strings.

## 0.10.0

Agent/Caller SDK distribution. Protocol 1.0 and the C ABI signatures are unchanged.

### SDK

- `scripts/release.sh` emits `rendez-sdk-<VERSION>.tar.gz` next to the operator artifacts.
- Odin consumers import `rendez:agent` and `rendez:caller` with `-collection:rendez=<root>`. Sibling checkout uses the repository root; the extracted SDK uses `odin/rendez/`.
- The SDK source tree is Agent, Caller, and their compile closure (`protocol`, `transport`, `logging`). Broker, CLIs, and tests are excluded.
- Linux C subtree: `c/include/rendez.h` and `c/lib/linux-<arch>/librendez.so`.
- Examples: `examples/sdk/odin/ephemeral_host`, `examples/sdk/odin/join_code_client`, `examples/sdk/c/echo_client`.
- `SDK_MANIFEST.json` records version, collection root, and per-file SHA-256. Clean-room verification is `scripts/verify_sdk.sh`.
- Guide: [SDK.md](SDK.md). Supported surface: [sdk-public-api.txt](sdk-public-api.txt).

## 0.9.0

Public Web Ingress adapter. Protocol 1.0 and the C ABI are unchanged.

### Web Ingress

- `rendez-web-ingress` is an additional public Caller: exact hostname routes, TLS-terminated HTTP/1.1, and TLS passthrough to an HTTPS origin.
- One browser connection is one isolated Rendez stream. Keep-alive, chunked, SSE, and WebSocket bytes pass without application parsers.
- Global and per-IP connection limits, ClientHello/handshake and Broker-dial timeouts, idle timeout, SIGTERM drain, `/healthz`, `/readyz`, and `/metrics`.
- Passthrough-only processes need no ingress certificate. Mixed `http` and `tls_passthrough` routes do. The Origin owns the passthrough certificate.

### Demo and deploy

- Five-terminal local demo: `rendez-echo-http` plus [examples/web-ingress/](../examples/web-ingress/).
- systemd unit [deploy/systemd/thirp-web-ingress.service](../deploy/systemd/thirp-web-ingress.service).
- CLI documentation: [web_ingress_cli/README.md](../web_ingress_cli/README.md).

### Release

- `--version` on `rendez-web-ingress` prints project version and protocol 1.0.
- `scripts/release.sh` includes `rendez-web-ingress`, its CLI README, the production example, and the systemd unit in the checksum set.

## 0.8.0

First numbered project version. Covers production-readiness work through PR-8.

### Authorization and roles

- Broker enforces Agent vs Caller opcode permissions before policy.
- Production policy is deny-by-default: namespace registration grants and connect grants.
- Development allow-all remains only when `--policy-mode development` (the flags-only default) or an explicit development config.

### Service lifecycle

- `UNREGISTER` is implemented end-to-end. Absent names are idempotent success.
- One agent session can own multiple services. Reconnect restores the desired set only.
- Deliberate agent shutdown sends `UNREGISTER` for owned names when the connection is still usable.

### Credentials

- Static credentials carry principal, organization, capabilities, optional label and expiry.
- `--token-file` on broker, agent, and caller. Tokens are never logged.
- Production examples use separate least-privilege agent and caller secrets.

### Resilience and operations

- `rendez-connect` reconnects the broker session after transient loss. In-flight local streams still die.
- Agent reconnect classifies permanent vs transient failures.
- `--metrics-listen` serves `/metrics`, `/healthz`, and `/readyz`.
- Auth, register/unregister, and CONNECT attempts are rate limited (`RATE_LIMITED`).
- Global buffered-byte ceiling and optional `--stream-idle-timeout`.
- Broker and agent accept `--config PATH` (line-oriented `key = value`; flags override). systemd units and [OPERATIONS.md](OPERATIONS.md) cover a two-principal, two-service deploy.

### Release

- `--version` on `rendez-broker`, `rendez-agent`, and `rendez-connect` prints project version and protocol 1.0.
- `scripts/release.sh` builds Linux binaries, `librendez.so`, source archive, SPDX SBOM, NOTICE, provenance, and SHA-256 checksums.
- Minimum Odin compiler is `dev-2026-07` ([DEPENDENCIES.md](DEPENDENCIES.md)). The release script refuses an older toolchain.
