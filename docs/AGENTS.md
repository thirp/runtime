# Working in this tree

Thirp Runtime is the open-source named-Service data plane. Protocol 1.0 is frozen: do not add opcodes, wire fields, or peer-visible error codes.

## Tests

A sleep, a longer grace, a destroy timeout that gives up, or a poll loop that waits out a handshake is not a fix. Unblock the thread or close the right fd.

A `+++ leak` line is a failure even when the process exits 0. Free with the same allocator that allocated.

Run `odin test . -all-packages` from the repository root. Report thread count, pass/fail counts, and whether any test logged `+++ leak`.

## Protocol constants

Error codes and messages, HTTP methods/status/headers/media types, JSON field names, query keys, wire enum strings, and route paths are declared once as `SCREAMING_SNAKE` constants. Call sites use those names.

## Names

Product `-out:` / installed command names are kebab-case (`thirp-broker`, `thirp-agent`, `thirp-connect`). Packages, procs, types, C ABI, metrics, and env vars stay snake_case.
