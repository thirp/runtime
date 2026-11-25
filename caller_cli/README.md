# thirp-connect

Listens on local TCP ports and copies bytes both ways between local clients
and named services through the broker.

Source: `caller_cli/`. Binary name: `thirp-connect`. Uses the `caller` package for broker connections.

This is a port bridge, not a VPN. Routing is by `ServiceId`.

## Build

See the native Linux, macOS and Windows instructions. [Building](../docs/BUILDING.md#build-command-line-components)

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
| `--token-file PATH` | one of in legacy mode | File containing the bearer secret. Use mode `0600` on Unix and a private ACL on Windows |
| `--service SERVICE_ID` | yes in legacy mode | Service to dial on each local accept |
| `--listen HOST:PORT` | yes in legacy mode | Local TCP listen address. Use a numeric IP address |
| `--caller-conf PATH` | yes in enrollment mode | Enrolled caller configuration; see Caller enrollment |
| `--tls-ca PATH` | no | Legacy mode: PEM CA file. Omit to use the system CA bundle |
| `--tls-server-name NAME` | no | Legacy mode: SNI / hostname verification. Defaults to the host in `--broker` |
| `--insecure` | no | Legacy mode: plaintext TCP. Rejected if combined with `--tls-ca` or `--tls-server-name` |
| `--stream-stall-timeout SECONDS` | no | A write to a local client that takes no bytes this long fails and ends that stream (range `0` to `86400`, default `30`, `0` disables the timeout). See Behavior |
| `--max-stream-buffer-mib N` | no | Download data held for one local client that it has not read yet; a stream further behind is reset at once (`1`..`1048576`, default `8`). See Behavior |
| `-h`, `--help` | no | Print usage and exit 0 |

In legacy mode, exactly one of `--token` or `--token-file` is required. `--token-file` is the production path for this mode: the file is the raw secret (one line, no `TOKEN=PRINCIPAL` grammar). Do not put long-lived secrets on the command line. On Unix, group- or world-readable files print a warning.

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
- A download that overruns the Caller's per-stream buffer resets that stream.
  A local write that makes no progress for the configured stall timeout also
  ends the stream. [Broker backpressure](../docs/OPERATIONS.md#resource-limits)
- A Caller accepts up to 256 live local connections per session. Enrollment
  listeners for the same catalog service share that limit.

A failed initial legacy broker setup exits nonzero. For established sessions,
see [session recovery](../docs/OPERATIONS.md#session-recovery).

`--listen` (legacy mode) or each `listen` address in `caller.conf` controls who on the caller-side network can use the bridge. Examples use `127.0.0.1`. A non-loopback listen address prints a warning in either mode.

A local listen failure exits nonzero.

Programs that want in-process `dial` / `conn_read` / `conn_write` should link the `caller` package (or `libthirp.so`) instead of this binary.

## Caller enrollment

```bash
thirp-connect --caller-conf /path/to/caller.conf
```

Use the configuration produced by the control-plane enrollment tool. The conf contains `api`, `org`,
`environment`, `enrollment`, `token_file`, `broker`, `tls_ca`, and
`tls_server_name`, plus service/listen links. All eight keys must be present;
`environment`, `tls_ca`, and `tls_server_name` may have empty values.
The configuration and its `token_file` must be regular files. On Unix their
permissions must be no wider than `0600`; broader permissions cause an error
and exit 1. Keep their directory at `0700` (recommended, not checked).
On Windows, token rotation writes a protected DACL granting `FILE_ALL_ACCESS`
to the process-token user and LocalSystem (SYSTEM). When the process runs as
LocalSystem, the DACL has one allow entry for SYSTEM. Before reading either
file, the process checks the open file's DACL and rejects a NULL or unprotected
DACL, inherited entries, or an allow entry for another principal that grants
more than metadata access. Explicit deny entries are permitted. An unsafe
file causes exit 1.
Relative `token_file`, `tls_ca`, and `api_tls_ca` paths resolve beside the conf.
One process opens a listener for every `service = <catalog id> listen = <IP:port>`
line. `api` must be an HTTPS origin. The API's TLS identity comes from the URL.
The API uses system trust or the PEM CA file in the optional `api_tls_ca` key.
`tls_ca` and `tls_server_name` configure the broker's trust and identity.
Stream buffer and stall flags can also be used.

`--caller-conf` cannot be mixed with `--token`, `--token-file`, `--broker`,
`--service`, `--listen`, `--tls-ca`, `--tls-server-name`, or `--insecure`;
mixing them prints an error and exits 1.
Put endpoint and TLS settings in the file.

The enrollment secret authenticates control-plane requests. With an
organization-wide Platforms enrollment, the Caller can request and approve
a replacement grant. With an environment-scoped enrollment, it waits for an
approved grant. The Caller mints
a separate broker credential and renews it while the grant is valid. It keeps
the listeners bound during approval and rollover. Accepts close while the
service has no live, admitted session. On revocation, affected streams close
and approval polling resumes. Invalid configuration and enrollment expiry
cause a nonzero exit.

If admission is lost, the Caller retires the session and tries to mint a
fresh broker credential. If the API is unavailable, it can reuse its former
credential once if it is still valid for the same grant. A failed broker
setup discards that credential. Each setup attempt shares a 10-second deadline
across DNS, TCP, TLS, Hello and Authenticate. With no usable session, three
consecutive broker setup failures for a service cause exit 1 with
`broker_setup_exhausted`. Approval waits and API retries have separate timers.

The Caller checks for enrollment token rotation at startup and every six hours.
Within 30 days of expiry it requests a replacement and atomically replaces the
token file. Unix uses a private temporary file and rename. Windows sets a
protected DACL before writing the temporary file, then replaces the token
and rechecks the DACL. Rotation of an existing token on Windows requires
hard-link support to retain the old token for rollback. Run one process per
enrollment token file.

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
- [Quickstart](../docs/QUICKSTART.md) — local relay demo
