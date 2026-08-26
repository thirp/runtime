# thirp-agent

Registers one or more named services with a rendezvous broker and relays streams to local TCP targets.

Source: `agent_cli/`. Binary name: `thirp-agent`. Thin wrapper over the `agent` package.

## Build

Requires [Odin](https://odin-lang.org/) and OpenSSL 3. See [DEPENDENCIES.md](../docs/DEPENDENCIES.md).

```bash
odin build agent_cli -out:thirp-agent
```

## Usage

```text
thirp-agent [--version] [--config PATH] --broker HOST:PORT (--token TOKEN | --token-file PATH)
             (--map SERVICE_ID=HOST:PORT ... | --service SERVICE_ID --target HOST:PORT)
             [--tls-ca PATH] [--tls-server-name NAME | --insecure]
```

| Flag | Required | Meaning |
|---|---|---|
| `--version` | no | Print project version and protocol 1.0, then exit 0 |
| `--config PATH` | no | Line-oriented `key = value` file. Flags override. May be set once |
| `--broker HOST:PORT` | yes | Broker address |
| `--token TOKEN` | one of | Bearer token (must match a broker credential). Development convenience |
| `--token-file PATH` | one of | File whose body is the bearer secret. Prefer mode `0600` |
| `--map SERVICE_ID=HOST:PORT` | one mapping | Repeatable service → local target. At least one `--map` or the one-service pair |
| `--service SERVICE_ID` | with `--target` | Convenience for a single mapping |
| `--target HOST:PORT` | with `--service` | Local TCP address to dial on each `OPEN` |
| `--tls-ca PATH` | no | PEM CA file. Omit to use the system CA bundle |
| `--tls-server-name NAME` | no | SNI / hostname verification. Defaults to the host in `--broker` |
| `--insecure` | no | Plaintext TCP. Rejected if combined with `--tls-ca` or `--tls-server-name` |
| `-h`, `--help` | no | Print usage and exit 0 |

Exactly one of `--token` or `--token-file` is required (from the file, the flags, or both after merge). `--token-file` is the production path: the file is the raw secret (one line, no `TOKEN=PRINCIPAL` grammar). Do not put long-lived secrets on the command line. Group- or world-readable files print a warning.

`--config` uses the same keys as the flags (`broker`, `token_file`, `map`, `tls_ca`, …). Repeatable `map` lines append; a `--map` for an existing `ServiceId` replaces the file mapping. After merge, every practical error is printed and the process exits 1 before dialing. Example: [examples/production/agent.conf](../examples/production/agent.conf) (two services). Operator walkthrough: [OPERATIONS.md](../docs/OPERATIONS.md).

TLS is the default. `--insecure` is for development only.

`--service` and `--target` must be used together. Duplicate `ServiceId`s are rejected. On success the process prints one `registered SERVICE_ID -> TARGET` line per mapping and stays running.

## ServiceId

`--service` / `--map` names must be valid `ServiceId`s: nonempty, at most 128 bytes, case-sensitive, characters `A-Z a-z 0-9 - _ / .`.

Examples: `demo/echo`, `acme/atlanta/reporting-api`.

A `ServiceId` is a name, not a network address and not a credential. Only one live registration of a given id is allowed on the broker.

## Behavior

1. Dial the broker (TLS unless `--insecure`).
2. `HELLO` as role Agent, then `AUTHENTICATE` with the bearer token.
3. `REGISTER` each configured mapping.
4. On each `OPEN` for a registered name, dial that mapping’s target and pump bytes both ways. Concurrent streams share one broker session.
5. While idle, send `PING` every 15 s.

SIGINT or SIGTERM calls `agent_stop`. The agent UNREGISTERs owned services (best effort), RESET remaining streams, then exits 0 and does not reconnect.

If the broker connection drops, the agent reconnects with exponential backoff and jitter (250 ms … 15 s) and re-registers the configured set. Reconnect logs a `reason`: `network`, `broker_unavailable`, `tls`, `authentication`, `authorization`, `duplicate_registration`, `configuration`, `rate_limited`, or `disconnected`. Authentication, authorization, and configuration failures use the 15 s cap. `RATE_LIMITED` is transient, not a bad token. An explicit library `unregister_service` removes a name from that set so reconnect does not restore it. Live streams do not survive disconnect; they are ordinary closes.

Malformed `--map` / `--target` addresses and unreadable `--tls-ca` fail before the broker is dialed. All mappings are checked; every bad one is printed.

Changing the CLI service set requires a process restart. There is no SIGHUP reload. Programs that need dynamic register/unregister, join codes, or in-process I/O should link the `agent` package (or `libthirp.so`).

## Example

Broker and echo server already running (see [broker_cli/README.md](../broker_cli/README.md)):

```bash
./thirp-agent --broker 127.0.0.1:9000 --tls-ca broker.crt \
    --token host-dev-token \
    --service demo/echo \
    --target 127.0.0.1:7000
```

Production (secret in a `0600` file):

```bash
printf '%s\n' 'host-site-17' > agent.token
chmod 600 agent.token
./thirp-agent --broker 127.0.0.1:9000 --tls-ca broker.crt \
    --token-file agent.token \
    --map acme/site-17/reporting-api=127.0.0.1:7000
```

Two services in one process (or `map` lines in `--config`):

```bash
./thirp-agent --broker 127.0.0.1:9000 --tls-ca broker.crt \
    --token host-dev-token \
    --map demo/echo=127.0.0.1:7000 \
    --map demo/other=127.0.0.1:7001
```

```bash
./thirp-agent --config /etc/thirp/agent.conf
```

Plaintext:

```bash
./thirp-agent --insecure --broker 127.0.0.1:9000 \
    --token host-dev-token \
    --service demo/echo \
    --target 127.0.0.1:7000
```

## See also

- [BUILDING.md](../docs/BUILDING.md) - building, testing, and packaging
- [caller_cli/README.md](../caller_cli/README.md) — local port that dials the registered service
- [broker_cli/README.md](../broker_cli/README.md) — broker
- [OPERATIONS.md](../docs/OPERATIONS.md) — deploy, systemd, backup
- [PROTOCOL.md](../docs/PROTOCOL.md) — wire format
- [README.md](../README.md) — five-terminal echo demo
