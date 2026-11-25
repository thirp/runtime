# Operations

Deploy and run a self-hosted Thirp Runtime broker. The systemd and container examples below use Linux.

Configuration files, systemd units, and a container example live in the repository:

```text
examples/production/     broker.conf, agent.conf, web-ingress.conf, token files
examples/web-ingress/    local five-terminal demo (loopback TLS)
deploy/systemd/          thirp-broker.service, thirp-agent.service, thirp-web-ingress.service
deploy/container/        Dockerfile for a pre-built broker binary
```

For binary downloads and native builds, see [Building](BUILDING.md).

## TLS

The broker terminates TLS. Use TLS with `policy_mode = production`.

Runtime sets the minimum to TLS 1.2 and uses OpenSSL's default cipher policy.

The certificate SAN must include the name or address clients verify. For a local test with `127.0.0.1`:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout /etc/thirp/broker.key -out /etc/thirp/broker.crt \
  -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

On a public host, use a certificate whose SAN matches the hostname in the agent/caller `broker` address (or set `tls_server_name`). Agents and callers verify the server certificate by default. `--tls-ca` points at a PEM CA file; omit it to use the system CA bundle.

## Configuration

Broker and agent accept `--config PATH`. CLI flags override file values. Required fields may come from either source. Unknown keys, duplicate non-repeatable keys, and validation errors are reported together, then the process exits 1 without listening.

Format: line-oriented `key = value`. `#` starts a comment line. Optional `[section]` lines are ignored. Repeatable keys (`token_file`, `allow_register`, `allow_connect`, `org_namespace`, agent `map`, …) append.

Secrets do not belong in the main file. Use `token_file = PATH` and keep that file mode `0600`. `token = ...` remains for development and prints a warning in production.

The Broker defaults to `development` policy even when a configuration file is supplied. Set `policy_mode = production` explicitly for deny-by-default access.

See the command references for input and defaults. [Broker](../broker_cli/README.md) · [Agent](../agent_cli/README.md) · [Caller](../caller_cli/README.md) · [Web Ingress](../web_ingress_cli/README.md)

## Production walkthrough

Goal: a TLS broker, two differently privileged principals, one agent with two services, one caller that can reach only one of those services. Copy [examples/production/](../examples/production/) and replace placeholders. Do not use the `change-me-` secrets.

```text
/etc/thirp/
  broker.conf
  broker.tokens      # mode 0600
  broker.crt
  broker.key         # mode 0600
  agent.conf
  agent.token        # mode 0600
```

`broker.tokens` (broker credential list):

```text
<agent-secret>=agent-site-17:acme;capabilities=register;label=site-17-agent
<caller-secret>=reporting-client:acme;capabilities=connect;label=reporting-client
```

`broker.conf` (see the example file):

```text
listen = 0.0.0.0:8443
tls_cert = /etc/thirp/broker.crt
tls_key = /etc/thirp/broker.key
policy_mode = production
token_file = /etc/thirp/broker.tokens
metrics_listen = 127.0.0.1:9090
org_namespace = acme=acme/*
allow_register = agent-site-17=acme/site-17/*
allow_connect = reporting-client=acme/site-17/reporting-api
```

`agent.conf`:

```text
broker = broker.example:8443
token_file = /etc/thirp/agent.token
tls_ca = /etc/thirp/broker.crt
map = acme/site-17/reporting-api=127.0.0.1:7000
map = acme/site-17/inventory=127.0.0.1:7001
```

Replace `broker.example` with the address the agent actually dials. `agent.token` contains only the raw agent secret (one line).

Legacy caller (flags only), permitted for `reporting-api` and denied for `inventory`:

```bash
printf '%s\n' '<caller-secret>' > /etc/thirp/caller.token
chmod 600 /etc/thirp/caller.token
thirp-connect --broker broker.example:8443 --tls-ca /etc/thirp/broker.crt \
  --token-file /etc/thirp/caller.token \
  --service acme/site-17/reporting-api \
  --listen 127.0.0.1:8000
```

Empty grants in production are valid (deny-all). Malformed grants fail startup; the broker never falls back to allow-all.

## Secrets

- Prefer `--token-file` / `token_file`. Do not put long-lived secrets on the command line.
- Broker token file: line grammar `TOKEN=PRINCIPAL[:ORG][;capabilities=...][;label=...][;expires=RFC3339]`. Agent and caller token files: raw secret only.
- On Unix, use mode `0600` for token files. On Windows, restrict access with file ACLs. Enrolled callers enforce private access on both input files. [Caller enrollment](../caller_cli/README.md#caller-enrollment)
- Tokens never appear in logs.

## Bind addresses

- Relay listen (`listen`) is the public switchboard port (example: `0.0.0.0:8443`).
- Metrics/health (`metrics_listen`) is a separate plaintext HTTP socket with no authentication. Bind `127.0.0.1` or a management network. Do not expose it on the public internet.
- `/metrics`, `/healthz`, and `/readyz` share that one socket. There is no second management port.
- `thirp-connect --listen` (legacy mode) or each `listen` address in `caller.conf` controls who on the caller host can use the bridge. Examples use `127.0.0.1`. Binding all interfaces prints a warning.

## Health and metrics

```bash
curl -s http://127.0.0.1:9090/healthz   # 200 ok
curl -s http://127.0.0.1:9090/readyz    # 200 ready, or 503 draining / not_ready
curl -s http://127.0.0.1:9090/metrics
```

If `metrics_listen` is omitted, there is no health or metrics endpoint. systemd units do not use `Type=notify`; point a checker at `/healthz` and `/readyz`.

Metric labels are fixed enums only. `ServiceId`, `PrincipalId`, tokens, and source IPs belong in structured logs, not Prometheus labels.

## systemd

Example units: [deploy/systemd/](../deploy/systemd/).

```bash
useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin thirp
install -d -o root -g thirp -m 0750 /etc/thirp
# install binaries, conf, tokens (0600), certs
install -m 0644 deploy/systemd/thirp-broker.service /etc/systemd/system/
install -m 0644 deploy/systemd/thirp-agent.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now thirp-broker
systemctl enable --now thirp-agent
```

The examples listen on **8443** so the unit does not need `CAP_NET_BIND_SERVICE`. `LimitNOFILE=8256` is `2 * 4096 + 64` (default `--max-connections` plus metrics/log). Do not add `PrivateNetwork=yes`; the agent must dial the broker and local targets, and the broker must accept relay TLS.

## Container

Optional. [deploy/container/Dockerfile](../deploy/container/Dockerfile) copies a **pre-built** `thirp-broker`, runs as uid 10001, and expects `/etc/thirp/broker.conf`. It is not the only supported deployment.

The example `metrics_listen = 127.0.0.1:9090` is not reachable from outside the container. For scraping, set `metrics_listen = 0.0.0.0:9090` and publish that port only on a private network.

## Logs

The processes log structured JSON to stderr (journald under systemd). There is no application log file. Use journal rotation (`SystemMaxUse=` in journald, or your existing log pipeline).

Do not log tokens or application payloads. Correlate with `session_id`, `stream_id`, `principal_id`, `organization_id`, and `service_id`.

## Resource limits

Read the limits and defaults in the command references.
[Broker limits](../broker_cli/README.md#limits) · [Agent options](../agent_cli/README.md#usage) · [Caller options](../caller_cli/README.md#usage)

A full destination queue can make the Broker wait while it checks for
progress. During caller-to-agent backpressure it can read ahead and respond
to heartbeats. If the caller input is also saturated and the Broker cannot
read ahead, it can reset the affected stream while keeping the session.
On the receiving side, the Caller and Agent also reset individual streams
that overrun their local buffers.

## Startup and shutdown

Startup validates configuration, loads TLS and credentials, then listens. Development policy and argv `--token` in production print warnings on stderr.

During a Broker drain, `/readyz` returns `503 draining`. See how to request
a drain on your platform. [Broker shutdown](../broker_cli/README.md#session-and-shutdown)

## Credential rotation

Broker restart is required to change the credential set.

1. Add the replacement token line (same principal) to the broker token file.
2. Restart the broker (`systemctl restart thirp-broker`).
3. Update the Agent or legacy Caller token file, restart that client, and confirm it authenticates. The running processes keep their startup tokens in memory.
4. Remove the old token line and restart the broker again.

Two different token values may map to the same principal (overlapping validity). Duplicate token values are rejected.

## Certificate rotation

1. Install the new unencrypted PEM certificate chain (leaf first, then intermediates in issuer order) and matching unencrypted PEM key at the configured `tls_cert` and `tls_key` paths. The chain must permit TLS server authentication. The root certificate is optional. For reload, each path must resolve to a regular file of at most 1 MiB. The certificate file must contain complete PEM certificate blocks, with only whitespace outside the blocks. The chain can use LF or CRLF line endings. Finish replacing both files before requesting reload. Keep a backup of the previous pair for rollback.
2. Write a fresh 32-digit hexadecimal request ID followed by LF or CRLF to the regular file at the configured certificate path with `.reload` appended. Use a regular request file directly at that path.

   **Linux and macOS**

   ```bash
   openssl rand -hex 16 > /etc/thirp/broker.crt.reload
   ```

   **Windows PowerShell**

   ```powershell
   Set-Content -LiteralPath 'C:\Thirp\broker.crt.reload' -Encoding ascii -Value ([Guid]::NewGuid().ToString('N'))
   ```

3. The Broker checks the request file once a second. It acts on a complete ID that differs from the last one it read. A successful attempt logs `tls_reloaded` at info level. A rejected attempt logs `tls_reload_failed` at error level and keeps serving the previous certificate. Correct the PEM files and write a new ID to retry. Wait for the attempt to complete before issuing another request.

The request file can stay in place between rotations and across restarts. Give the broker account read access and restrict write access to trusted operators.

New TLS handshakes use the replacement chain after success, and established sessions and streams continue. Agents and callers can reuse their configurations on reconnect when the new certificate matches the configured name and trust roots. To roll back, restore both previous PEM files and write a fresh request ID.

## Backup and restore

Do not back up live registrations. They disappear when the agent session dies and come back when agents reconnect.

Back up:

```text
broker.conf, agent.conf
broker.tokens, agent.token, caller.token
TLS certificate and key (per your PKI policy)
```

Restore: put the files back, start the broker, start agents. Agents re-register the desired service set.

## Upgrade

A single-broker restart interrupts active sessions. There is no zero-downtime broker upgrade. Protocol and config compatibility: [COMPATIBILITY.md](COMPATIBILITY.md). User-visible changes: [CHANGELOG.md](CHANGELOG.md).

Download the platform archive and verify it before install.
[Release archives](BUILDING.md#release-archives) · [Archive verification](BUILDING.md#verify-a-downloaded-tree)

1. Install the new binaries.
2. Restart the broker (drain, then exit).
3. Restart agents if their binary also changed. They reconnect and re-register.

Breaking configuration changes will be called out in [CHANGELOG.md](CHANGELOG.md). Do not silently reinterpret a security rule.

## Failure modes and triage

Use logs and labeled metrics. Packet capture is not required to distinguish these:

| Symptom | Where to look |
|---|---|
| Bad or expired token | `auth_failed`, `thirp_authentication` latency; wire `AUTHENTICATION_FAILED` |
| Caller cannot REGISTER | role violation (`thirp_role_violations_total`); connection closed |
| Agent cannot CONNECT | same |
| Missing service | `connection_failure_total{reason=service_not_found}` |
| Policy deny | `authorization_failures_total`, `UNAUTHORIZED` |
| Local target down | `OPEN_FAILED` / `LOCAL_SERVICE_UNAVAILABLE`; agent session stays up |
| Rate limited | `rate_limit_exceeds_total`; `RATE_LIMITED` is transient, not a bad token |
| Resource cap | `limit_exceeds_total`, `QUOTA_EXCEEDED`, stream RESET |
| Broker draining | `readyz` 503, `BROKER_DRAINING` |
| Session idle | `session_timeouts_total`; registration removed |
| Stream idle | `resets_total{reason=stream_idle}` when `stream_idle_timeout` > 0 |
| FD exhaustion | `accept_failed`, `limit_exceeds_total{limit="file_descriptors"}` |

For a closed Agent link, inspect the Agent's `disconnected.close_cause` and
the Broker's `session_closed.reason`. Examples include `peer_eof`,
`peer_reset`, `tls_alert` and `read_deadline`. The Broker uses `idle_timeout`
for its session-idle deadline. The Agent's `reconnect_scheduled.reason`
classifies the retry separately. [Agent behavior](../agent_cli/README.md#behavior)

## Session recovery

A Caller tries to queue a Ping after 15 seconds without an inbound frame
and at least 15 seconds since its last Ping. Each complete inbound frame
refreshes the receive timer. After 45 seconds of inbound silence, the
receive watchdog closes the session with `dead_peer`. Send stalls and socket
failures can also end a session. A legacy Caller can recycle a session after
45 seconds with no open streams or outstanding dials, including replies it
still expects after a dial has timed out. Enrolled Callers keep healthy
sessions admitted while idle.

An Agent reconnects and re-registers its desired services. The Broker
removes the old session's registrations when that session closes. A legacy
Caller reconnects using its startup credential. An enrolled Caller manages
grant, credential and session replacement through its enrollment file.
[Caller enrollment](../caller_cli/README.md#caller-enrollment)

Streams on a lost session end. Once the service is registered and the Caller
is admitted again, a new connection opens a new stream. During rollover a
healthy enrolled session can drain existing streams until they finish or
the grant ends.

## Web Ingress

`thirp-web-ingress` runs as a separate Caller process on Linux and macOS.

See the Web Ingress command reference for [route setup](../web_ingress_cli/README.md#routes).

The public hostname is a locator, not a secret. Anyone who can complete TLS to that host reaches the Origin. **The Origin Application must authenticate users** unless it is intentionally public. Configure the Origin to accept the public `Host` / SNI. Web Ingress does not rewrite `Host` and does not add `Forwarded` / `X-Forwarded-*`.

A process with only `tls_passthrough` routes does not need an ingress certificate. Mixed `http` and `tls_passthrough` routes do. Passthrough failures before the Origin completes TLS close the TCP connection; they do not write an HTTP error with the ingress certificate. See the commented passthrough route in [examples/production/web-ingress.conf](../examples/production/web-ingress.conf).

For a terminated HTTP route, an absent Service or unavailable local target returns `503`. After sending an HTTP error, Web Ingress half-closes its write side and drains up to 64 KiB or 250 ms of remaining request data so the browser can receive the response.

Copy [examples/production/web-ingress.conf](../examples/production/web-ingress.conf) and [examples/production/web-ingress.token.example](../examples/production/web-ingress.token.example). Use a dedicated Ingress Principal (`ConnectService` only). The production Broker example grants `web-ingress-a` exactly `acme/site-17/portfolio-ui`.

```text
/etc/thirp/
  web-ingress.conf
  web-ingress.token          # mode 0600
  web-ingress-fullchain.pem
  web-ingress-key.pem        # mode 0600
```

Public listen and management listen stay separate. Production `metrics_listen` should be loopback or a protected network:

```bash
curl -sS http://127.0.0.1:9190/healthz
curl -sS http://127.0.0.1:9190/readyz
curl -sS http://127.0.0.1:9190/metrics
```

`/healthz` is process liveness. `/readyz` is false while the public listener is down, required TLS context is missing, the Caller session is unusable, or the process is draining. One unavailable Origin does not make the whole process unready.

See the Web Ingress command reference for
[limits](../web_ingress_cli/README.md#limits) and
[drain behavior](../web_ingress_cli/README.md#metrics-and-health).

systemd unit: [deploy/systemd/thirp-web-ingress.service](../deploy/systemd/thirp-web-ingress.service). Same user and hardening as the broker unit, plus `CAP_NET_BIND_SERVICE` when `listen` is port 443. SIGTERM is the drain path. A reverse proxy is not required.

For a loopback deployment to try locally, see the
[Web Ingress demo](../web_ingress_cli/README.md#local-demo).

Threat model: [SECURITY.md](SECURITY.md).
