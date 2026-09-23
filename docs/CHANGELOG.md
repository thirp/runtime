# Changelog

Project version is independent of the wire protocol version. This tree speaks protocol 1.0. See [COMPATIBILITY.md](COMPATIBILITY.md).

## Unreleased

`dataplane-release` builds macOS **x86_64 (Intel)** on `macos-15-intel` in addition to arm64 (`macos-latest`) and Windows. Output trees are `dist/thirp-runtime-macos-<arch>-<VERSION>/`. Intel archive is published on [v0.16.3-dataplane-unsigned-mac-intel](https://github.com/thirp/runtime/releases/tag/v0.16.3-dataplane-unsigned-mac-intel) without bumping `VERSION.txt`; [v0.16.3-dataplane-unsigned](https://github.com/thirp/runtime/releases/tag/v0.16.3-dataplane-unsigned) stays the arm64 / Windows / Linux dataplane drop. Embed SDK tarball still Linux `.so` only; operator/Broker stack remains Linux-primary; OS-level signing not claimed.

Windows dataplane link: `system:libssl.lib` / `system:libcrypto.lib` and `LIB` search under `OPENSSL_ROOT_DIR` / `C:\Program Files\OpenSSL` (OpenSSL 4). `build_windows.bat` unknown-mode echo no longer uses parentheses (cmd.exe `exit /b 1` trap). CI finds `vcvars64.bat` via vswhere, not hardcoded VS 2022 paths. CI Odin pin restored to `dev-2026-07` (docs floor / last successful dataplane publish). The 2026-09 bump and Darwin `_odin_entry_point` stub were agent-only; a compiler move is backlog.

Caller no longer RESET finished or unknown streams. Broker delivers terminal CLOSE/RESET after dropping leftover DATA (fixes CLOSE-delivery / stuck agent fds). Broker rate-limits `STREAM_NOT_FOUND` stream_reset Info logs. Agent no longer RESET finished or unknown streams. Broker outbox cleanup on stream termination. macOS and Windows CLIs, C ABI libraries, and automated data-plane release packaging. Protocol 1.0 unchanged.

- **Caller + Broker**: Post-stop idle RESET storm after PR #4. Two remaining bugs, no protocol change. (1) `conn_handle_stream_frame` called `server_drop_stream_queues` *after* enqueueing the terminal CLOSE/RESET/second HALF_CLOSE, so the peer never got the frame. Agent origin fds stayed open (N=256 → ~258 stuck). (2) Caller still echoed `RESET` / `STREAM_NOT_FOUND` on DATA / HALF_CLOSE / CLOSE / RESET for a stream `conn_close` had already removed — same ping-pong PR #4 stopped on the agent (~383k `stream_not_found`/s, broker RSS 121→2749 MiB / 5 min). Fix: drop leftover DATA first, then enqueue the terminal frame, then `relay_drop_stream`. Caller ignores unknown/finished stream frames. Regression: N=32 Caller `conn_destroy` burst then idle — `resets_total{reason=stream_not_found}` stays flat and echo origin conns return to 0. Broker test: caller CLOSE is readable on the agent after queued DATA.
- **Broker**: `stream_reset` Info for `STREAM_NOT_FOUND` is rate-limited to one line per `STREAM_NOT_FOUND_LOG_WINDOW` (1s). A RESET flood still increments `thirp_resets_total{reason=stream_not_found}` on every reply; it no longer allocates a log line per RESET (~23 GiB / 5 min and ~60 B/RESET heap at ~288k/s).

- **Agent**: DATA / HALF_CLOSE for a finished or unknown `stream_id` no longer emit `RESET` / `STREAM_NOT_FOUND`. `agent_finish_stream` shuts down the origin socket before destroy so the local pump leaves `recv`. Write-failure RESET is sent only while the agent still owns the stream. Broker queue drop (PR #3) did not stop the idle storm because the agent kept initiating; remeasure after that fix was ~288k `stream_not_found` RESET/s and ~258 stuck agent fds. Regression: N=64 echo burst then idle — `resets_total{reason=stream_not_found}` stays flat.
- **Broker**: Overflow, stream-idle, grant-expiry, and abort now call `server_drop_stream_queues` before enqueueing the terminal RESET and `relay_drop_stream`. PR #3 missed those four `conn.odin` drop paths; leftover DATA/HalfClose on either outbox could still be written after the stream table entry was gone.
- **Broker**: Fixed agent RESET hot-loop leak. Streams reaching terminal state now call `server_drop_stream_queues` before `relay_drop_stream` to clear any queued frames, preventing the broker from sending DATA/HalfClose to agents for already-dropped stream_ids. Without this, agents responded with RESET+StreamNotFound, broker enqueued RESET back, creating a hot loop (~288k RESET/s, unbounded RSS growth).
- macOS: `thirp-broker`, `thirp-agent`, `thirp-connect`, `thirp-web-ingress` CLIs and `libthirp.dylib`
- Windows: same CLIs plus `libthirp.dll`
- Platform-specific TLS socket wait: `core:sys/windows` WSAPoll (Windows POLLIN/POLLOUT/POLLERR/POLLHUP/POLLNVAL) on Windows, poll on POSIX
- Windows TCP peek uses winsock `recv`/`MSG_PEEK`; `SO_RCVLOWAT` is a no-op (not a TCP option there)
- Windows ROOT certificate store for TLS client verification via `CertOpenSystemStoreW`
- macOS TLS falls back to `/etc/ssl/cert.pem` when Homebrew OpenSSL default paths are empty
- Windows Ctrl-C/console close handling via SetConsoleCtrlHandler
- Portable temp file paths in tests respect TEMP/TMP/TMPDIR environment variables
- Build scripts: `scripts/build_macos.sh` and `scripts/build_windows.bat` (`dataplane` mode for Agent/Caller/`libthirp` only)
- Data-plane release packaging: `scripts/release_macos.sh`, `scripts/release_windows.ps1`, checksums, provenance, optional GPG. GitHub Actions workflow `.github/workflows/dataplane-release.yml` builds those trees on `macos-latest` (arm64), `macos-15-intel` (x86_64), and `windows-latest`. Unsigned multi-OS dataplane packaging is automated. Apple Developer ID (`THIRP_MACOS_CODESIGN_IDENTITY`) and Authenticode (`THIRP_WINDOWS_PFX`) remain Chuck-supplied secrets.
- Documentation: BUILDING.md, README.md, DEPENDENCIES.md, COMPATIBILITY.md, SECURITY.md updated for cross-platform release and verification
- Agent and broker CLI signal handling split into `interrupt_{linux,darwin,windows}.odin`
Agent stream cleanup on broker write failure. Protocol 1.0, the C ABI, and the Agent/Caller SDK surface are unchanged.

- `agent_pump_local` sends RESET and calls `agent_finish_stream` when DATA write to broker fails, preventing wedged streams. Matches cleanup pattern used for OpenOk write failures (line 230).
- Transport `Connection.send_timeout` / `connection_set_send_timeout`: TLS WANT_WRITE polls no longer reuse `recv_timeout`. Agent relay keeps 50ms read polling for heartbeats but DATA writes block on peer window (send_timeout=0), so backpressure is not turned into RESET storms.
- Agent OPEN is dialed on a worker thread (`agent_open_worker`) so the relay reader is not stalled behind `connection_dial` while other streams' DATA/control arrive.
- Agent DATA to local: on `connection_write` failure, send RESET and `agent_finish_stream` (was ignored). Local dials get a 5s send timeout to bound reader HOL if the target stops reading.

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
