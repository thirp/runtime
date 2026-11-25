# Local TLS quickstart

Run the complete Thirp Runtime relay locally on Linux, macOS or Windows:

```text
curl → thirp-connect → thirp-broker ← thirp-agent → private HTTP service
```

The Agent and Caller both connect to the Broker over TLS. The Agent publishes
the logical service `demo/http`; the Caller exposes that service at
`127.0.0.1:8000`. All application-side listeners are loopback-only, and the
Agent initiates the Broker connection.

The example credentials and certificate are for loopback testing only.

## Prerequisites

- A Linux, macOS or Windows machine
- OpenSSL 3 command-line tools
- Python 3 for the private HTTP fixture
- `curl`

Building instead of downloading also requires
[Odin](https://odin-lang.org/) `dev-2026-07` or later and OpenSSL 3 development
files. See [DEPENDENCIES.md](DEPENDENCIES.md).

## 1. Get the Runtime binaries

On Linux x86_64, use the operator archive if it is available for your tag.
Verify the checksums from the extracted directory. [Release archives](BUILDING.md#release-archives)

```bash
tar -xzf thirp-runtime-linux-x86_64-0.16.16.tar.gz
cd thirp-runtime-linux-x86_64-0.16.16
sha256sum -c SHA256SUMS
```

On macOS, use the full local build and open each terminal in the output
directory printed by the build. On Windows, use the three direct Odin build
commands. On Linux you can also build all three from source.
[Build command-line components](BUILDING.md#build-command-line-components)

The shell examples below use Bash syntax. On Windows, open each PowerShell
terminal in the build directory. Add the OpenSSL 3 `bin` directory to `PATH`
in each terminal so the `openssl` command and DLLs are available. Adjust the
path for your installation.

```powershell
$env:Path = "C:\Program Files\OpenSSL\bin;$env:Path"
```

In PowerShell, use `curl.exe` and `py -3` (or `python`) for the HTTP service.
Run each Runtime binary by its `.exe` name, such as `.\thirp-broker.exe`.
Put each command on one line or replace Bash's trailing backslashes with
PowerShell backticks.

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

Terminal 2. Create an empty `demo-origin` directory before starting the server.

```bash
python3 -m http.server 7000 --bind 127.0.0.1 --directory demo-origin
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

Stop the Agent, then repeat the HTTP request. It fails while the service is
unregistered. Start the Agent again and retry with a new HTTP connection.
[Session recovery](OPERATIONS.md#session-recovery)

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
