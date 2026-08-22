# Security

Report vulnerabilities in Thirp Runtime to `security@thirp.net`. Do not open a public issue for an unfixed vulnerability. This is not the product-intake mailbox (`partners@thirp.net`). Privacy questions: `privacy@thirp.net`.

## Release signing

Release `SHA256SUMS` files may include a detached signature `SHA256SUMS.asc`. The Thirp publish key fingerprint is:

```text
3B8559D8754FB3C5B21110C786897A405CF3D8C4
```

Verify with `gpg --verify SHA256SUMS.asc SHA256SUMS`. Unsigned checksums are still usable; the signature is additional.

This document is the threat model for a self-hosted Thirp Runtime deployment. It is not an external assessment and does not claim that the software is qualified for hostile public SaaS.

The open-source release is production-capable self-hosted infrastructure: TLS, deny-by-default Broker policy, least-privilege credentials, and bounded resources. Completing parent PR-8 does not qualify Web Ingress for an untrusted Internet edge. Treat a public `thirp-web-ingress` listener as hostile-input software.

## Identities

Three identities stay separate:

```text
browser / application user
    authenticated only by the Origin Application

Ingress Principal
    a Caller credential used by thirp-web-ingress
    ConnectService only, exact allow_connect grants, no RegisterService

Agent principal
    RegisterService for the services it owns
```

A configured public hostname is a locator, not a credential. An unguessable-looking name may reduce accidental discovery. It is not access control.

Web Ingress never accepts its Broker bearer token from a browser request. Do not put tokens in flags on a production host; use `token_file` mode `0600`.

## Broker

The Broker remains application-opaque. It authorizes CONNECT and REGISTER from authenticated principals. It does not parse HTTP, cookies, or WebSocket frames.

Production policy is deny-by-default. An Ingress route is not a Broker grant. Configure an exact `allow_connect` for every published `ServiceId` unless an operator consciously chooses a bounded namespace grant.

Do not give the Ingress Principal all-service access or RegisterService.

## Web Ingress

`thirp-web-ingress` is an Internet-reachable Caller adapter. Browser clients are not Version 1 peers and are not authenticated by Thirp Runtime before the public listener.

The threat model covers:

```text
connection and TLS handshake floods
slow or oversized ClientHello
malformed TLS handshakes
SNI enumeration and unknown-host probing
slow reader and slow writer
long-lived idle connections
Broker CONNECT amplification
Ingress credential theft
route misconfiguration and overbroad grants
an Origin Application without its own authentication
Host-header attacks against the Origin
certificate or private-key compromise
log leakage of invitation URLs, cookies, or tokens
```

Required bounds (defaults): 4096 global browser connections, 64 per source IP, 10s ClientHello/TLS handshake, 10s Broker dial, 300s established idle (0 disables idle only), 15s shutdown grace. Handshake and dial timeouts cannot be disabled in production.

Web Ingress connects only to a `ServiceId` in its immutable route table. It does not accept a client-supplied destination, `ServiceId`, IP, port, URL, or HTTP CONNECT target.

Unknown or unpublished hostnames do not produce a helpful distinction from a missing route. Do not expose a route list.

When terminated TLS succeeds but a Thirp Runtime stream cannot be opened, browsers receive a fixed generic HTTP status (`421` / `403` / `429` / `502` / `503`) with `Connection: close`. Responses must not include `ServiceId`, principal, token, internal address, or Broker diagnostic text.

## Origin Application

A published route makes the Origin reachable by anyone who can complete TLS to that public hostname. The Origin MUST authenticate and authorize users unless it is intentionally public.

Configure the Origin to accept the public `Host`. Web Ingress does not rewrite `Host` to `localhost` and does not inject `Forwarded` / `X-Forwarded-*` headers.

Application invitation tokens, cookies, CSRF, and session expiry remain application data.

## Logging

Structured JSON logs may include connection id, canonical public host, `ServiceId`, source IP, mode, stable error reason, byte counts, and duration.

Logs must not include Broker tokens, request or response bodies, `Authorization` or `Cookie` values, invitation tokens, URL path or query by default, raw headers, raw ClientHello bytes, TLS keys, or browser-visible Broker diagnostics. The no-payload rule applies in debug mode.

## TLS

Production Web Ingress requires browser TLS except for an explicit loopback-only development mode. Terminated-mode keys stay on the Web Ingress host. Passthrough inspects a bounded ClientHello to obtain SNI (the public hostname is visible), then relays original TLS bytes; the Origin owns the certificate for that hostname. Do not distribute one wildcard private key to Agents. Do not log ClientHello bytes.

Broker-facing TLS reuses the existing Caller verification path. A public production Web Ingress must not use `--insecure-broker`.

## Residual risk

Metrics and health HTTP have no TLS and no authentication; bind them to loopback or a protected network.

This tree does not implement HTTP/2, a WAF, request rewriting, trusted client-IP propagation, or dynamic route revocation. There is no 24-hour soak and no external assessment. Connection churn (20 sequential), 8 concurrent GETs, backpressure isolation, Agent/Caller session loss, and ingress restart were measured in-process; counters returned to zero. That is qualification under those tests, not a capacity rating and not a claim that the software is assessed for hostile public SaaS.
