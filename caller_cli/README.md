# thirp-connect

Listens on local TCP ports. Each accepted connection dials a named service through the broker and copies bytes both ways.

Source: `caller_cli/`. Binary name: `thirp-connect`. Uses the `caller` package for broker connections.

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
thirp-connect --caller-conf PATH [--stream-stall-timeout SECONDS] [--max-stream-buffer-mib N]
```

| Flag | Required | Meaning |
|---|---|---|
| `--version` | no | Print project version, build commit and protocol 1.0, then exit 0 |
| `--broker HOST:PORT` | yes in legacy mode | Broker address. IP or DNS name; DNS is resolved at start |
| `--token TOKEN` | one of in legacy mode | Bearer token (must match a broker credential). Development convenience |
| `--token-file PATH` | one of in legacy mode | File whose body is the bearer secret. Prefer mode `0600` |
| `--service SERVICE_ID` | yes in legacy mode | Service to dial on each local accept |
| `--listen HOST:PORT` | yes in legacy mode | Local TCP listen address |
| `--caller-conf PATH` | yes in enrollment mode | Enrolled caller configuration; see Caller enrollment |
| `--tls-ca PATH` | no | Legacy mode: PEM CA file. Omit to use the system CA bundle |
| `--tls-server-name NAME` | no | Legacy mode: SNI / hostname verification. Defaults to the host in `--broker` |
| `--insecure` | no | Legacy mode: plaintext TCP. Rejected if combined with `--tls-ca` or `--tls-server-name` |
| `--stream-stall-timeout SECONDS` | no | A write to a local client that takes no bytes this long fails and ends that stream (default `30`, `0` = never). See Behavior |
| `--max-stream-buffer-mib N` | no | Download data held for one local client that it has not read yet; a stream further behind is reset at once (`1`..`1048576`, default `8`). See Behavior |
| `-h`, `--help` | no | Print usage and exit 0 |

In legacy mode, exactly one of `--token` or `--token-file` is required. `--token-file` is the production path for this mode: the file is the raw secret (one line, no `TOKEN=PRINCIPAL` grammar). Do not put long-lived secrets on the command line. Group- or world-readable files print a warning.

For an enrolled caller, use `--caller-conf` as described below. Broker and agent config files are documented in [OPERATIONS.md](../docs/OPERATIONS.md).

TLS is the default. `--insecure` is for development only.

In legacy mode, on success the process prints `thirp-connect listening on HOST:PORT for SERVICE_ID` and stays running.

## ServiceId

`--service` must be a valid `ServiceId`: nonempty, at most 128 bytes, case-sensitive, characters `A-Z a-z 0-9 - _ / .`.

It must match the id the agent registered. Case matters: `demo/echo` and `Demo/echo` are different names.

## Behavior

Legacy startup and accepts:

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
- At most 256 local connections are open per Caller; more are closed on accept (with a message on stderr in legacy mode). Enrollment links with the same catalog ID share this limit.

In legacy mode, a failed initial broker dial exits nonzero. Enrollment mode retries broker setup. A dead broker session closes in-flight local sockets. The caller library reconnects the broker session with the same backoff as the agent (250 ms … 15 s). Later accepts `CONNECT` on the new session. Lost streams are not resumed. `RATE_LIMITED` on authenticate or CONNECT is transient, not a bad token.

`--listen` (legacy mode) or each `listen` address in `caller.conf` controls who on the caller-side network can use the bridge. Examples use `127.0.0.1`. Binding all interfaces (`0.0.0.0` / `::`) prints a warning.

There is no signal waiter. Default process kill is enough. Local listen failure also exits nonzero.

Programs that want in-process `dial` / `conn_read` / `conn_write` should link the `caller` package (or `libthirp.so`) instead of this binary.

## Caller enrollment

```bash
thirp-connect --caller-conf /path/to/caller.conf
```

Use the file written by `thirp caller enroll`. The conf contains `api`, `org`,
`environment`, `enrollment`, `token_file`, `broker`, `tls_ca`, and
`tls_server_name`, plus service/listen links. All eight keys must be present;
`environment`, `tls_ca`, and `tls_server_name` may have empty values.
The configuration and its `token_file` must be regular files. On Unix their
permissions must be no wider than `0600`; broader permissions cause an error
and exit 1. Keep their directory at `0700` (recommended, not checked).
On Windows, files written during rotation have an owner-only DACL: exactly
two allow ACEs, granting the current process-token user and LocalSystem (SYSTEM)
`FILE_ALL_ACCESS`, with inheritance off. Before reading either file, the process
checks the open file's DACL and refuses a NULL DACL, an unprotected DACL,
inherited ACEs, or a grant that lets another principal read the data. Deny ACEs
are permitted. An unsafe file causes the same error and exit 1 as on Unix.
Relative `token_file` and `tls_ca` paths resolve beside the conf.
One process opens a listener for every `service = <catalog id> listen = <IP:port>`
line. `api` must be an HTTPS origin. TLS verifies both the control API and broker;
`tls_ca` and `tls_server_name` apply to both, with each endpoint's hostname used
by default. Stream buffer and stall flags can also be used.

`--caller-conf` cannot be mixed with `--token`, `--token-file`, `--broker`,
`--service`, `--listen`, `--tls-ca`, `--tls-server-name`, or `--insecure`;
mixing them prints an error and exits 1.
Put endpoint and TLS settings in the conf.
The enrollment secret authenticates only control-plane requests. The process
mints and renews a separate broker credential for each grant. Platforms
org-wide links create and approve replacement grants automatically. Support
links stop accepting at grant end, log `waiting for approval`, and poll until
a new Active grant exists. They never create or approve access requests.
Listeners stay bound while waiting and during rollover; existing streams drain
until EOF or their grant end. Revocation closes the Caller and its streams and
polls slowly. Configuration errors and enrollment expiry exit nonzero.

On start and every six hours the process checks enrollment expiry. Within
30 days of expiry it rotates the token and replaces the configured `token_file` atomically
after flushing the temporary file. Unix uses mode `0600` and rename. Windows
sets the protected DACL on the empty temporary file before writing any secret,
then uses `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`
for an atomic replace in the same directory that keeps the temporary file's
DACL, and checks the final path's DACL again. A temporary hard link retains the
old token until that check passes; a failed check restores it. If restoring the
old token also fails, its backup remains beside the token as `*.tmp.old`.
Windows rotation of an existing token requires hard-link support for that backup;
if creating it fails, the old token remains in place. No login session, session
refresh, or disk adoption is involved. Run one process per enrollment token file. The compile-time
`-define:THIRP_LAB_TIMERS=true` shortens polling and rotation-check intervals
only; credential and grant lifetimes and the rotation window stay unchanged.

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
