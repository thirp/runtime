package broker

import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

MAX_RATE_LIMIT_KEYS :: 8192

RateLimitConfig :: struct {
	burst:  int,
	window: time.Duration,
}

TokenBucket :: struct {
	tokens:      f64,
	last_refill: time.Time,
}

RateLimiters :: struct {
	mutex:              sync.Mutex,
	allocator:          mem.Allocator,
	max_keys:           int,
	auth_ip:            map[IpKey]TokenBucket,
	register_principal: map[string]TokenBucket,
	connect_principal:  map[string]TokenBucket,
	connect_ip:         map[IpKey]TokenBucket,
}

rate_limit_config :: proc(burst: int, window: time.Duration) -> RateLimitConfig {
	w := window
	if w <= 0 {
		w = DEFAULT_RATE_LIMIT_WINDOW
	}
	return RateLimitConfig{burst = burst, window = w}
}

rate_limit_unlimited :: proc(cfg: RateLimitConfig) -> bool {
	return cfg.burst <= 0
}

rate_limiters_init :: proc(lim: ^RateLimiters, allocator := context.allocator) {
	lim^ = {}
	lim.allocator = allocator
	lim.max_keys = MAX_RATE_LIMIT_KEYS
	lim.auth_ip = make(map[IpKey]TokenBucket, allocator)
	lim.register_principal = make(map[string]TokenBucket, allocator)
	lim.connect_principal = make(map[string]TokenBucket, allocator)
	lim.connect_ip = make(map[IpKey]TokenBucket, allocator)
}

rate_limiters_destroy :: proc(lim: ^RateLimiters) {
	if lim == nil {
		return
	}
	rate_limit_free_principal_map(&lim.register_principal, lim.allocator)
	rate_limit_free_principal_map(&lim.connect_principal, lim.allocator)
	delete(lim.auth_ip)
	delete(lim.connect_ip)
	lim.auth_ip = {}
	lim.register_principal = {}
	lim.connect_principal = {}
	lim.connect_ip = {}
}

rate_limit_free_principal_map :: proc(table: ^map[string]TokenBucket, allocator: mem.Allocator) {
	if table == nil {
		return
	}
	for key in table {
		delete(key, allocator)
	}
	delete(table^)
}

token_bucket_refill :: proc(b: ^TokenBucket, cfg: RateLimitConfig, now: time.Time) {
	if cfg.burst <= 0 || cfg.window <= 0 {
		b.tokens = f64(cfg.burst)
		b.last_refill = now
		return
	}
	elapsed := time.diff(b.last_refill, now)
	if elapsed <= 0 {
		return
	}
	add := f64(cfg.burst) * f64(elapsed) / f64(cfg.window)
	next := b.tokens + add
	cap := f64(cfg.burst)
	if next > cap {
		next = cap
	}
	b.tokens = next
	b.last_refill = now
}

token_bucket_available :: proc(b: TokenBucket, cfg: RateLimitConfig, now: time.Time) -> bool {
	tmp := b
	token_bucket_refill(&tmp, cfg, now)
	return tmp.tokens >= 1
}

token_bucket_take :: proc(b: ^TokenBucket, cfg: RateLimitConfig, now: time.Time) -> bool {
	token_bucket_refill(b, cfg, now)
	if b.tokens < 1 {
		return false
	}
	b.tokens -= 1
	return true
}

rate_limit_max_keys :: proc(lim: ^RateLimiters) -> int {
	if lim.max_keys <= 0 {
		return MAX_RATE_LIMIT_KEYS
	}
	return lim.max_keys
}

rate_limit_prune_ip :: proc(table: ^map[IpKey]TokenBucket, cfg: RateLimitConfig, now: time.Time) {
	idle: [dynamic]IpKey
	defer delete(idle)
	for key, bucket in table {
		tmp := bucket
		token_bucket_refill(&tmp, cfg, now)
		if tmp.tokens >= f64(cfg.burst) {
			append(&idle, key)
		}
	}
	for key in idle {
		delete_key(table, key)
	}
}

rate_limit_prune_principal :: proc(
	table: ^map[string]TokenBucket,
	cfg: RateLimitConfig,
	now: time.Time,
	allocator: mem.Allocator,
) {
	idle: [dynamic]string
	defer delete(idle)
	for key, bucket in table {
		tmp := bucket
		token_bucket_refill(&tmp, cfg, now)
		if tmp.tokens >= f64(cfg.burst) {
			append(&idle, key)
		}
	}
	for key in idle {
		delete_key(table, key)
		delete(key, allocator)
	}
}

rate_limit_ip_get_or_insert :: proc(
	lim: ^RateLimiters,
	table: ^map[IpKey]TokenBucket,
	cfg: RateLimitConfig,
	key: IpKey,
	now: time.Time,
) -> (
	^TokenBucket,
	bool,
) {
	if key in table {
		return &table[key], true
	}
	max_keys := rate_limit_max_keys(lim)
	if len(table) >= max_keys {
		rate_limit_prune_ip(table, cfg, now)
	}
	if len(table) >= max_keys {
		return nil, false
	}
	table[key] = TokenBucket {
		tokens      = f64(cfg.burst),
		last_refill = now,
	}
	return &table[key], true
}

rate_limit_principal_get_or_insert :: proc(
	lim: ^RateLimiters,
	table: ^map[string]TokenBucket,
	cfg: RateLimitConfig,
	principal: string,
	now: time.Time,
) -> (
	^TokenBucket,
	bool,
) {
	if principal in table {
		return &table[principal], true
	}
	max_keys := rate_limit_max_keys(lim)
	if len(table) >= max_keys {
		rate_limit_prune_principal(table, cfg, now, lim.allocator)
	}
	if len(table) >= max_keys {
		return nil, false
	}
	cloned, err := strings.clone(principal, lim.allocator)
	if err != .None {
		return nil, false
	}
	table[cloned] = TokenBucket {
		tokens      = f64(cfg.burst),
		last_refill = now,
	}
	return &table[cloned], true
}

rate_limit_auth_available :: proc(lim: ^RateLimiters, cfg: RateLimitConfig, ip: IpKey) -> bool {
	if rate_limit_unlimited(cfg) {
		return true
	}
	sync.mutex_lock(&lim.mutex)
	defer sync.mutex_unlock(&lim.mutex)
	now := time.now()
	if ip in lim.auth_ip {
		return token_bucket_available(lim.auth_ip[ip], cfg, now)
	}
	max_keys := rate_limit_max_keys(lim)
	if len(lim.auth_ip) >= max_keys {
		rate_limit_prune_ip(&lim.auth_ip, cfg, now)
	}
	return len(lim.auth_ip) < max_keys
}

rate_limit_auth_take :: proc(lim: ^RateLimiters, cfg: RateLimitConfig, ip: IpKey) -> bool {
	if rate_limit_unlimited(cfg) {
		return true
	}
	sync.mutex_lock(&lim.mutex)
	defer sync.mutex_unlock(&lim.mutex)
	now := time.now()
	bucket, ok := rate_limit_ip_get_or_insert(lim, &lim.auth_ip, cfg, ip, now)
	if !ok {
		return false
	}
	return token_bucket_take(bucket, cfg, now)
}

rate_limit_register_take :: proc(lim: ^RateLimiters, cfg: RateLimitConfig, principal: string) -> bool {
	if rate_limit_unlimited(cfg) {
		return true
	}
	sync.mutex_lock(&lim.mutex)
	defer sync.mutex_unlock(&lim.mutex)
	now := time.now()
	bucket, ok := rate_limit_principal_get_or_insert(lim, &lim.register_principal, cfg, principal, now)
	if !ok {
		return false
	}
	return token_bucket_take(bucket, cfg, now)
}

rate_limit_connect_take :: proc(
	lim: ^RateLimiters,
	cfg: RateLimitConfig,
	principal: string,
	ip: IpKey,
) -> bool {
	if rate_limit_unlimited(cfg) {
		return true
	}
	sync.mutex_lock(&lim.mutex)
	defer sync.mutex_unlock(&lim.mutex)
	now := time.now()
	p_bucket, p_ok := rate_limit_principal_get_or_insert(lim, &lim.connect_principal, cfg, principal, now)
	if !p_ok {
		return false
	}
	ip_bucket, ip_ok := rate_limit_ip_get_or_insert(lim, &lim.connect_ip, cfg, ip, now)
	if !ip_ok {
		return false
	}
	if !token_bucket_available(p_bucket^, cfg, now) || !token_bucket_available(ip_bucket^, cfg, now) {
		return false
	}
	_ = token_bucket_take(p_bucket, cfg, now)
	_ = token_bucket_take(ip_bucket, cfg, now)
	return true
}

server_auth_rate_available :: proc(server: ^Server, ip: IpKey) -> bool {
	if server == nil {
		return true
	}
	return rate_limit_auth_available(&server.rate_limits, server.auth_rate, ip)
}

server_auth_rate_take :: proc(server: ^Server, ip: IpKey) -> bool {
	if server == nil {
		return true
	}
	return rate_limit_auth_take(&server.rate_limits, server.auth_rate, ip)
}

server_register_rate_take :: proc(server: ^Server, principal: string) -> bool {
	if server == nil {
		return true
	}
	return rate_limit_register_take(&server.rate_limits, server.register_rate, principal)
}

server_connect_rate_take :: proc(server: ^Server, principal: string, ip: IpKey) -> bool {
	if server == nil {
		return true
	}
	return rate_limit_connect_take(&server.rate_limits, server.connect_rate, principal, ip)
}

server_disable_test_hardening :: proc(server: ^Server) {
	if server == nil {
		return
	}
	server.auth_rate = rate_limit_config(0, DEFAULT_RATE_LIMIT_WINDOW)
	server.register_rate = rate_limit_config(0, DEFAULT_RATE_LIMIT_WINDOW)
	server.connect_rate = rate_limit_config(0, DEFAULT_RATE_LIMIT_WINDOW)
	server.max_buffered_bytes = 0
	server.stream_idle_timeout = 0
}

server_try_add_buffered_bytes :: proc(server: ^Server, n: int) -> bool {
	if server == nil || n <= 0 {
		return true
	}
	max := server.max_buffered_bytes
	if max <= 0 {
		return true
	}
	for {
		cur := sync.atomic_load(&server.buffered_bytes)
		next := cur + i64(n)
		if next > i64(max) {
			return false
		}
		_, ok := sync.atomic_compare_exchange_strong(&server.buffered_bytes, cur, next)
		if ok {
			return true
		}
	}
}

server_sub_buffered_bytes :: proc(server: ^Server, n: int) {
	if server == nil || n <= 0 {
		return
	}
	for {
		cur := sync.atomic_load(&server.buffered_bytes)
		next := cur - i64(n)
		if next < 0 {
			next = 0
		}
		_, ok := sync.atomic_compare_exchange_strong(&server.buffered_bytes, cur, next)
		if ok {
			return
		}
	}
}

server_global_buffer_at_ceiling :: proc(server: ^Server) -> bool {
	if server == nil || server.max_buffered_bytes <= 0 {
		return false
	}
	return sync.atomic_load(&server.buffered_bytes) >= i64(server.max_buffered_bytes)
}
