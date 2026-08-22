# Security policy

Report vulnerabilities in Thirp Runtime to `security@thirp.net`.

Do not open a public GitHub issue for an unfixed vulnerability.

- Product and design-partner questions: `partners@thirp.net`
- Privacy: `privacy@thirp.net`

`security@thirp.net` is not the pilot-intake mailbox.

## Release signing

Release `SHA256SUMS` files may include a detached signature `SHA256SUMS.asc`. The Thirp publish key fingerprint is:

```text
3B8559D8754FB3C5B21110C786897A405CF3D8C4
```

Verify with `gpg --verify SHA256SUMS.asc SHA256SUMS`. See [SECURITY.md](../docs/SECURITY.md) for the self-hosted threat model.
