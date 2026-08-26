# Local TLS quickstart

This walkthrough proves the complete Thirp Runtime relay path on one Linux
machine:

```text
curl → thirp-connect → thirp-broker ← thirp-agent → private HTTP service
```

The Agent and Caller both connect to the Broker over TLS. The Agent publishes
the logical service `demo/http`; the Caller exposes that service at
`127.0.0.1:8000`. All application-side listeners are loopback-only, and the
Agent initiates the Broker connection.

The example credentials and certificate are for loopback testing only.

## Prerequisites

- Linux
- OpenSSL 3 command-line tools
- Python 3 for the private HTTP fixture
- `curl`

Building instead of downloading also requires
[Odin](https://odin-lang.org/) `dev-2026-07` or later and OpenSSL 3 development
files. See [DEPENDENCIES.md](DEPENDENCIES.md).

## 1. Get the Runtime binaries

### Download the Linux release

Download these files from the
[latest GitHub release](https://github.com/thirp/runtime/releases/latest):

- `thirp-broker`
- `thirp-agent`
- `thirp-connect`
- `SHA256SUMS`
- `SHA256SUMS.asc` when the release is signed

Place them in one directory, verify the downloaded artifacts, and make the
binaries executable:

```bash
sha256sum --ignore-missing -c SHA256SUMS
chmod +x thirp-broker thirp-agent thirp-connect
```

When `SHA256SUMS.asc` is present, verify it using the publish-key fingerprint
and command in [SECURITY.md](SECURITY.md#release-signing).

### Or build from source

Run from the repository root:

```bash
odin build broker_cli -out:thirp-broker
odin build agent_cli -out:thirp-agent
odin build caller_cli -out:thirp-connect
```

For the full build, test, C ABI, and packaging workflow, see
[BUILDING.md](BUILDING.md).

## 2. Create a loopback certificate

The certificate SAN includes `127.0.0.1`, which is the Broker address used by
the clients:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout broker.key -out broker.crt \
  -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
```

## 3. Start the Broker

Terminal 1:

```bash
./thirp-broker --listen 127.0.0.1:9000 \
  --tls-cert broker.crt --tls-key broker.key \
  --token agent-dev-token=agent-a \
  --token caller-dev-token=caller-a \
  --metrics-listen 127.0.0.1:9090
```

This flags-only launch uses development policy after enforcing Agent and Caller
roles. It is intentionally convenient for a loopback demo. Production
deployments use separate token files and explicit deny-by-default grants.

## 4. Start the private service

Terminal 2:

```bash
python3 -m http.server 7000 --bind 127.0.0.1 --directory /tmp
```

Treat this as the private service that a real product would provide.

## 5. Publish the service

Terminal 3:

```bash
./thirp-agent --broker 127.0.0.1:9000 --tls-ca broker.crt \
  --token agent-dev-token \
  --service demo/http \
  --target 127.0.0.1:7000
```

The Agent connects outbound to the Broker and registers `demo/http`. The
service name is a locator, not a credential.

## 6. Expose the authorized service locally

Terminal 4:

```bash
./thirp-connect --broker 127.0.0.1:9000 --tls-ca broker.crt \
  --token caller-dev-token \
  --service demo/http \
  --listen 127.0.0.1:8000
```

Existing TCP tools can now use loopback port `8000`; they do not need to speak
the Thirp protocol.

## 7. Send a payload

Terminal 5:

```text
$ curl -I http://127.0.0.1:8000/
HTTP/1.0 200 OK
```

The HTTP request reaches the Python service through the Caller, Broker, and
Agent. Run several requests concurrently to exercise separate streams on the
same Agent and Caller sessions.

## Observe the Broker

The management listener is separate from the relay listener:

```bash
curl -s http://127.0.0.1:9090/healthz
curl -s http://127.0.0.1:9090/readyz
curl -s http://127.0.0.1:9090/metrics
```

The metrics/health listener has no TLS or authentication. Bind it only to
loopback or a protected management network.

## Test reconnect behavior

Stop Terminal 3 while an `nc` session is open:

- The active stream closes.
- The Broker removes the Agent-owned registration.
- A new Caller connection cannot reach `demo/http`.

Restart the Agent command. It reconnects and re-registers the desired service,
and a new `nc` connection succeeds. The old stream is not resumed.

## Plaintext loopback shortcut

For local development only, replace the Broker TLS flags and both client
`--tls-ca` flags with `--insecure`:

```bash
./thirp-broker --insecure --listen 127.0.0.1:9000 \
  --token agent-dev-token=agent-a \
  --token caller-dev-token=caller-a
```

Use `--insecure` on `thirp-agent` and `thirp-connect` as well. Never use this
mode on a public or untrusted network. Production policy cannot be combined
with plaintext mode.

## Next steps

- [Deploy least-privilege production policy](OPERATIONS.md#production-walkthrough)
- [Run the browser HTTPS demo](../web_ingress_cli/README.md#local-demo)
- [Embed Agent or Caller behavior](SDK.md)
- [Review the security model](SECURITY.md)
