package broker

import "core:testing"
import "core:time"

test_ip :: proc(n: u8) -> IpKey {
	key: IpKey
	key.kind = 4
	key.bytes[0] = n
	key.bytes[3] = 1
	return key
}

@(test)
test_rate_limit_take_until_burst :: proc(t: ^testing.T) {
	lim: RateLimiters
	rate_limiters_init(&lim)
	defer rate_limiters_destroy(&lim)
	cfg := rate_limit_config(2, time.Hour)
	ip := test_ip(1)
	testing.expect(t, rate_limit_auth_take(&lim, cfg, ip))
	testing.expect(t, rate_limit_auth_take(&lim, cfg, ip))
	testing.expect(t, !rate_limit_auth_take(&lim, cfg, ip))
	testing.expect(t, !rate_limit_auth_available(&lim, cfg, ip))
}

@(test)
test_rate_limit_refill_after_window :: proc(t: ^testing.T) {
	lim: RateLimiters
	rate_limiters_init(&lim)
	defer rate_limiters_destroy(&lim)
	cfg := rate_limit_config(2, 50 * time.Millisecond)
	ip := test_ip(2)
	testing.expect(t, rate_limit_auth_take(&lim, cfg, ip))
	testing.expect(t, rate_limit_auth_take(&lim, cfg, ip))
	testing.expect(t, !rate_limit_auth_take(&lim, cfg, ip))
	time.sleep(80 * time.Millisecond)
	testing.expect(t, rate_limit_auth_take(&lim, cfg, ip))
}

@(test)
test_rate_limit_burst_zero_unlimited :: proc(t: ^testing.T) {
	lim: RateLimiters
	rate_limiters_init(&lim)
	defer rate_limiters_destroy(&lim)
	cfg := rate_limit_config(0, time.Minute)
	ip := test_ip(3)
	for _ in 0 ..< 20 {
		testing.expect(t, rate_limit_auth_take(&lim, cfg, ip))
		testing.expect(t, rate_limit_register_take(&lim, cfg, "alice"))
		testing.expect(t, rate_limit_connect_take(&lim, cfg, "alice", ip))
	}
}

@(test)
test_rate_limit_map_cap_fail_closes :: proc(t: ^testing.T) {
	lim: RateLimiters
	rate_limiters_init(&lim)
	defer rate_limiters_destroy(&lim)
	lim.max_keys = 2
	cfg := rate_limit_config(1, time.Hour)
	testing.expect(t, rate_limit_auth_take(&lim, cfg, test_ip(1)))
	testing.expect(t, rate_limit_auth_take(&lim, cfg, test_ip(2)))
	testing.expect(t, !rate_limit_auth_take(&lim, cfg, test_ip(3)))
	testing.expect(t, !rate_limit_auth_available(&lim, cfg, test_ip(3)))
}

@(test)
test_rate_limit_principal_destroy_frees_keys :: proc(t: ^testing.T) {
	lim: RateLimiters
	rate_limiters_init(&lim)
	cfg := rate_limit_config(4, time.Hour)
	testing.expect(t, rate_limit_register_take(&lim, cfg, "alice"))
	testing.expect(t, rate_limit_connect_take(&lim, cfg, "bob", test_ip(9)))
	testing.expect_value(t, len(lim.register_principal), 1)
	testing.expect_value(t, len(lim.connect_principal), 1)
	rate_limiters_destroy(&lim)
	testing.expect_value(t, len(lim.register_principal), 0)
	testing.expect_value(t, len(lim.connect_principal), 0)
}

@(test)
test_server_accept_error_is_fatal :: proc(t: ^testing.T) {
	server: Server
	testing.expect(t, server_accept_error_is_fatal(&server, .Closed))
	testing.expect(t, !server_accept_error_is_fatal(&server, .Network))
	testing.expect(t, !server_accept_error_is_fatal(&server, .Timeout))
	server.stop = true
	testing.expect(t, server_accept_error_is_fatal(&server, .Network))
}
