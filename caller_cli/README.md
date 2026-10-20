# thirp-connect

Listens on a local TCP port. Each accepted connection dials a named service through the broker and copies bytes both ways.

Source: `caller_cli/`. Binary name: `thirp-connect`. Thin wrapper over the `caller` package.

This is a port bridge, not a VPN. Routing is by `ServiceId`.

## Build

Requires [Odin](https://odin-lang.org/) and OpenSSL 3. See [DEPENDENCIES.md](../docs/DEPENDENCIES.md).

```bash
odin build caller_cli -out:thirp-connect
```

## Usage

```text
thirp-connect [--version] --broker HOST:PORT (--token TOKEN | --token-file PATH) --service SERVICE_ID --listen HOST:PORT
               [--tls-ca PATH] [--tls-server-name NAME | --insecure]
               [--stream-stall-timeout SECONDS] [--max-stream-buffer-mib N]
```

| Flag | Required | Meaning |
|---|---|---|
| `--version` | no | Print project version and protocol 1.0, then exit 0 |
| `--broker HOST:PORT` | yes | Broker address. IP or DNS name; DNS is resolved at start |
| `--token TOKEN` | one of | Bearer token (must match a broker credential). Development convenience |
| `--token-file PATH` | one of | File whose body is the bearer secret. Prefer mode `0600` |
| `--service SERVICE_ID` | yes | Service to dial on each local accept |
| `--listen HOST:PORT` | yes | Local TCP listen address |
| `--tls-ca PATH` | no | PEM CA file. Omit to use the system CA bundle |
| `--tls-server-name NAME` | no | SNI / hostname verification. Defaults to the host in `--broker` |
| `--insecure` | no | Plaintext TCP. Rejected if combined with `--tls-ca` or `--tls-server-name` |
| `--stream-stall-timeout SECONDS` | no | A write to a local client that takes no bytes this long fails and ends that stream (default `30`, `0` = never). See Behavior |
| `--max-stream-buffer-mib N` | no | Download data held for one local client that it has not read yet; a stream further behind is reset at once (`1`..`1048576`, default `8`). See Behavior |
| `-h`, `--help` | no | Print usage and exit 0 |

Exactly one of `--token` or `--token-file` is required. `--token-file` is the production path: the file is the raw secret (one line, no `TOKEN=PRINCIPAL` grammar). Do not put long-lived secrets on the command line. Group- or world-readable files print a warning.

`thirp-connect` has no `--config` file. Operators use flags and `--token-file`. Broker and agent config files are documented in [OPERATIONS.md](../docs/OPERATIONS.md).

TLS is the default. `--insecure` is for development only.

On success the process prints `thirp-connect listening on HOST:PORT for SERVICE_ID` and stays running.

## ServiceId

`--service` must be a valid `ServiceId`: nonempty, at most 128 bytes, case-sensitive, characters `A-Z a-z 0-9 - _ / .`.

It must match the id the agent registered. Case matters: `demo/echo` and `Demo/echo` are different names.

## Behavior

1. Listen on `--listen`. A busy or unusable address exits 1 with `listen failed on HOST:PORT: <reason>` (for example `address already in use`) before any broker session is opened.
2. Dial the broker once (TLS unless `--insecure`).
3. `HELLO` as role Caller, then `AUTHENTICATE` with the bearer token.
4. On each accept, a per-connection thread sends `CONNECT` for `--service` on the existing broker session and pumps 16 KiB chunks between the local TCP socket and the relay stream. The accept loop never waits on a `CONNECT`.

Accepts are concurrent. Closing one local connection RESET/CLOSE that stream only; others stay up.

Stream ends:

- Local EOF is sent as `HALF_CLOSE`; the response direction stays open until the peer finishes.
- Peer `HALF_CLOSE` is passed to the client as EOF (`shutdown(SHUT_WR)`).
- When both directions are done, or on the peer's `CLOSE`/`RESET`, the local socket is closed. After an early `CLOSE`/`RESET` (for example a server that answers 403 and closes while the client is still uploading), the rest of the client's request is drained for up to 2 s so the response is not lost to a TCP reset, then the socket is shut down both ways.
- A slow client or server only slows its own stream. Each stream has its own buffer: 8 MiB in thirp-connect (download direction) and 64 MiB in the Agent (upload direction, `AgentConfig.max_stream_buffer`; 256 MiB for all streams together).
- A write to the local client fails only when the client took no bytes for `--stream-stall-timeout` seconds (default 30; `0` = never).
- The protocol has no per-stream flow control, so no buffer ever makes the session wait. **A slow download past 8 MiB is reset:** a client that reads slower than the service sends (or pauses, like a pager) loses its stream once it is `--max-stream-buffer-mib` behind. Likewise in the Agent, an upload whose backlog would pass 64 MiB is reset. Either way the other streams, and other callers of the same service, are unaffected. See the CHANGELOG trade-off note.
- At most 256 local connections are open at once; more are closed on accept with a message on stderr.

A failed initial broker dial exits nonzero. After listen starts, a dead broker session closes in-flight local sockets. The caller library reconnects the broker session with the same backoff as the agent (250 ms … 15 s). Later accepts `CONNECT` on the new session. Lost streams are not resumed. `RATE_LIMITED` on authenticate or CONNECT is transient, not a bad token.

`--listen` controls who on the caller-side network can use the bridge. Examples use `127.0.0.1`. Binding all interfaces (`0.0.0.0` / `::`) prints a warning.

There is no signal waiter. Default process kill is enough. Local listen failure also exits nonzero.

Programs that want in-process `dial` / `conn_read` / `conn_write` should link the `caller` package (or `libthirp.so`) instead of this binary.

## Example

Broker and agent already running (see [agent_cli/README.md](../agent_cli/README.md)):

```bash
./thirp-connect --broker 127.0.0.1:9000 --tls-ca broker.crt \
    --token caller-dev-token \
    --service demo/echo \
    --listen 127.0.0.1:8000
```

Production (secret in a `0600` file):

```bash
printf '%s\n' 'reporting-client' > caller.token
chmod 600 caller.token
./thirp-connect --broker 127.0.0.1:9000 --tls-ca broker.crt \
    --token-file caller.token \
    --service acme/site-17/reporting-api \
    --listen 127.0.0.1:8000
```

Then:

```bash
nc 127.0.0.1 8000
```

A second `nc 127.0.0.1 8000` can run at the same time; each is a separate stream on the same caller session.

Plaintext:

```bash
./thirp-connect --insecure --broker 127.0.0.1:9000 \
    --token caller-dev-token \
    --service demo/echo \
    --listen 127.0.0.1:8000
```

## See also

- [BUILDING.md](../docs/BUILDING.md) - building, testing, and packaging
- [agent_cli/README.md](../agent_cli/README.md) — register the service
- [broker_cli/README.md](../broker_cli/README.md) — broker
- [OPERATIONS.md](../docs/OPERATIONS.md) — deploy, systemd, backup
- [PROTOCOL.md](../docs/PROTOCOL.md) — wire format
- [README.md](../README.md) — five-terminal echo demo
