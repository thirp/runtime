# Thirp Runtime protocol

**Version:** 1.0  
**Status:** normative for the Odin reference implementation  
**Transport:** Version 1 runs over TCP, typically with TLS. This document specifies only the application framing and payloads. Rendezvous semantics do not depend on TCP, TLS, or QUIC.

This is the wire contract. Implementation details live in [`protocol/`](../protocol/). The broader product specification is `named-service-rendezvous-broker-spec-v3-acquisition.md`.

## 1. Framing

Every frame is a 16-byte header followed by a payload. Integers are **network byte order** (big-endian). Receivers MUST decode fields explicitly; they MUST NOT overlay received bytes onto language structs.

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|    version    |     opcode    |             flags             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            length                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                            stream_id                          +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            payload...                         |
```

| Field | Size | Meaning |
|---|---|---|
| `version` | u8 | Protocol major version. Version 1 sends `1`. |
| `opcode` | u8 | Frame type. See §3. |
| `flags` | u16 | Reserved. Version 1 MUST send `0`. Nonzero is a protocol error. |
| `length` | u32 | Payload length in bytes. Does **not** include the 16-byte header. |
| `stream_id` | u64 | Logical stream identifier. `0` means connection-level (no stream). |
| `payload` | `length` bytes | Opcode-specific. |

Constants:

```text
HEADER_SIZE             = 16
PROTOCOL_MAJOR          = 1
PROTOCOL_MINOR          = 0   // carried in HELLO / HELLO_ACK, not the header
MAX_FRAME_PAYLOAD       = 65536          // 64 KiB
RECOMMENDED_DATA_PAYLOAD = 16384         // 16 KiB; not a hard maximum
```

A decoder MUST reject `length > MAX_FRAME_PAYLOAD` as soon as the header is available, without waiting for the declared payload bytes.

Unknown opcodes are a protocol error and MUST terminate the connection. Version 1 does not designate any opcode as ignorable.

The header `version` field is the major version. A peer MUST reject `version != 1` on Version 1 connections (`UNSUPPORTED_VERSION` / protocol error). Minor version and capability bits are negotiated in `HELLO` / `HELLO_ACK`.

## 2. Stream identifiers

`stream_id == 0` is reserved for connection-level control.

Opcodes that **MUST** use `stream_id == 0`:

```text
Hello, HelloAck, Authenticate, AuthenticateOk, AuthenticateFailed,
Register, RegisterOk, RegisterFailed, Unregister, UnregisterOk, UnregisterFailed,
Connect, ConnectFailed, Ping, Pong, Error
```

Opcodes that **MUST** use `stream_id != 0`:

```text
ConnectOk, Open, OpenOk, OpenFailed, Data, HalfClose, Close, Reset
```

`CONNECT` allocates a stream. The allocated identifier appears on `CONNECT_OK` and on the corresponding `OPEN` sent to the agent.

## 3. Opcodes

Numeric values are fixed. Implementations MUST NOT depend on language enum declaration order.

| Value | Name | Role |
|---|---|---|
| 1 | `Hello` | Connection start |
| 2 | `HelloAck` | Connection start reply |
| 3 | `Authenticate` | Bearer token |
| 4 | `AuthenticateOk` | Authenticated principal |
| 5 | `AuthenticateFailed` | Authentication rejection |
| 6 | `Register` | Agent registers a service |
| 7 | `RegisterOk` | Registration accepted |
| 8 | `RegisterFailed` | Registration rejected |
| 9 | `Unregister` | Agent drops a service |
| 10 | `Connect` | Caller requests a service |
| 11 | `ConnectOk` | Stream allocated and opened |
| 12 | `ConnectFailed` | Connect rejected or failed |
| 13 | `Open` | Broker asks agent to dial local target |
| 14 | `OpenOk` | Agent local dial succeeded |
| 15 | `OpenFailed` | Agent local dial failed |
| 16 | `Data` | Opaque application bytes |
| 17 | `HalfClose` | This side will send no more DATA |
| 18 | `Close` | Normal stream close |
| 19 | `Reset` | Abnormal stream termination |
| 20 | `Ping` | Liveness |
| 21 | `Pong` | Liveness reply |
| 22 | `Error` | Connection-level protocol error |
| 23 | `UnregisterOk` | Unregister accepted (including already-absent) |
| 24 | `UnregisterFailed` | Unregister rejected |

Value `0` is not a valid opcode. Opcodes 1–22 are unchanged. 23 and 24 complete UNREGISTER.

## 4. Payload encoding conventions

Length-prefixed fields are `u16` byte count, then that many bytes.

- Strings are UTF-8. Invalid UTF-8 is a protocol error.
- Authentication tokens are opaque bytes, not necessarily UTF-8.
- A decoder MUST consume the entire payload. Trailing unread bytes are a protocol error.

## 5. Message payloads

### 5.1 HELLO

```text
major u8
minor u8
peer_role u8          // Agent=1, Caller=2
capability_bits u64   // Version 1 sends 0; bits are reserved for negotiation
implementation u16+UTF-8
```

A connection MUST begin with `HELLO`. The broker replies with `HELLO_ACK`. Registration and connect are forbidden until authentication succeeds.

If `major` is not `1`, the peer SHOULD send `Error` with `UNSUPPORTED_VERSION` and close.

### 5.2 HELLO_ACK

```text
major u8
minor u8
capability_bits u64
implementation u16+UTF-8
```

### 5.3 AUTHENTICATE

```text
token u16+bytes       // opaque
```

The AUTHENTICATE payload is still opaque bytes. Off-wire credential records may carry capabilities, an optional label, and an optional expiry; those fields are not on the Version 1.0 wire. An expired credential and an unknown token both produce `AUTHENTICATION_FAILED` (numeric `3`).

### 5.4 AUTHENTICATE_OK

```text
principal_id u16+UTF-8
```

`OrganizationId` is not on the Version 1.0 wire. Tenancy is a domain field on the principal, not a protocol dependency.

### 5.5 Failure payloads

Used by `AuthenticateFailed`, `RegisterFailed`, `UnregisterFailed`, `ConnectFailed`, `OpenFailed`, `Error`, and `Reset`:

```text
error_code u16
diagnostic u16+UTF-8   // optional; empty string if none
```

Programs MUST branch on `error_code`, never on diagnostic text. Diagnostics MUST NOT contain tokens, payloads, or secrets.

### 5.6 Service-ID payloads

Used by `Register`, `RegisterOk`, `Unregister`, `UnregisterOk`, `Connect`, and `Open`:

```text
service_id u16+UTF-8
```

The string MUST be a valid `ServiceId` (see §7). Invalid names are `INVALID_SERVICE_ID`.

### 5.7 CONNECT_OK / OPEN_OK / HALF_CLOSE / CLOSE

Empty payload. The stream identifier is in the header.

### 5.8 DATA

The payload is opaque application bytes. The broker MUST NOT parse, inspect, alter, compress, or interpret it.

Recommended DATA payload size is 16 KiB. The hard maximum remains `MAX_FRAME_PAYLOAD`.

### 5.9 PING / PONG

```text
nonce u64
```

`PONG` echoes the nonce from `PING`.

## 6. Wire error codes

| Value | Name |
|---|---|
| 0 | `OK` |
| 1 | `PROTOCOL_ERROR` |
| 2 | `UNSUPPORTED_VERSION` |
| 3 | `AUTHENTICATION_FAILED` |
| 4 | `UNAUTHORIZED` |
| 5 | `INVALID_SERVICE_ID` |
| 6 | `SERVICE_NOT_FOUND` |
| 7 | `SERVICE_ALREADY_REGISTERED` |
| 8 | `AGENT_UNAVAILABLE` |
| 9 | `LOCAL_SERVICE_UNAVAILABLE` |
| 10 | `QUOTA_EXCEEDED` |
| 11 | `RATE_LIMITED` |
| 12 | `STREAM_NOT_FOUND` |
| 13 | `STREAM_ALREADY_EXISTS` |
| 14 | `FRAME_TOO_LARGE` |
| 15 | `TIMEOUT` |
| 16 | `BROKER_DRAINING` |
| 17 | `INTERNAL_ERROR` |

Unknown codes MUST be treated as an error the implementation does not understand; they MUST NOT be confused with `OK`.

Note: the product spec’s caller-flow prose uses `SERVICE_UNAVAILABLE` for a failed local dial. The Version 1.0 numeric set uses `LOCAL_SERVICE_UNAVAILABLE` (9) for that case and `AGENT_UNAVAILABLE` (8) when the agent session is gone.

## 7. ServiceId

`ServiceId` is a distinct logical name, not a network address and not a credential.

Rules:

- nonempty
- at most 128 bytes
- case-sensitive
- characters: `A-Z` `a-z` `0-9` `-` `_` `/` `.`

Valid examples: `game/7QF3P9`, `acme/atlanta/reporting-api`, `buildfarm/linux/x86-17`.

Invalid names MUST be rejected by `make_service_id` / at registration decode. Access-control policy MUST NOT be encoded in the name.

## 7.1 Roles and authorization

`HELLO.peer_role` is a hard security boundary, not a hint.

| Opcode | Agent | Caller |
|---|---|---|
| `REGISTER`, `UNREGISTER`, `OPEN_OK`, `OPEN_FAILED` | allowed | `PROTOCOL_ERROR` |
| `UNREGISTER_OK`, `UNREGISTER_FAILED` | broker → agent | `PROTOCOL_ERROR` if sent by a peer |
| `CONNECT` | `PROTOCOL_ERROR` | allowed |
| `OPEN` | `PROTOCOL_ERROR` (broker → agent only) | `PROTOCOL_ERROR` |
| `DATA`, `HALF_CLOSE`, `CLOSE`, `RESET`, `PING`, `PONG` | allowed | allowed |

A role-invalid opcode MUST be rejected with `PROTOCOL_ERROR` (numeric `1`) and MUST close the physical connection. Policy is not consulted.

After the role check, `REGISTER`, `UNREGISTER`, and `CONNECT` also require principal capability and a matching grant when the broker is in production policy mode:

- `REGISTER` requires `RegisterService` and a namespace grant
- `UNREGISTER` requires `RegisterService` (session ownership is still required)
- `CONNECT` requires `ConnectService` and a connect grant

Capabilities may come from the authenticated credential, from broker policy (`--capability`), or both (union). Capability or grant denial uses `UNAUTHORIZED` (numeric `4`) and does **not** close the connection: `REGISTER_FAILED`, `UNREGISTER_FAILED`, or `CONNECT_FAILED`.

Rate limits use `RATE_LIMITED` (numeric `11`):

- failed `AUTHENTICATE` per source IP → `AUTHENTICATE_FAILED` / `RATE_LIMITED`, connection closes (same as a bad token)
- `REGISTER` / `UNREGISTER` per principal → `REGISTER_FAILED` / `UNREGISTER_FAILED` / `RATE_LIMITED`, connection stays up
- `CONNECT` per principal and per source IP, including missing or unauthorized names → `CONNECT_FAILED` / `RATE_LIMITED`, connection stays up

Role-invalid opcodes are still `PROTOCOL_ERROR` and do not consume rate-limit tokens. A global buffered-byte ceiling rejects new `CONNECT` with `QUOTA_EXCEEDED` (numeric `10`).

Grants are exact `ServiceId`s or a single trailing `/*` prefix (`acme/site-17/*` matches `acme/site-17/` plus a remainder). `*` anywhere else is invalid. Service names are locators, not credentials: knowing a name does not authorize access.

Development policy may allow all authenticated principals after the role check. Production policy is deny-by-default and has no allow-all fallback.

## 7.2 UNREGISTER

`UNREGISTER` is a request/response. The broker replies with `UNREGISTER_OK` or `UNREGISTER_FAILED`. `UnregisterOk` / `UnregisterFailed` are broker-originated; a peer that sends them is a protocol error and the connection closes.

| Case | Reply |
|---|---|
| Role-invalid (`Caller`) | `Error` / `PROTOCOL_ERROR`, connection closes |
| Invalid `ServiceId` | `UNREGISTER_FAILED` / `INVALID_SERVICE_ID`, connection stays up |
| Capability denied | `UNREGISTER_FAILED` / `UNAUTHORIZED`, connection stays up |
| Name owned by another session | `UNREGISTER_FAILED` / `UNAUTHORIZED`, registration unchanged |
| Name owned by this session | remove lookup, `UNREGISTER_OK` |
| Name not in the registry | `UNREGISTER_OK` (idempotent) |

Successful unregister prevents new `CONNECT` lookups. Already-open relay streams stay up until `CLOSE` / `RESET` / disconnect. Unregister does not tear down the agent session or unrelated registrations.

## 8. Connection sequence (informative)

Agent:

```text
AGENT  -> BROKER : HELLO
BROKER -> AGENT  : HELLO_ACK
AGENT  -> BROKER : AUTHENTICATE
BROKER -> AGENT  : AUTHENTICATE_OK
AGENT  -> BROKER : REGISTER
BROKER -> AGENT  : REGISTER_OK
AGENT  -> BROKER : UNREGISTER
BROKER -> AGENT  : UNREGISTER_OK
```

Caller:

```text
CALLER -> BROKER : HELLO
BROKER -> CALLER : HELLO_ACK
CALLER -> BROKER : AUTHENTICATE
BROKER -> CALLER : AUTHENTICATE_OK
CALLER -> BROKER : CONNECT
BROKER -> AGENT  : OPEN          (stream_id allocated)
AGENT  -> BROKER : OPEN_OK
BROKER -> CALLER : CONNECT_OK    (same stream_id)
```

Then `DATA` in both directions until `HALF_CLOSE` / `CLOSE` / `RESET`.

Lost application streams are not resumed after a broker-session reconnect. The caller and agent may open new streams on a new session. Deliberate agent shutdown sends `UNREGISTER` for owned names when the connection is still usable; broker session teardown remains the cleanup guarantee if that courtesy fails.

The broker’s idle timeout is a **session** timeout (no inbound frames). `--stream-idle-timeout` (default off) RESET a relay stream with `TIMEOUT` (numeric `15`) when it has no `DATA` / `HALF_CLOSE` / `OPEN_OK` for that long. Opening streams that never receive `OPEN_OK` expire the same way (`CONNECT_FAILED` / `TIMEOUT` to the caller). With the timeout at `0`, streams may stay open until peer `CLOSE` / `RESET`, session timeout, drain, or disconnect.

Operators distinguish common failures from structured logs (`error_code` plus `event`) and labeled Prometheus counters on `--metrics-listen`, not from diagnostic strings. `/healthz` is process liveness; `/readyz` is false while the broker is draining or not yet listening. Agent reconnect remains an agent-side log (`reconnect_scheduled`); the broker does not count reconnects separately from a new session.

## 9. Capability bits

Version 1.0 sends `capability_bits = 0`. Bits are reserved. A future minor version may assign bits without changing the header layout. Peers MUST NOT assume unknown bits are safe to ignore until a version defines that behavior; Version 1.0 has no assigned bits.

## 10. Compatibility

Breaking wire changes require a major version increment. Backward-compatible additions may increment `PROTOCOL_MINOR` or assign capability bits.

The project version (`--version`, `VERSION.txt`) is independent of this protocol version. See [COMPATIBILITY.md](COMPATIBILITY.md).

JSON is not used on this protocol. JSON MAY appear in diagnostics, configuration, or admin APIs elsewhere.

## 11. Public Web Ingress (informative)

A public `thirp-web-ingress` process consumes Version 1 as a Caller. It HELLO as role Caller, AUTHENTICATE with its own credential, and CONNECT to a configured `ServiceId`. Browser HTTP and TLS bytes are application payload on `DATA`. This section is not normative for the wire protocol. Do not add HTTP opcodes, hostnames, or cookies to Version 1 frames.
