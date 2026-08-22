# Hard races

These fail on a 24-thread `odin test . -all-packages` and usually pass in isolation or on a single lucky suite. One green run is not evidence. Do not “fix” them by raising a timeout, adding a sleep, or giving up on `wait_idle` after N seconds.

Killing the `odin test` shell or a `| tail` pipeline does not kill `*.bin` workers. Check `pgrep -a web_ingress.bin` (and other test binaries) before blaming the next change.

## TLS poll: FIN + data in one wakeup

**Symptom:** `web_ingress.test_unauthorized_connect_returns_403` (also other HTTP-error tests). `ok` is false; `head` is empty or not a complete status line. Isolation passes.

**Cause:** `tls_poll` treated `POLLHUP` / `POLLERR` as `.Closed` even when `POLLIN` (or `POLLOUT`) was set. The server writes the error and shuts down. The 403 TLS record and the FIN arrive together. The client returns Closed without `SSL_read` and drops the response.

**Fix:** `transport/tls.odin` `tls_poll` — if the requested event is ready, return `.None`. `POLLHUP` without data is still Closed. `POLLNVAL` is always Closed.

**Regression test:** `transport.test_tls_read_delivers_bytes_sent_before_shutdown` (reader blocked, then write + `SHUT_RDWR`).

## close() with an unread GET is RST

**Symptom:** Same 403/502/503 tests; client gets no headers.

**Cause:** Terminated HTTP writes the error before reading the request. `close()` on a socket with unread data is RST. The kernel can discard the error response the peer has not read yet.

**Fix:** `web_ingress/http_error.odin` `write_http_error` — after a successful write, `connection_shutdown_both` so unread request bytes are discarded and the close is a FIN.

## SSL_free must not own the fd

**Symptom:** Parallel TLS tests flake; a live connection dies for no local reason.

**Cause:** `SSL_set_fd` defaults to `BIO_CLOSE`. `SSL_free` closes the fd, then `connection_close` calls `net.close` on the same number. Under load that number is already a new socket.

**Fix:** `transport/openssl.odin` `ssl_set_fd_noclose`. The `Connection` owns the socket.

## Drain must not SSL_free from another thread

**Symptom:** `web_ingress.test_ingress_drain_waits_then_closes_established` — `active_conns` stays 1. Leftover `web_ingress.bin` after a “killed” test run; fans spin.

**Cause:** Connection workers are `thread.run_with_poly_data` (no join handle). Destroy waits on `active_conns`. A keep-alive pump sits in `SSL_read` / `poll`. `connection_close` / `SSL_free` from the drain thread does not reliably unblock that. A 3s destroy timeout only lets the test function return.

**Fix:** `transport/tcp.odin` `connection_shutdown_both` — `SHUT_RDWR` and `conn.closed`, no `SSL_free`. The owner thread still runs `connection_destroy`. Ingress drain/force-close uses that.

## StreamEcho origin 2s recv timeout

**Symptom:** `web_ingress.test_terminated_large_stream_echo_without_whole_body_buffer` — `got` 0 (or short). The test writes 16 KiB, then reads response headers before sending the rest.

**Cause:** The origin fixture set `SO_RCVTIMEO` to 2s on every connection. Under a loaded suite the header-read pause exceeds 2s. The origin closes. `read_job.got` was only set on full success, so a short echo printed 0.

**Fix:** `web_ingress/fixture_test.odin` `http_origin_serve` — StreamEcho uses recv timeout 0. `read_n_bytes` keeps the partial length on failure.

## Agent→caller stream buffer RESET

**Symptom:** Same large-stream test — `got` 163840 (10 × 16 KiB) not 1 MiB. Happens after many full-suite runs.

**Cause:** Default `max_stream_buffer` is 256 KiB. Caller→agent DATA waits when the outbox is full. Agent→caller DATA RESET immediately. A slow browser reader (TLS mutex shared with the writer) lets the echo path hit 256 KiB. The client has already received some flushed bytes; the rest is dropped.

**Fix:** `broker/conn.odin` `conn_enqueue_stream` — wait for stream space on both directions. A single frame larger than the cap still RESET (`test_limits_stream_buffer_overflow_resets_one_stream`).
