package caller

import "core:crypto"
import "core:time"

reconnect_backoff :: proc(attempt: int) -> time.Duration {
	n := attempt
	if n < 0 {
		n = 0
	}
	ms: i64 = 250
	for i in 0 ..< n {
		if ms >= 15000 {
			ms = 15000
			break
		}
		next := ms * 2
		if next > 15000 || next < ms {
			ms = 15000
			break
		}
		ms = next
	}
	if ms > 15000 {
		ms = 15000
	}
	return time.Duration(ms) * time.Millisecond
}

reconnect_delay :: proc(attempt: int, jitter: u64) -> time.Duration {
	d := reconnect_backoff(attempt)
	if d > RECONNECT_MAX {
		d = RECONNECT_MAX
	}
	half := d / 2
	if half <= 0 {
		return d
	}
	span := u64(half)
	j := time.Duration(jitter % (span + 1))
	return half + j
}

jitter_u64 :: proc() -> u64 {
	buf: [8]u8
	crypto.rand_bytes(buf[:])
	v: u64
	for b in buf {
		v = (v << 8) | u64(b)
	}
	return v
}
