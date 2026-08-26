# thirp-web-ingress

Public HTTPS listener that reaches a registered HTTP or HTTPS origin through the existing Broker as a Caller. The browser is not a Version 1 peer. `thirp-connect` remains the loopback bridge.

Source: `web_ingress_cli/`. Binary name: `thirp-web-ingress`. Thin wrapper over the `web_ingress` package.

## Build

Requires [Odin](https://odin-lang.org/) and OpenSSL 3. See [DEPENDENCIES.md](../docs/DEPENDENCIES.md).

```bash
odin build web_ingress_cli -out:thirp-web-ingress
```

## Usage

```text
thirp-web-ingress [--version] [--config PATH] --listen HOST:PORT --broker HOST:PORT
                   (--token TOKEN | --token-file PATH) --route HOST=SERVICE_ID[:MODE] ...
                   [--tls-cert PATH --tls-key PATH | --insecure]
                   [--tls-ca PATH] [--tls-server-name NAME | --insecure-broker]
                   [--max-connections N] [--max-connections-per-ip N]
                   [--max-client-hello-bytes BYTES] [--client-hello-timeout SECONDS]
                   [--broker-dial-timeout SECONDS] [--idle-timeout SECONDS]
                   [--shutdown-grace SECONDS] [--metrics-listen HOST:PORT] [--log-level LEVEL]
```

### Config file

`--config PATH` loads a line-oriented `key = value` file. `#` starts a comment. Optional `[section]` lines are ignored. Keys are the flag names without `--` (`tls_cert`, `token_file`, `metrics_listen`, …). Repeatable `route` lines append.

CLI flags override file values. Required fields may come from either source. After merge, every practical error is printed and the process exits 1 without listening. Unknown keys and duplicate non-repeatable keys fail.

Exactly one of `token` or `token_file` is required. Secrets stay in `token_file`, not in the main file. Example: [examples/production/web-ingress.conf](../examples/production/web-ingress.conf). Operator walkthrough: [OPERATIONS.md](../docs/OPERATIONS.md). Process restart is required to change configuration (no SIGHUP).

`--version` prints the project version and protocol 1.0, then exits 0.

### Required

| Flag | Meaning |
|---|---|
| `--config PATH` | Optional ingress config file. May be set once |
| `--listen HOST:PORT` | Public browser listener |
| `--broker HOST:PORT` | Broker address. Web Ingress HELLO as Caller |
| `--token TOKEN` | Bearer secret (must match a Broker Caller credential). Development convenience |
| `--token-file PATH` | File whose body is the bearer secret. Prefer mode `0600` |
| `--route HOST=SERVICE_ID[:MODE]` | Repeatable exact public-host route. `MODE` is `http` (default) or `tls_passthrough` |

`--tls-cert` and `--tls-key` are required unless `--insecure` is set, or every route is `tls_passthrough`. Combining `--insecure` with either TLS flag is rejected. `--insecure` is loopback-only and allows exactly one route.

`--insecure-broker` is rejected with `--tls-ca` or `--tls-server-name`. A public production listener must not use `--insecure-broker`.

On listen the process prints `thirp-web-ingress listening on HOST:PORT`.

### Routes

Exact hostname match after canonical lowercase and terminal-dot strip. The public hostname is a locator, not a credential. A normal Agent registration is not browser-reachable until a route exists, the Ingress Principal has an exact Broker `allow_connect` grant, and Web Ingress is ready.

```text
route = portfolio-k7m4x2.web.example.com=acme/site-17/portfolio-ui:http
route = secure-k9p3.web.example.com=acme/site-17/secure-ui:tls_passthrough
```

`http` terminates TLS at Web Ingress and pumps HTTP/1.1 bytes. `tls_passthrough` inspects a bounded ClientHello for SNI, then relays original TLS bytes. The Origin owns the certificate for that hostname. Mixed routes need an ingress certificate. Passthrough-only does not.

Web Ingress connects only to a configured `ServiceId`. It does not accept a client-supplied destination.

### Limits

Unset flags keep the defaults. Handshake and Broker-dial timeouts cannot be 0.

| Flag | Default | Meaning |
|---|---|---|
| `--max-connections N` | 4096 | Browser connections |
| `--max-connections-per-ip N` | 64 | Browser connections from one source IP |
| `--max-client-hello-bytes BYTES` | 65536 | Maximum peeked ClientHello |
| `--client-hello-timeout SECONDS` | 10 | ClientHello / TLS handshake timeout |
| `--broker-dial-timeout SECONDS` | 10 | `CONNECT` / service-dial timeout |
| `--idle-timeout SECONDS` | 300 | Established idle timeout. `0` disables idle only |
| `--shutdown-grace SECONDS` | 15 | Drain wait after SIGINT/SIGTERM |
| `--log-level LEVEL` | `info` | `error`, `warn`, `info`, or `debug` |

Recommended `ulimit -n` is at least `2 * max_connections + 64`.

### Metrics and health

`--metrics-listen HOST:PORT` starts a separate HTTP listener (not the public port):

| Path | Meaning |
|---|---|
| `GET /healthz` | Process liveness. `200` `ok` |
| `GET /readyz` | `200` `ready`, or `503` `not_ready` / `draining` |
| `GET /metrics` | Prometheus text. Fixed labels only |

`/readyz` is false while the public listener is down, required TLS context is missing, the Caller session is unusable, or the process is draining. One unavailable Origin does not make the process unready.

The socket is unauthenticated and has no TLS. Bind it to localhost or a private network.

SIGINT or SIGTERM: mark draining, stop accepts, reject connections that have not finished route selection, stop new CONNECT, wait `shutdown_grace` for established streams, then close what remains. Web Ingress does not request Broker-wide drain.

## Local demo

Run from the repository root. Separate Agent and Ingress credentials, production Broker policy, TLS on every Rendez link. The local origin is plaintext loopback.

```bash
odin build broker_cli -out:thirp-broker
odin build agent_cli -out:thirp-agent
odin build web_ingress_cli -out:thirp-web-ingress
odin build echo_http_cli -out:thirp-echo-http
```

Terminal 1:

```bash
./thirp-broker --config examples/web-ingress/broker.conf
```

Terminal 2:

```bash
./thirp-echo-http --listen 127.0.0.1:7080
```

Terminal 3:

```bash
./thirp-agent --config examples/web-ingress/agent.conf
```

Terminal 4:

```bash
./thirp-web-ingress --config examples/web-ingress/web-ingress.conf
```

Terminal 5:

```bash
curl --cacert examples/web-ingress/web-ingress.crt \
  --resolve portfolio.demo.test:9443:127.0.0.1 \
  https://portfolio.demo.test:9443/invite/demo
```

The fixture response includes `X-Echo-Method`, `X-Echo-Target`, and `X-Echo-Host` and echoes the request body. Those example tokens and certificates are for loopback only.

## See also

- [BUILDING.md](../docs/BUILDING.md) - building, testing, and packaging
- [OPERATIONS.md](../docs/OPERATIONS.md) — deploy, systemd, Agent stop/restore, grant revoke
- [SECURITY.md](../docs/SECURITY.md) — threat model
- [broker_cli/README.md](../broker_cli/README.md) — Broker policy and grants
- [agent_cli/README.md](../agent_cli/README.md) — register a local target
- [README.md](../README.md) — five-terminal echo and Web Ingress demos
