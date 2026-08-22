# Thirp Runtime

Publish a private service. Connect to a private service. Do not expose the network around it.

Formerly authored as rendez. Protocol 1.0 is unchanged.

A private application registers a named service with a public broker over an outbound connection. An authorized caller asks the broker for that service and receives a bidirectional byte stream. The broker is a switchboard, not an application server.

This is not a VPN, port-forwarder, or “expose localhost” product. Routing is by logical service identity.

**Language:** Odin (Linux first; architecture stays portable)

## Status

- Parent spec: through Phase 10 (Linux C ABI `libthirp.so`). Phase 11 (Windows/macOS CLIs) is planned, not in this tree. Phase 12 (QUIC) is deferred.
- Production-readiness amendment: through PR-8. PR-9 (24-hour soak) and PR-10 (release candidate) are not implemented.
- Web Ingress: through WI-6. See [web_ingress_cli/README.md](web_ingress_cli/README.md).

Project version `0.16.0`. Protocol 1.0.

## Build and test

Requires [Odin](https://odin-lang.org/) `dev-2026-07` or later and OpenSSL 3 (`libssl`/`libcrypto`; `openssl-devel` on Fedora). See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

```bash
odin test . -all-packages
```

`odin test . -all-packages` runs protocol, broker, transport, auth, logging, agent, caller, config, version, c_abi, and web_ingress. Races that pass in isolation and fail on a 24-thread full suite are listed in [docs/RACES.md](docs/RACES.md).

`scripts/release.sh` writes `dist/thirp-runtime-0.16.0/` (Linux artifacts, SBOM, checksums, SDK and broker tarballs). Set `THIRP_GPG_KEY` to detach-sign `SHA256SUMS`.

```bash
odin build broker_cli -out:thirp-broker
odin build agent_cli -out:thirp-agent
odin build caller_cli -out:thirp-connect
odin build echo_cli -out:thirp-echo
odin build echo_http_cli -out:thirp-echo-http
odin build web_ingress_cli -out:thirp-web-ingress
odin build c_abi -build-mode:shared -out:libthirp.so
cc -o thirp-c-smoke c_abi/smoke.c -I c_abi -L. -lthirp -Wl,-rpath,$PWD
```

## TLS echo

Generate a local certificate (SAN must include `IP:127.0.0.1` so hostname verification succeeds):

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout broker.key -out broker.crt \
  -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

Terminal 1:

```bash
./thirp-broker --listen 127.0.0.1:9000 \
  --tls-cert broker.crt --tls-key broker.key \
  --token host-dev-token=host-a \
  --token caller-dev-token=client-a \
  --metrics-listen 127.0.0.1:9090
```

Terminal 2:

```bash
./thirp-echo --listen 127.0.0.1:7000
```

Terminal 3:

```bash
./thirp-agent --broker 127.0.0.1:9000 --tls-ca broker.crt \
    --token host-dev-token \
    --service demo/echo \
    --target 127.0.0.1:7000
```

Terminal 4:

```bash
./thirp-connect --broker 127.0.0.1:9000 --tls-ca broker.crt \
    --token caller-dev-token \
    --service demo/echo \
    --listen 127.0.0.1:8000
```

Terminal 5:

```bash
nc 127.0.0.1 8000
hello
hello
```

A second `nc 127.0.0.1 8000` can run at the same time; each local TCP is a separate stream on the same agent session.

Production policy uses separate least-privilege credentials in files (mode `0600`), not a shared all-powerful token. Copy [examples/production/](examples/production/), replace the `change-me-` secrets and `/etc/thirp` paths, then:

```bash
./thirp-broker --config /etc/thirp/broker.conf
./thirp-agent --config /etc/thirp/agent.conf
./thirp-connect --broker broker.example:8443 --tls-ca /etc/thirp/broker.crt \
    --token-file /etc/thirp/caller.token \
    --service acme/site-17/reporting-api \
    --listen 127.0.0.1:8000
```

The example agent registers `reporting-api` and `inventory`. The example caller grant is `reporting-api` only. Flags override file values. Walkthrough: [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Web Ingress (browser HTTPS)

An unmodified browser reaches a published HTTP origin through `thirp-web-ingress`. The browser machine needs no Thirp Runtime software. Run from the repository root. Separate Agent and Ingress credentials, production Broker policy, TLS on browser-to-ingress, ingress-to-Broker, and Agent-to-Broker. The local origin is plaintext loopback.

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

The fixture response includes `X-Echo-Method`, `X-Echo-Target`, `X-Echo-Host`, and the request body. Those example tokens and certificates are for loopback only. Production template: [examples/production/web-ingress.conf](examples/production/web-ingress.conf). CLI: [web_ingress_cli/README.md](web_ingress_cli/README.md).

Scrape broker metrics:

```bash
curl -s http://127.0.0.1:9090/metrics
```

SIGTERM (or SIGINT) stops accepts, rejects new REGISTER/CONNECT with `BROKER_DRAINING`, waits `--shutdown-grace` (default 10s) for live streams, then RESET remaining streams and exits. `--heartbeat-interval` and `--session-timeout` default to 15s and 45s.

Without `--tls-ca`, clients verify the broker against the system CA bundle. `--tls-server-name` defaults to the host in `--broker`. `--insecure` together with TLS flags is rejected.

## Plaintext echo (development)

Pass `--insecure` on the broker, agent, and connect CLIs instead of certificate flags. Do not use this on a public network.

```bash
./thirp-broker --insecure --listen 127.0.0.1:9000 \
    --token host-dev-token=host-a \
    --token caller-dev-token=client-a
```

Default broker caps (override with flags): 256 KiB per-stream outbound buffer, 8 MiB per-connection buffer, 256 MiB global buffered bytes, 256 streams per agent session, 64 KiB max frame, 4096 physical connections, 256 connections per source IP. Failed authentications default to 20/minute per IP; register/unregister 60/minute per principal; CONNECT 600/minute per principal and per IP (`0` disables a limiter). A stream that exceeds its buffer is RESET; other streams on the same agent stay up. `/metrics` reports labeled `thirp_connection_failure_total`, `thirp_authorization_failures_total`, `thirp_resets_total{reason=...}`, `thirp_limit_exceeds_total{limit=...}`, and `thirp_rate_limit_exceeds_total{limit=...}` so policy denial, missing service, local-target failure, overflow RESET, idle timeout, rate limits, and drain are distinguishable.

The agent stays connected and sends PING while idle. If the broker connection drops, the agent reconnects with exponential backoff and jitter (250ms … 15s) and re-registers. `thirp-connect` does the same for its broker session; lost local sockets still close. Live streams do not survive disconnect. Disconnect or session idle timeout on the broker removes the registration and resets live streams. `--stream-idle-timeout SECONDS` (default `0`, off) RESET idle relay streams with `TIMEOUT`; a production value such as `300` is recommended.

## Embed

Games and other programs link `agent` and `caller` instead of spawning the CLIs. Odin applications import the packages directly (`-collection:thirp=<root>`). C programs link `libthirp.so`. Guide, collection mapping, TLS, token files, and C compile/link: [docs/SDK.md](docs/SDK.md).

```odin
import thirp_agent "thirp:agent"
import thirp_caller "thirp:caller"

agent_init(&agent, config)
register_service(&agent, service_id, LocalTarget{address = target})
// or: hosting, err := host_ephemeral(&agent, .{namespace = "game", local_address = target})

caller_init(&caller, caller_config)
conn, err := dial(&caller, service_id)
n, err := conn_write(conn, data)
n, err := conn_read(conn, buf)
```

`host_ephemeral` generates an 8-character join code (alphabet without `0 O 1 I`) and registers `namespace/code`. Callers use `dial_join_code`. The join code is not a credential; AUTH is still required.

```c
thirp_agent_create(&agent_config, &agent);
thirp_register_service(agent, "demo/echo", "127.0.0.1:7000");
/* or: thirp_host_ephemeral(agent, "game", "127.0.0.1:7000", &hosting); */

thirp_caller_create(&caller_config, &caller);
thirp_dial(caller, "demo/echo", &conn);
thirp_conn_write(conn, data, n, &put);
thirp_conn_read(conn, buf, n, &got);
```

`thirp_conn_read` / `thirp_conn_write` may block. `thirp_unregister_service` drops one name on a live agent without destroying the session.

C-linkable smoke test against an insecure broker and echo (after the build commands above):

```bash
./thirp-broker --insecure --listen 127.0.0.1:9000 \
    --token host-dev-token=host-a \
    --token caller-dev-token=client-a
./thirp-echo --listen 127.0.0.1:7000
./thirp-c-smoke 127.0.0.1:9000 host-dev-token caller-dev-token demo/echo 127.0.0.1:7000
```

## Commands

- [thirp-broker](broker_cli/README.md) — self-hosted Broker
- [thirp-agent](agent_cli/README.md) — outbound Agent
- [thirp-connect](caller_cli/README.md) — standalone Caller CLI
- [thirp-web-ingress](web_ingress_cli/README.md) — browser HTTPS Caller adapter

`thirp-echo` and `thirp-echo-http` are fixtures, not separately documented products.

## License

Apache-2.0. See [LICENSE](LICENSE).

## Documentation

- [docs/PROTOCOL.md](docs/PROTOCOL.md) — normative Version 1 wire format
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) — protocol, C ABI, Odin SDK, and config compatibility
- [docs/SDK.md](docs/SDK.md) — embed Agent/Caller from Odin collections or the C ABI
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — user-visible project versions
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — deploy, TLS, policy, systemd, backup
- [docs/SECURITY.md](docs/SECURITY.md) — self-hosted threat model
- [docs/RACES.md](docs/RACES.md) — TLS poll, fd ownership, drain, stream-buffer races
- [docs/NAMING.md](docs/NAMING.md) — Odin naming convention
- [docs/TRADEMARKS.md](docs/TRADEMARKS.md) — product-name notice
