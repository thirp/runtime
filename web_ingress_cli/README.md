# thirp-web-ingress

A browser-facing listener that reaches registered HTTP and HTTPS origins through the Broker as a Caller.

Source: `web_ingress_cli/`. Binary name: `thirp-web-ingress`. Thin wrapper over the `web_ingress` package.

## Build

Build on Linux or macOS. The CLI uses POSIX signal handling. [Building](https://github.com/thirp/runtime/blob/main/docs/BUILDING.md#build-command-line-components)

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

`--config PATH` loads a line-oriented `key = value` file. `#` starts a comment. Optional `[section]` lines are ignored. Keys such as `tls_cert`, `token_file`, and `metrics_listen` use underscores where the flags use hyphens. Repeatable `route` lines add routes. A `--route` flag for a configured hostname replaces that route.

CLI flags override file values. Required fields may come from either source. After merge, every practical error is printed and the process exits 1 without listening. Unknown keys and duplicate non-repeatable keys fail.

Exactly one of `token` or `token_file` is required. Keep the secret in
`token_file`. Restart the process to change its configuration.
[Example configuration](https://github.com/thirp/runtime/blob/main/examples/production/web-ingress.conf) · [Operations](https://github.com/thirp/runtime/blob/main/docs/OPERATIONS.md#web-ingress)

`--version` prints the project version, build commit and protocol 1.0, then exits 0.

### Listener, routing and TLS

| Flag | Meaning |
|---|---|
| `--config PATH` | Optional ingress config file. May be set once |
| `--listen HOST:PORT` | Public browser listener. Use a numeric IP address |
| `--broker HOST:PORT` | Broker address. Web Ingress HELLO as Caller |
| `--token TOKEN` | Bearer secret (must match a Broker Caller credential). Development convenience |
| `--token-file PATH` | File containing the bearer secret. Use mode `0600` |
| `--route HOST=SERVICE_ID[:MODE]` | Repeatable exact public-host route. `MODE` is `http` (default) or `tls_passthrough` |
| `--tls-cert PATH` | Browser-facing certificate chain for TLS-terminating routes |
| `--tls-key PATH` | Private key for the browser-facing certificate |
| `--insecure` | Enable plaintext on the loopback browser listener. Off by default |
| `--tls-ca PATH` | PEM CA for the Broker. Omit to use system trust |
| `--tls-server-name NAME` | Broker TLS identity and SNI. Defaults to verifying the resolved Broker IP |
| `--insecure-broker` | Enable plaintext to the Broker for development. Off by default |
| `-h`, `--help` | Print usage and exit 0 |

`--tls-cert` and `--tls-key` are required unless `--insecure` is set, or every route is `tls_passthrough`. Combining `--insecure` with either TLS flag is rejected. `--insecure` is loopback-only and allows exactly one route.

`--insecure-broker` is rejected with `--tls-ca` or `--tls-server-name`. A public production listener must not use `--insecure-broker`.

On listen the process prints `thirp-web-ingress listening on HOST:PORT`.

### Routes

For TLS routes, Web Ingress matches hostnames exactly after lowercasing and
removing a trailing dot. To reach a service from a browser, register the
service, add a route for its public hostname, and authorize the Ingress Caller
to connect to that service.

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

On Unix, recommended `ulimit -n` is at least `2 * max_connections + 64`.

### Metrics and health

`--metrics-listen HOST:PORT` starts a separate HTTP listener. It is off by default.

| Path | Meaning |
|---|---|
| `GET /healthz` | Process liveness. `200` `ok` |
| `GET /readyz` | `200` `ready`, or `503` `not_ready` / `draining` |
| `GET /metrics` | Prometheus text. Fixed labels only |

`/readyz` is false while the public listener is down, required TLS context is missing, the Caller session is unusable, or the process is draining. One unavailable Origin does not make the process unready.

The socket is unauthenticated and has no TLS. Bind it to localhost or a private network.

On Linux and macOS, SIGINT or SIGTERM starts a drain. During drain, stop accepts, reject connections that have not finished route selection, stop new CONNECT, wait `shutdown_grace` for established streams, then close what remains. Web Ingress does not request Broker-wide drain.

## Local demo

Run from the root of the Runtime source tree. On macOS, use the full macOS
build for the Broker, Agent and Web Ingress.
[macOS builds](https://github.com/thirp/runtime/blob/main/docs/BUILDING.md#macos-1)

This demo uses separate Agent and Ingress credentials and production Broker
policy. Both Broker links and the public listener use TLS. The loopback
origin uses plaintext.

Add the directory with the Broker, Agent and Web Ingress binaries to `PATH`
in each demo terminal. On Linux, build all four binaries.

```bash
odin build broker_cli -out:thirp-broker
odin build agent_cli -out:thirp-agent
odin build web_ingress_cli -out:thirp-web-ingress
odin build echo_http_cli -out:thirp-echo-http
```

On macOS, build the HTTP fixture from the repository root with the same
OpenSSL libraries as the other binaries:

```bash
source scripts/macos_openssl.sh
macos_prepare_openssl
odin build echo_http_cli -out:thirp-echo-http -define:OPENSSL_STATIC=true -extra-linker-flags:"$OPENSSL_LINK_FLAGS"
```

Terminal 1:

```bash
thirp-broker --config examples/web-ingress/broker.conf
```

Terminal 2:

```bash
./thirp-echo-http --listen 127.0.0.1:7080
```

Terminal 3:

```bash
thirp-agent --config examples/web-ingress/agent.conf
```

Terminal 4:

```bash
thirp-web-ingress --config examples/web-ingress/web-ingress.conf
```

Terminal 5:

```bash
curl --cacert examples/web-ingress/web-ingress.crt \
  --resolve portfolio.demo.test:9443:127.0.0.1 \
  https://portfolio.demo.test:9443/invite/demo
```

The fixture response includes `X-Echo-Method`, `X-Echo-Target`, and `X-Echo-Host` and echoes the request body. Those example tokens and certificates are for loopback only.

## See also

- [Building, testing, and packaging](https://github.com/thirp/runtime/blob/main/docs/BUILDING.md)
- [OPERATIONS.md](https://github.com/thirp/runtime/blob/main/docs/OPERATIONS.md) — deploy, systemd, Agent stop/restore, grant revoke
- [SECURITY.md](https://github.com/thirp/runtime/blob/main/docs/SECURITY.md) — threat model
- [broker_cli/README.md](https://github.com/thirp/runtime/blob/main/broker_cli/README.md) — Broker policy and grants
- [agent_cli/README.md](https://github.com/thirp/runtime/blob/main/agent_cli/README.md) — register a local target
- [Quickstart](https://github.com/thirp/runtime/blob/main/docs/QUICKSTART.md) — local TLS relay demo
