# Thirp Runtime SDK

Application developers consume Agent and Caller from Odin source packages or the C ABI. Hosted Broker vendors consume the same collection layout plus `auth` and `broker`. This guide is the copyable reference. Wire behavior is [PROTOCOL.md](PROTOCOL.md). Compatibility policy is [COMPATIBILITY.md](COMPATIBILITY.md). The supported Agent/Caller symbol list is [sdk-public-api.txt](sdk-public-api.txt).

Join codes identify a service; they are not credentials. AUTH still uses a token.

## Two artifacts

One project version, two tarballs. There is no third “foundation SDK.” `protocol`, `transport`, and `logging` are a layer inside both artifacts. Protocol 1.0 is unchanged.

`thirp-runtime-sdk-<VERSION>.tar.gz` is the embed SDK: Odin `agent` and `caller` plus their compile closure, Linux `libthirp.so`, and C examples. It does not include Broker, `auth`, CLIs, Web Ingress, or operator configuration.

`thirp-runtime-broker-<VERSION>.tar.gz` is the Broker Odin collection: the embed SDK Odin packages plus `auth` and `broker` (non-test sources). It has no C ABI, CLIs, tests, `config`, `web_ingress`, or `version`. One collection compiles Agent and Broker together.

Sibling checkout is still the repository root. Do not vendor a full git checkout when the tarball is the contract.

## Collection mapping

Odin consumers import packages from a `thirp` collection. The same import paths work in sibling checkout and from an extracted artifact.

```odin
import thirp_agent "thirp:agent"
import thirp_caller "thirp:caller"
import proto "thirp:protocol"
import trans "thirp:transport"
```

Broker collection consumers also import:

```odin
import thirp_auth "thirp:auth"
import thirp_broker "thirp:broker"
```

Sibling checkout (repository root is the collection root):

```bash
odin build ./my_app -collection:thirp=../thirp-runtime
```

Extracted embed SDK:

```bash
odin build ./my_app \
  -collection:thirp=/opt/thirp-runtime-sdk-<VERSION>/odin/thirp
```

Extracted Broker collection:

```bash
odin build ./my_app \
  -collection:thirp=/opt/thirp-runtime-broker-<VERSION>/odin/thirp
```

Pinned vendor snapshot: copy the chosen artifact’s `odin/thirp` tree (plus `LICENSE`, `NOTICE`, the manifest, and a recorded version/checksum). Do not copy the full repository.

Internal library files keep relative imports (`import proto "../protocol"`). Consumers and examples use `thirp:` collection imports only.

## Agent

`agent_init` copies config. `agent_run` blocks: it dials the Broker, authenticates as Agent, registers the desired set, and relays. Start it on a thread. `agent_stop` unblocks `agent_run`. `agent_destroy` stops and frees. There is no `agent_start`.

```odin
broker_ep, berr := trans.parse_endpoint("127.0.0.1:9000")
agent: ag.Agent
err := ag.agent_init(&agent, ag.AgentConfig{
	broker   = broker_ep,
	token    = token,          // read from a file in production
	tls_ca   = "broker.crt",   // empty → system CA bundle
	insecure = false,
})
defer ag.agent_destroy(&agent)

th := thread.create_and_start_with_poly_data(&agent, proc(a: ^ag.Agent) {
	_ = ag.agent_run(a)
})
defer {
	ag.agent_stop(&agent)
	thread.join(th)
	thread.destroy(th)
}

id, _ := proto.make_service_id("acme/site-17/reporting-api")
_ = ag.register_service(&agent, id, ag.LocalTarget{address = target})
_ = ag.unregister_service(&agent, id)
```

Ephemeral hosting generates an 8-character join code and registers `namespace/code`:

```odin
hosting, err := ag.host_ephemeral(&agent, ag.EphemeralConfig{
	namespace     = "game",
	local_address = target,
})
defer ag.hosting_destroy(&hosting)
// print hosting.join_code and string(hosting.service_id); never print token
```

TLS: omit `tls_ca` to verify the Broker against the system CA bundle. Set `tls_server_name` when the certificate name is not the host in `broker`. `insecure` is plaintext and cannot be combined with TLS fields. Development plaintext is loopback-only.

The library takes a token string. Read `--token-file` yourself (mode `0600`). Do not pass long-lived secrets on a command line.

## Caller

`caller_init` dials the Broker, authenticates as Caller, and starts the session reader. There is no `caller_stop`; `caller_destroy` is shutdown. `dial` and `dial_join_code` return a `Conn` with blocking `conn_read` / `conn_write`. `conn_half_close` stops writes. `conn_close` / `conn_destroy` finish the stream.

```odin
c: cl.Caller
err := cl.caller_init(&c, cl.CallerConfig{
	broker   = broker_ep,
	token    = token,
	tls_ca   = "broker.crt",
	insecure = false,
})
defer cl.caller_destroy(&c)

conn, derr := cl.dial_join_code(&c, "game", join_code)
defer cl.conn_destroy(conn)
n, werr := cl.conn_write(conn, payload)
n, rerr := cl.conn_read(conn, buf[:])
cl.conn_close(conn)
```

The Caller reconnects the Broker session after transient loss. In-flight `Conn` streams do not resume; they fail. A later `dial` can open a new stream.

## Shutdown order

Agent: `unregister_service` for names you still own (optional courtesy), then `agent_stop`, join the `agent_run` thread, then `agent_destroy`. Destroy is idempotent with stop.

Caller: `conn_close` / `conn_destroy` for live streams, then `caller_destroy`.

## C ABI

Linux shared library only. Header `c/include/thirp.h`, library `c/lib/linux-<arch>/libthirp.so`. Links system OpenSSL 3 (`libssl` / `libcrypto`). No static library. No versioned soname.

```bash
cc -o echo_client examples/c/echo_client/echo_client.c \
  -I /opt/thirp-runtime-sdk-<VERSION>/c/include \
  -L /opt/thirp-runtime-sdk-<VERSION>/c/lib/linux-x86_64 \
  -lthirp -Wl,-rpath,/opt/thirp-runtime-sdk-<VERSION>/c/lib/linux-x86_64
```

`thirp_conn_read` and `thirp_conn_write` may block. Branch on integer error codes, not message text. Opaque handles; call the matching destroy.

If the dynamic linker cannot find `libthirp.so`, set `LD_LIBRARY_PATH` to the `c/lib/linux-<arch>` directory or embed rpath as above. If TLS fails at runtime, install OpenSSL 3 and confirm `ldd libthirp.so` shows `libssl` and `libcrypto`.

## Examples

SDK examples live in the artifact under `examples/`. In this repository they are [examples/sdk/](../examples/sdk/).

```bash
odin build examples/sdk/odin/ephemeral_host -collection:thirp=.
odin build examples/sdk/odin/join_code_client -collection:thirp=.
```

`ephemeral_host` starts a loopback echo target, calls `host_ephemeral`, prints `join_code` and `service_id`, and exits on SIGINT/SIGTERM after unregister. `join_code_client` dials that code and exchanges a payload.
