# Changelog

Project version is independent of the wire protocol version. This tree speaks protocol 1.0. See [COMPATIBILITY.md](COMPATIBILITY.md).

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
