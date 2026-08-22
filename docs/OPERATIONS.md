# Operations

How to deploy and run a self-hosted Thirp Runtime broker. This document is for an operator who did not write the software.

The open-source release is **production-capable self-hosted infrastructure**. It is not a globally distributed service, not high availability, and not an externally assessed security product. Live service registrations are ephemeral: they exist only while the owning agent session is connected.

Configuration files, systemd units, and a container example live in the repository:

```text
examples/production/     broker.conf, agent.conf, web-ingress.conf, token files
examples/web-ingress/    local five-terminal demo (loopback TLS)
deploy/systemd/          thirp-broker.service, thirp-agent.service, thirp-web-ingress.service
deploy/container/        Dockerfile for a pre-built broker binary
```

`thirp-connect` has no config file. Use flags and `--token-file`. `thirp-web-ingress` accepts `--config` or flags.

Process restart is the supported way to change configuration. There is no SIGHUP reload.

## Dependencies

Linux, [Odin](https://odin-lang.org/) `dev-2026-07` or later, and OpenSSL 3 (`libssl` / `libcrypto`). See [DEPENDENCIES.md](DEPENDENCIES.md).

```bash
odin build broker_cli -out:thirp-broker
odin build agent_cli -out:thirp-agent
odin build caller_cli -out:thirp-connect
odin build web_ingress_cli -out:thirp-web-ingress
odin build echo_http_cli -out:thirp-echo-http
```

Install the binaries where the systemd units expect them, default `/usr/local/bin/`.

## TLS

TLS is required unless `--insecure` or `insecure = true` is set. Production policy (`policy_mode = production`) cannot be combined with insecure. The broker terminates TLS itself; a reverse proxy is not required.

Minimum version is TLS 1.2, inherited from OpenSSL. Cipher policy is the library default.

The certificate SAN must include the name or address clients verify. For a local test with `127.0.0.1`:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout /etc/thirp/broker.key -out /etc/thirp/broker.crt \
  -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

On a public host, use a certificate whose SAN matches the hostname in the agent/caller `broker` address (or set `tls_server_name`). Agents and callers verify the server certificate by default. `--tls-ca` points at a PEM CA file; omit it to use the system CA bundle.

Hot reload of certificates is not implemented. Replace the PEM files and restart the broker. Drain (SIGINT/SIGTERM) lets existing streams finish within `shutdown_grace` (default 10s).

## Configuration

Broker and agent accept `--config PATH`. CLI flags override file values. Required fields may come from either source. Unknown keys, duplicate non-repeatable keys, and validation errors are reported together, then the process exits 1 without listening.

Format: line-oriented `key = value`. `#` starts a comment line. Optional `[section]` lines are ignored. Repeatable keys (`token_file`, `allow_register`, `allow_connect`, `org_namespace`, agent `map`, …) append.

Secrets do not belong in the main file. Use `token_file = PATH` and keep that file mode `0600`. `token = ...` remains for development and prints a warning in production.

Flags-only launch (no `--config`) is unchanged: `--policy-mode` defaults to `development` (allow-all after a successful role check) and prints a stderr warning.

Key names are the flag names without `--`, with hyphens turned into underscores. Full flag lists: [broker_cli/README.md](../broker_cli/README.md), [agent_cli/README.md](../agent_cli/README.md).

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

Caller (flags only), permitted for `reporting-api` and denied for `inventory`:

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
- Mode `0600`. Group- or world-readable token files print a warning; the process still starts.
- Tokens never appear in logs.

## Bind addresses

- Relay listen (`listen`) is the public switchboard port (example: `0.0.0.0:8443`).
- Metrics/health (`metrics_listen`) is a separate plaintext HTTP socket with no authentication. Bind `127.0.0.1` or a management network. Do not expose it on the public internet.
- `/metrics`, `/healthz`, and `/readyz` share that one socket. There is no second management port.
- `thirp-connect --listen` controls who on the caller host can use the bridge. Examples use `127.0.0.1`. Binding all interfaces prints a warning.

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

Defaults (override in the broker config or flags):

| Limit | Default |
|---|---|
| Per-stream outbound buffer | 256 KiB |
| Per-connection outbound buffer | 8 MiB |
| Global buffered DATA | 256 MiB |
| Streams per agent session | 256 |
| Registrations per agent session | 32 |
| Frame payload | 64 KiB |
| Physical connections | 4096 |
| Connections per source IP | 256 |
| Failed AUTHENTICATE / IP / minute | 20 |
| REGISTER+UNREGISTER / principal / minute | 60 |
| CONNECT / principal and IP / minute | 600 |
| Stream idle timeout | 0 (off). Production recommendation: 300 |
| Session idle timeout | 45 s |
| Shutdown grace | 10 s |

`ulimit -n` (and `LimitNOFILE`) should be at least `2 * max_connections + 64`. If accept fails because the process is out of file descriptors, the broker logs `accept_failed`, increments `thirp_limit_exceeds_total{limit="file_descriptors"}`, and keeps running.

Sizing is workload-dependent. Start with the defaults on a single host and raise connection/buffer caps after measuring. Do not treat these numbers as a capacity claim.

## Startup and shutdown

Startup validates configuration, loads TLS and credentials, then listens. Development policy and argv `--token` in production print warnings on stderr.

SIGINT/SIGTERM: stop accepts, reject new REGISTER/CONNECT with `BROKER_DRAINING`, wait `shutdown_grace` for live streams, RESET what remains, exit. `/readyz` returns `503 draining` during this window.

A deliberate agent stop UNREGISTERs owned services (best effort), RESET remaining streams, and does not reconnect. Broker session teardown is the cleanup guarantee if unregister does not complete.

## Credential rotation

Broker restart is required to change the credential set.

1. Add the replacement token line (same principal) to the broker token file.
2. Restart the broker (`systemctl restart thirp-broker`).
3. Deploy the new secret to the agent or caller token file and confirm it authenticates.
4. Remove the old token line and restart the broker again.

Two different token values may map to the same principal (overlapping validity). Duplicate token values are rejected.

## Certificate rotation

1. Install the new certificate and key (keep the old files until the new ones load).
2. Restart the broker. Drain drops sessions that outlive `shutdown_grace`.
3. Agents reconnect and re-register. Callers reconnect the broker session; in-flight local streams still die.

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

Release trees from `scripts/release.sh` include Linux binaries, `libthirp.so`, a source archive, an SPDX SBOM, `NOTICE`, `PROVENANCE.txt`, and `SHA256SUMS`. Verify `SHA256SUMS` before install.

1. Install the new binaries.
2. Restart the broker (drain, then exit).
3. Restart agents if their binary also changed. They reconnect and re-register.
4. `thirp-connect` reconnects the broker session after transient loss; lost local sockets still close.

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

Agent reconnect logs `reason`: `network`, `broker_unavailable`, `tls`, `authentication`, `authorization`, `duplicate_registration`, `configuration`, `rate_limited`, `disconnected`. Authentication, authorization, and configuration failures use the long backoff cap.

## Web Ingress

`thirp-web-ingress` is a separate public process. It is a Caller, not an Agent. It does not register services and does not drain the Broker.

A normal Thirp Runtime registration is not browser-reachable until all of these are true: the Agent is registered, an exact public-host route exists, the Ingress Principal has an exact Broker `allow_connect` grant, and Web Ingress is ready.

The public hostname is a locator, not a secret. Anyone who can complete TLS to that host reaches the Origin. **The Origin Application must authenticate users** unless it is intentionally public. Configure the Origin to accept the public `Host` / SNI. Web Ingress does not rewrite `Host` and does not add `Forwarded` / `X-Forwarded-*`.

A process with only `tls_passthrough` routes does not need an ingress certificate. Mixed `http` and `tls_passthrough` routes do. Passthrough failures before the Origin completes TLS close the TCP connection; they do not write an HTTP error with the ingress certificate. See the commented passthrough route in [examples/production/web-ingress.conf](../examples/production/web-ingress.conf).

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

SIGINT/SIGTERM: mark draining (`/readyz` 503), stop accepts, reject connections that have not finished route selection, stop new CONNECT, wait `shutdown_grace` (default 15s) for established streams, then close what remains. Web Ingress does not request Broker-wide drain.

| Limit | Default |
|---|---|
| Browser connections | 4096 |
| Browser connections per source IP | 64 |
| Maximum ClientHello bytes | 65536 |
| ClientHello / TLS handshake timeout | 10 s (cannot be 0) |
| Broker service-dial timeout | 10 s (cannot be 0) |
| Established idle timeout | 300 s (`0` disables idle only) |
| Shutdown grace | 15 s |

`ulimit -n` should be at least `2 * max_connections + 64`. A hostile client that holds sockets open is rejected at the configured cap; it must not create unbounded memory, pending handshakes, or Broker CONNECT work.

systemd unit: [deploy/systemd/thirp-web-ingress.service](../deploy/systemd/thirp-web-ingress.service). Same user and hardening as the broker unit, plus `CAP_NET_BIND_SERVICE` when `listen` is port 443. SIGTERM is the drain path. A reverse proxy is not required.

### Local check and failure behavior

Run the five-terminal demo from the repository root ([examples/web-ingress/](../examples/web-ingress/), [README.md](../README.md)). Open the URL with `curl` (and a browser if you add `portfolio.demo.test` to `/etc/hosts`):

```bash
curl --cacert examples/web-ingress/web-ingress.crt \
  --resolve portfolio.demo.test:9443:127.0.0.1 \
  https://portfolio.demo.test:9443/invite/demo
```

Then:

1. Stop the Agent. New requests return `503`. In-flight streams close. They are not replayed.
2. Start the Agent again. It re-registers. New connections succeed. Old ones stay dead.
3. Remove the Ingress Principal `allow_connect` grant and restart the Broker (drain). New requests return `403`.
4. Remove the route from `web-ingress.conf` and SIGTERM/restart Web Ingress. That hostname is unpublished. Unknown SNI does not dial another service.

A Broker process kill drops the Caller session. `/readyz` goes false until Web Ingress reconnects. In-flight browser connections die. Later connections work after Agent re-register and Caller reconnect.

### Qualification

In-process tests in `web_ingress/qualify_test.odin` measured:

- 20 sequential GET/close cycles; `connections_total{ok}` increased by 20; `active_conns`, slot, and per-IP maps returned to zero
- 8 concurrent GETs on one route with no cross-talk, then the same leak check
- Slow-writer backpressure next to a fast sibling, then idle
- Agent loss, Caller session loss, and Web Ingress restart: in-flight fails, later GET succeeds

Those numbers are measured results on the machine that ran the suite. They are not a capacity claim. The configured 4096 connection cap was not load-tested.

Threat model: [SECURITY.md](SECURITY.md).

## Known limitations

- One broker process. Restart drops sessions.
- No SIGHUP; edit files and restart.
- No caller config file.
- Metrics/health HTTP has no TLS and no authentication.
- This tree does not claim an external security assessment. See [SECURITY.md](SECURITY.md).
