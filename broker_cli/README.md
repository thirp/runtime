# thirp-broker

Agents register named services. Authorized Callers connect by name and get a bidirectional byte stream.

Source: `broker_cli/`. Binary name: `thirp-broker`. Thin wrapper over the `broker` package.

## Build

See the native Linux, macOS and Windows instructions. [Building](../docs/BUILDING.md#build-command-line-components)

## Usage

```text
thirp-broker [--version] [--config PATH] --listen HOST:PORT (--token TOKEN=PRINCIPAL[:ORG] | --token-file PATH) ...
              [--tls-cert PATH --tls-key PATH | --insecure]
              [--policy-mode development|production]
              [--capability PRINCIPAL=register|connect]
              [--allow-register PRINCIPAL=PATTERN] [--allow-connect PRINCIPAL=PATTERN]
              [--org-namespace ORG=PATTERN]
              [--max-stream-buffer BYTES] [--max-connection-buffer BYTES]
              [--max-streams-per-session N] [--max-registrations-per-session N]
              [--max-frame-size BYTES] [--max-connections N] [--max-connections-per-ip N]
              [--auth-rate-limit N] [--register-rate-limit N] [--connect-rate-limit N]
              [--max-buffered-bytes BYTES] [--stream-idle-timeout SECONDS]
              [--heartbeat-interval SECONDS] [--session-timeout SECONDS]
              [--shutdown-grace SECONDS] [--metrics-listen HOST:PORT] [--log-level LEVEL]
```

### Config file

`--config PATH` loads a line-oriented `key = value` file. `#` starts a comment. Optional `[section]` lines are ignored. Keys such as `tls_cert`, `allow_register`, and `metrics_listen` use underscores where the flags use hyphens. Repeatable keys append (`token`, `token_file`, `capability`, `allow_register`, `allow_connect`, `org_namespace`).

CLI flags override file values. Required fields may come from either source. After merge, every practical error is printed (`config: line N: …` or `flag: --listen: …`) and the process exits 1 without listening. Unknown keys and duplicate non-repeatable keys fail. `policy_mode = production` cannot be combined with `insecure`. Empty grants in production are valid (deny-all).

Secrets stay in `token_file`, not in the main file. Restart the process to apply configuration changes. To rotate the certificate at its configured path, use the reload procedure. [Production example](../examples/production/broker.conf) · [Certificate rotation](../docs/OPERATIONS.md#certificate-rotation)

`--version` prints the project version, build commit and protocol 1.0, then exits 0.

### Required

| Flag | Meaning |
|---|---|
| `--config PATH` | Optional broker config file. May be set once |
| `--listen HOST:PORT` | Broker listener. Use a numeric IP address |
| `--token TOKEN=PRINCIPAL[:ORG][;...]` | Static credential mapping. Repeatable. At least one `--token` or `--token-file` |
| `--token-file PATH` | File of credential lines (same grammar as `--token`). Repeatable. Prefer mode `0600` |
| `-h`, `--help` | Print usage and exit 0 |

`--tls-cert` and `--tls-key` are required unless `--insecure` is set. Combining `--insecure` with either TLS flag is rejected.

On listen the process prints `thirp-broker listening on HOST:PORT` (plus `(--insecure)` when plaintext).

### Tokens

Line grammar (used by `--token` and each non-comment line of `--token-file`):

```text
TOKEN=PRINCIPAL[:ORG][;capabilities=register|connect][;label=LABEL][;expires=RFC3339]
```

`TOKEN=PRINCIPAL` and `TOKEN=PRINCIPAL:ORG` remain valid. Optional fields may appear in any order. Unknown or duplicate keys are rejected. Token at most 4096 bytes; principal, organization, and label at most 128 bytes. Label charset is `A-Z a-z 0-9 - _ / .`. Duplicate token values are rejected. Two different tokens may map to the same principal (rotation).

`--token-file` is line-oriented: `#` starts a comment line; blank lines are ignored. Max file size 1 MiB. Missing, unreadable, or empty-of-records files fail startup without printing file contents. On Unix, group- or world-readable files print a warning. Use mode `0600` on Unix and a private ACL on Windows.

`--token` remains for development. In `--policy-mode production`, any argv `--token` prints:

```text
WARNING: --token puts the credential in the process listing and shell history. Prefer --token-file.
```

Capabilities on the credential are unioned with `--capability PRINCIPAL=...`. The broker does not infer capabilities from the token value.

The credential store authenticates both Agent and Caller roles. HELLO carries the peer role (`Agent` or `Caller`). Role-invalid opcodes (`Caller` `REGISTER`/`UNREGISTER`, `Agent` `CONNECT`) are `PROTOCOL_ERROR` and close the connection, regardless of policy.

Default `--policy-mode development` allows any authenticated principal to register or connect after the role check. The process prints an unmistakable stderr warning. Do not use development policy on an Internet-reachable host.

`--policy-mode production` is deny-by-default and never falls back to allow-all. A principal needs an explicit capability (on the credential and/or `--capability`) and a matching grant:

```text
--capability host-a=register
--capability client-a=connect
--allow-register host-a=acme/site-17/*
--allow-connect client-a=acme/site-17/reporting-api
--allow-connect client-b=acme/site-17/*
--org-namespace acme=acme/*
```

Patterns are an exact `ServiceId` or a single trailing `/*` prefix. Organization defaults to `org/dev` unless the token spec includes `:ORG`.

Do not log tokens. Expired and unknown credentials both return `AUTHENTICATION_FAILED`.

### Credential rotation

To replace static credentials, follow the rotation procedure.
[Credential rotation](../docs/OPERATIONS.md#credential-rotation)

### TLS and plaintext

| Flag | Meaning |
|---|---|
| `--tls-cert PATH` | Server certificate PEM, leaf first followed by any intermediates |
| `--tls-key PATH` | Server private key PEM |
| `--insecure` | Plaintext TCP. Development only |

TLS 1.2+. For a local cert, the SAN must include the address clients verify (for `127.0.0.1`, `IP:127.0.0.1`):

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout broker.key -out broker.crt \
  -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

For live certificate replacement, follow the reload procedure.
[Certificate rotation](../docs/OPERATIONS.md#certificate-rotation)

### Limits

Unset flags keep the server defaults. Integer flags must be nonnegative. `--max-frame-size` must be in `1..65536`. `--heartbeat-interval` and `--session-timeout` must be `> 0`.

| Flag | Default | Meaning |
|---|---|---|
| `--max-stream-buffer BYTES` | 262144 (256 KiB) | Per-stream outbound queue limit |
| `--max-connection-buffer BYTES` | 8388608 (8 MiB) | Per-connection outbound buffer |
| `--max-streams-per-session N` | 256 | Live streams on one agent session |
| `--max-registrations-per-session N` | 32 | Live `ServiceId`s on one agent session |
| `--max-frame-size BYTES` | 65536 (64 KiB) | Max frame payload |
| `--max-connections N` | 4096 | Physical connections |
| `--max-connections-per-ip N` | 256 | Physical connections from one source IP |
| `--auth-rate-limit N` | 20 | Failed `AUTHENTICATE` per source IP per minute. `0` disables |
| `--register-rate-limit N` | 60 | `REGISTER` + `UNREGISTER` per principal per minute. `0` disables |
| `--connect-rate-limit N` | 600 | `CONNECT` per principal **and** per source IP per minute. `0` disables. Callers behind NAT share the IP bucket; raise this if that is too tight |
| `--max-buffered-bytes BYTES` | 268435456 (256 MiB) | Sum of queued DATA across all connections. New `CONNECT` gets `QUOTA_EXCEEDED`; new accepts are closed. `0` disables |
| `--stream-idle-timeout SECONDS` | 0 (off) | RESET a relay stream with `TIMEOUT` if it has no DATA / HALF_CLOSE / OPEN_OK for this long. `300` is a reasonable production value |

For full outbound queues and stream resets, see [resource limits](../docs/OPERATIONS.md#resource-limits). `/metrics` distinguishes overflow RESET from peer-gone, session `idle_timeout`, per-stream `stream_idle`, and drain. `idle_timeout` on `thirp_resets_total` is **session** idle (no inbound frames for `--session-timeout`). `stream_idle` is the per-relay-stream timeout when `--stream-idle-timeout` is greater than 0.

On Unix, recommended `ulimit -n` is at least `2 * --max-connections + 64` (relay sockets plus metrics/log). If accept fails because the process is out of file descriptors, the broker logs `accept_failed`, increments `thirp_limit_exceeds_total{limit="file_descriptors"}`, and keeps the accept loop running.

### Session and shutdown

| Flag | Default | Meaning |
|---|---|---|
| `--heartbeat-interval SECONDS` | 15 | Broker `PING` interval |
| `--session-timeout SECONDS` | 45 | Idle session timeout. Disconnect removes registrations and RESET live streams |
| `--shutdown-grace SECONDS` | 10 | Maximum Broker wait after sending the drain notice |
| `--log-level LEVEL` | `info` | `error`, `warn`, `info`, or `debug` |

On Linux and macOS, SIGINT or SIGTERM requests a drain. On Windows the
console handler responds to Ctrl+C, Ctrl+Break and console close. The Broker
stops accepting connections and rejects new `REGISTER` and `CONNECT`
requests with `BROKER_DRAINING`. It sends a connection-level
`ERROR/BROKER_DRAINING` notice before waiting. On receipt, the Agent exits its
relay loop and the Caller fails its active streams. `--shutdown-grace` controls
only the Broker's wait before it resets any remaining streams. Transfers can
be interrupted as soon as a client receives the notice.

### Metrics and health

`--metrics-listen HOST:PORT` starts a separate HTTP listener. It is off by default.

| Path | Meaning |
|---|---|
| `GET /metrics` | Prometheus text, `version=0.0.4` |
| `GET /healthz` | Process liveness. `200` `ok` if the thread can answer |
| `GET /readyz` | `200` `ready` while the relay listener is up and the broker is not draining. `503` `draining` during SIGINT/SIGTERM drain. `503` `not_ready` if the management port is up before listen |

Other paths return 404. The socket is unauthenticated and has no TLS. Bind it to localhost or a private network.

```bash
curl -s http://127.0.0.1:9090/metrics
curl -s http://127.0.0.1:9090/healthz
curl -s http://127.0.0.1:9090/readyz
```

Gauges include `thirp_active_physical_connections`, `thirp_active_agent_sessions`, `thirp_active_caller_connections`, `thirp_registered_services`, `thirp_active_relay_streams`. Success counters include `thirp_registrations_total`, `thirp_unregistrations_total`, `thirp_connection_success_total`. Failure counters are labeled with a fixed `reason` or `limit` enum: `thirp_connection_failure_total{reason=...}`, `thirp_authorization_failures_total{reason=...}`, `thirp_registration_failures_total{reason=...}`, `thirp_unregistration_failures_total{reason=...}`, `thirp_resets_total{reason=...}`, `thirp_limit_exceeds_total{limit=...}`. Also `thirp_role_violations_total` and `thirp_session_timeouts_total` (one increment per timed-out session). `thirp_rate_limit_exceeds_total` with `limit` `authentication`, `registration`, or `connect` counts `RATE_LIMITED` replies.

Metric labels are only those fixed enums and histogram `le`. Do not expect `ServiceId`, `PrincipalId`, credential labels, tokens, or source IPs on series. Those belong in structured logs (`session_id`, `stream_id`, `principal_id`, `organization_id`, `service_id`).

Agent reconnect is an agent log (`reconnect_scheduled` plus a class). The broker treats a returning agent as a new session (`session_authenticated` / `service_registered`).

Histograms cover authentication, service lookup, `OPEN_OK`, and `CONNECT_OK` latency.

## Example

TLS:

```bash
./thirp-broker --listen 127.0.0.1:9000 \
  --tls-cert broker.crt --tls-key broker.key \
  --token host-dev-token=host-a \
  --token caller-dev-token=client-a \
  --metrics-listen 127.0.0.1:9090
```

Production policy (deny-by-default; no allow-all path). Put secrets in a `0600` file. Prefer `--config` (see [examples/production/broker.conf](../examples/production/broker.conf) and [OPERATIONS.md](../docs/OPERATIONS.md)):

```bash
./thirp-broker --config /etc/thirp/broker.conf
```

Equivalent flags:

```bash
printf '%s\n' \
  'host-site-17=agent-site-17:acme;capabilities=register;label=site-17-agent' \
  'reporting-client=reporting-client:acme;capabilities=connect;label=reporting-client' \
  > broker.tokens
chmod 600 broker.tokens

./thirp-broker --listen 127.0.0.1:9000 \
  --tls-cert broker.crt --tls-key broker.key \
  --policy-mode production \
  --token-file broker.tokens \
  --org-namespace acme=acme/* \
  --allow-register agent-site-17=acme/site-17/* \
  --allow-connect reporting-client=acme/site-17/reporting-api
```

Plaintext:

```bash
./thirp-broker --insecure --listen 127.0.0.1:9000 \
  --token host-dev-token=host-a \
  --token caller-dev-token=client-a
```

## See also

- [BUILDING.md](../docs/BUILDING.md) - building, testing, and packaging
- [agent_cli/README.md](../agent_cli/README.md) — register a local target
- [caller_cli/README.md](../caller_cli/README.md) — local listen that dials a service
- [OPERATIONS.md](../docs/OPERATIONS.md) — deploy, systemd, backup
- [PROTOCOL.md](../docs/PROTOCOL.md) — wire format
- [Quickstart](../docs/QUICKSTART.md) — local relay demo
