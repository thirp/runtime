# thirp-agent

Registers one or more named services with a rendezvous broker and relays streams to local TCP targets.

Source: `agent_cli/`. The CLI uses the `agent` package.

## Build

See the native Linux, macOS and Windows instructions. [Building](../docs/BUILDING.md#build-command-line-components)

## Usage

```text
thirp-agent [--version] [--config PATH] --broker HOST:PORT (--token TOKEN | --token-file PATH)
             (--map SERVICE_ID=HOST:PORT ... | --service SERVICE_ID --target HOST:PORT)
             [--tls-ca PATH] [--tls-server-name NAME | --insecure]
             [--max-stream-buffer-mib N] [--max-buffered-mib N] [--max-streams N]
```

| Flag | Required | Meaning |
|---|---|---|
| `--version` | no | Print project version, build commit and protocol 1.0, then exit 0 |
| `--config PATH` | no | Line-oriented `key = value` file. Flags override. May be set once |
| `--broker HOST:PORT` | yes | Broker address. IP or DNS name; DNS is resolved at start |
| `--token TOKEN` | one of | Bearer token (must match a broker credential). Development convenience |
| `--token-file PATH` | one of | File containing the bearer secret. Use mode `0600` on Unix and a private ACL on Windows |
| `--map SERVICE_ID=HOST:PORT` | one mapping | Repeatable service → local target. At least one `--map` or the one-service pair |
| `--service SERVICE_ID` | with `--target` | Convenience for a single mapping |
| `--target HOST:PORT` | with `--service` | Local TCP address to dial on each `OPEN` |
| `--tls-ca PATH` | no | PEM CA file. Omit to use the system CA bundle |
| `--tls-server-name NAME` | no | SNI / hostname verification. Defaults to the host in `--broker` |
| `--insecure` | no | Plaintext TCP. Rejected if combined with `--tls-ca` or `--tls-server-name` |
| `--max-stream-buffer-mib N` | no | DATA queued for one stream's local service before that stream is reset (`1`..`1048576`, default 64). No per-stream flow control in protocol 1.0: an upload that runs this far ahead of a slow service fails instead of holding up other streams |
| `--max-buffered-mib N` | no | DATA queued across all streams (`1`..`1048576`, default 256 MiB) |
| `--max-streams N` | no | Open streams (two threads each); further opens fail with `QUOTA_EXCEEDED` (`1`..`1048576`, default 128) |
| `-h`, `--help` | no | Print usage and exit 0 |

The Agent checks the per-stream cap first. A frame that would exceed it
resets that stream, even if the aggregate cap would also be exceeded. A
frame that fits the per-stream cap but would exceed the aggregate cap can
cause the Agent to reset the stream with the largest backlog. If the
receiving stream is still open and the frame still cannot fit, the Agent
resets that stream.

Exactly one of `--token` or `--token-file` is required (from the file, the flags, or both after merge). `--token-file` is the production path: the file is the raw secret (one line, no `TOKEN=PRINCIPAL` grammar). Do not put long-lived secrets on the command line. On Unix, group- or world-readable files print a warning.

The config accepts `broker`, `token`, `token_file`, `map`, `service`, `target`, `tls_ca`, `tls_server_name` and `insecure`. Set buffer and stream limits on the command line. Repeatable `map` lines append; a `--map` for an existing `ServiceId` replaces the file mapping. After merge, every practical error is printed and the process exits 1 before dialing. Example: [examples/production/agent.conf](../examples/production/agent.conf) (two services). Operator walkthrough: [OPERATIONS.md](../docs/OPERATIONS.md).

TLS is the default. `--insecure` is for development only.

`--service` and `--target` must be used together. Duplicate `ServiceId`s are rejected. The CLI prints `registered SERVICE_ID -> TARGET` when it adds a mapping locally. Check the structured `registered` event for broker confirmation.

## ServiceId

`--service` / `--map` names must be valid `ServiceId`s: nonempty, at most 128 bytes, case-sensitive, characters `A-Z a-z 0-9 - _ / .`.

Examples: `demo/echo`, `acme/atlanta/reporting-api`.

A `ServiceId` names a service. Only one live registration of that ID is allowed within its Broker namespace. [Service ID scope](../docs/COMPATIBILITY.md#service-ids)

## Behavior

1. Dial the broker (TLS unless `--insecure`).
2. `HELLO` as role Agent, then `AUTHENTICATE` with the bearer token.
3. `REGISTER` each configured mapping.
4. On each `OPEN` for a registered name, dial that mapping’s target and pump bytes both ways. Concurrent streams share one broker session.
5. Check every 2 seconds whether to send a Ping. While receiving traffic,
   the Agent lets outbound data take priority. If the Broker sends no frames
   for 7 seconds, the Agent closes the session.

On Linux and macOS, SIGINT or SIGTERM requests a stop. On Windows the
console handler handles Ctrl+C, Ctrl+Break and console close. The Agent
tries to unregister its services before it resets remaining streams and
exits. The Broker removes registrations owned by a closed session.

After disconnect, the Agent retries with jittered exponential backoff
(base 250 ms, cap 15 s) using its startup token. It re-registers its configured
services when admitted. The `reconnect_scheduled.reason` values include
`network`, `broker_unavailable`, `tls`, `authentication`, `authorization`,
`duplicate_registration`, `configuration`, `rate_limited`, `dead_peer`
and `disconnected`. Authentication, authorization and configuration failures
use the capped delay. [Session recovery and close causes](../docs/OPERATIONS.md#session-recovery)

Malformed `--map` / `--target` addresses and unreadable `--tls-ca` fail before the broker is dialed. All mappings are checked; every bad one is printed.

Restart the process to apply changes to its CLI service set or token file. Programs that need dynamic register/unregister, join codes, or in-process I/O should link the `agent` package (or `libthirp.so`).

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
- [Quickstart](../docs/QUICKSTART.md) — local relay demo
