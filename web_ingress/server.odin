package web_ingress

import cl "../caller"
import log "../logging"
import trans "../transport"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

ingress_server_init :: proc(
	server: ^IngressServer,
	config: IngressConfig,
	logger: ^log.Logger,
	connect_broker := true,
) -> IngressError {
	if server == nil {
		return .Internal
	}
	server^ = {}
	server.allocator = context.allocator
	if config.allocator.procedure != nil {
		server.allocator = config.allocator
	}
	server.config = config
	server.logger = logger
	server.want_caller = connect_broker
	server.ip_conns = make(map[IngressIpKey]int, server.allocator)
	server.lives = make([dynamic]^IngressLiveConn, server.allocator)

	listen_ep, lerr := trans.parse_endpoint(config.listen)
	if lerr != .None {
		ingress_server_clear_allocs(server)
		return .InvalidConfiguration
	}

	if !config.insecure && ingress_config_has_terminated(config) {
		ctx, terr := trans.tls_server_context_init(config.tls_cert, config.tls_key, server.allocator)
		if terr != .None {
			ingress_server_clear_allocs(server)
			return .InvalidConfiguration
		}
		trans.tls_server_context_set_alpn_http11(ctx)
		server.tls_ctx = ctx
	}

	if connect_broker {
		broker_ep, berr := trans.parse_endpoint(config.broker)
		if berr != .None || broker_ep.port == 0 {
			ingress_server_clear_tls(server)
			ingress_server_clear_allocs(server)
			return .InvalidConfiguration
		}
		cerr := ingress_try_caller_init(server, broker_ep)
		if cerr != .None && cerr != .Transport && cerr != .AuthFailed {
			ingress_server_clear_tls(server)
			ingress_server_clear_allocs(server)
			if cerr == .InvalidConfig {
				return .InvalidConfiguration
			}
			return .Internal
		}
	}

	ln, nerr := trans.listener_listen(listen_ep)
	if nerr != .None {
		if server.caller_ok {
			cl.caller_destroy(&server.caller)
			server.caller_ok = false
		}
		ingress_server_clear_tls(server)
		ingress_server_clear_allocs(server)
		return .InvalidConfiguration
	}
	server.listener = ln
	server.listening = true
	_ = trans.listener_set_recv_timeout(&server.listener, ACCEPT_POLL_INTERVAL)

	if len(config.metrics_listen) > 0 {
		mep, merr := trans.parse_endpoint(config.metrics_listen)
		if merr == .None {
			_ = ingress_metrics_listen(server, mep)
			ingress_metrics_start(server)
		}
	}

	if connect_broker && !server.caller_ok {
		server.retry_thread = thread.create_and_start_with_poly_data(server, ingress_caller_retry_proc)
	}

	ingress_log(server, .Info, "ingress_started")
	if ingress_caller_usable(server) && server.listening && !ingress_is_draining(server) {
		ingress_log(server, .Info, "ingress_ready")
	}
	return .None
}

ingress_try_caller_init :: proc(server: ^IngressServer, broker_ep: net.Endpoint) -> cl.CallerError {
	cerr := cl.caller_init(
		&server.caller,
		cl.CallerConfig {
			broker          = broker_ep,
			token           = server.config.token,
			insecure        = server.config.insecure_broker,
			tls_ca          = server.config.tls_ca,
			tls_server_name = server.config.tls_server_name,
			implementation  = INGRESS_IMPLEMENTATION,
			logger          = server.logger,
			dial_timeout    = server.config.limits.broker_dial_timeout,
		},
	)
	if cerr != .None {
		return cerr
	}
	server.caller_ok = true
	server.dialer.ctx = &server.caller
	server.dialer.dial = ingress_caller_dial
	return .None
}

ingress_caller_retry_proc :: proc(server: ^IngressServer) {
	attempt := 0
	for !server.stop && !server.retry_stop && !server.caller_ok {
		delay := cl.reconnect_backoff(attempt)
		start := time.now()
		for time.since(start) < delay {
			if server.stop || server.retry_stop {
				return
			}
			time.sleep(INGRESS_RETRY_POLL_SLICE)
		}
		if server.stop || server.retry_stop || server.caller_ok {
			return
		}
		broker_ep, berr := trans.parse_endpoint(server.config.broker)
		if berr != .None {
			attempt += 1
			continue
		}
		if ingress_try_caller_init(server, broker_ep) == .None {
			ingress_log(server, .Info, "ingress_ready")
			return
		}
		attempt += 1
	}
}

ingress_server_endpoint :: proc(server: ^IngressServer) -> (net.Endpoint, trans.TransportError) {
	if server == nil || !server.listening {
		return {}, .Closed
	}
	return trans.listener_endpoint(server.listener)
}

ingress_server_start :: proc(server: ^IngressServer) {
	if server == nil {
		return
	}
	server.serve_thread = thread.create_and_start_with_poly_data(server, ingress_server_serve)
}

ingress_server_serve :: proc(server: ^IngressServer) {
	for {
		if server.stop || ingress_is_draining(server) {
			return
		}
		conn, err := trans.listener_accept(&server.listener, server.allocator)
		if err == .Timeout {
			continue
		}
		if server.stop || ingress_is_draining(server) {
			if conn != nil {
				trans.connection_destroy(conn, server.allocator)
			}
			return
		}
		if err != .None {
			return
		}
		slot := ingress_acquire_connection_slot(server, conn)
		if slot != .Ok {
			kind := slot == .ConnectionsPerIp ? LimitKind.ConnectionsPerIp : LimitKind.Connections
			metrics_inc_limit(&server.metrics, kind)
			metrics_inc_conn(&server.metrics, .Limit)
			ingress_log(
				server,
				.Warn,
				"connection_limit_rejected",
				log.LogFields {
					remote_address = net.endpoint_to_string(conn.remote),
					reason         = limit_kind_label(kind),
				},
			)
			trans.connection_destroy(conn, server.allocator)
			continue
		}
		arg, aerr := new(IngressConnArg, server.allocator)
		if aerr != .None {
			ingress_release_connection_slot(server, ingress_ip_key_from_endpoint(conn.remote))
			trans.connection_destroy(conn, server.allocator)
			continue
		}
		live, lerr := new(IngressLiveConn, server.allocator)
		if lerr != .None {
			free(arg, server.allocator)
			ingress_release_connection_slot(server, ingress_ip_key_from_endpoint(conn.remote))
			trans.connection_destroy(conn, server.allocator)
			continue
		}
		conn_id := sync.atomic_add(&server.next_conn_id, 1) + 1
		live.id = conn_id
		live.browser = conn
		arg.server = server
		arg.browser = conn
		arg.ip_key = ingress_ip_key_from_endpoint(conn.remote)
		arg.conn_id = conn_id
		arg.live = live
		ingress_live_add(server, live)
		ingress_conn_begin(server)
		thread.run_with_poly_data(arg, ingress_connection_proc)
	}
}

ingress_ip_key_from_endpoint :: proc(ep: net.Endpoint) -> IngressIpKey {
	key: IngressIpKey
	switch addr in ep.address {
	case net.IP4_Address:
		key.kind = 4
		key.bytes[0] = addr[0]
		key.bytes[1] = addr[1]
		key.bytes[2] = addr[2]
		key.bytes[3] = addr[3]
	case net.IP6_Address:
		key.kind = 6
		key.bytes = transmute([16]u8)addr
	}
	return key
}

ingress_acquire_connection_slot :: proc(server: ^IngressServer, conn: ^trans.Connection) -> IngressSlotResult {
	if server == nil || conn == nil {
		return .Connections
	}
	key := ingress_ip_key_from_endpoint(conn.remote)
	sync.mutex_lock(&server.limits_mutex)
	defer sync.mutex_unlock(&server.limits_mutex)
	max_conns := server.config.limits.max_connections
	if max_conns > 0 && server.slot_count >= max_conns {
		return .Connections
	}
	count := server.ip_conns[key]
	max_ip := server.config.limits.max_connections_per_ip
	if max_ip > 0 && count >= max_ip {
		return .ConnectionsPerIp
	}
	server.ip_conns[key] = count + 1
	server.slot_count += 1
	return .Ok
}

ingress_release_connection_slot :: proc(server: ^IngressServer, key: IngressIpKey) {
	if server == nil {
		return
	}
	sync.mutex_lock(&server.limits_mutex)
	defer sync.mutex_unlock(&server.limits_mutex)
	count := server.ip_conns[key]
	if count <= 1 {
		delete_key(&server.ip_conns, key)
	} else {
		server.ip_conns[key] = count - 1
	}
	if server.slot_count > 0 {
		server.slot_count -= 1
	}
}

ingress_conn_begin :: proc(server: ^IngressServer) {
	sync.mutex_lock(&server.conn_mutex)
	server.active_conns += 1
	sync.mutex_unlock(&server.conn_mutex)
	metrics_add_active(&server.metrics, 1)
}

ingress_conn_end :: proc(server: ^IngressServer, key: IngressIpKey) {
	ingress_release_connection_slot(server, key)
	sync.mutex_lock(&server.conn_mutex)
	if server.active_conns > 0 {
		server.active_conns -= 1
	}
	sync.cond_signal(&server.conn_cond)
	sync.mutex_unlock(&server.conn_mutex)
	metrics_add_active(&server.metrics, -1)
}

ingress_live_add :: proc(server: ^IngressServer, live: ^IngressLiveConn) {
	sync.mutex_lock(&server.lives_mutex)
	_, _ = append(&server.lives, live)
	sync.mutex_unlock(&server.lives_mutex)
}

ingress_live_remove :: proc(server: ^IngressServer, live: ^IngressLiveConn) {
	if live == nil {
		return
	}
	sync.mutex_lock(&server.lives_mutex)
	for i := 0; i < len(server.lives); i += 1 {
		if server.lives[i] == live {
			ordered_remove(&server.lives, i)
			break
		}
	}
	sync.mutex_unlock(&server.lives_mutex)
}

ingress_live_mark_routed :: proc(live: ^IngressLiveConn) {
	if live != nil {
		live.routed = true
	}
}

ingress_live_set_stream :: proc(live: ^IngressLiveConn, stream: ^cl.Conn) {
	if live != nil {
		live.stream = stream
	}
}

ingress_server_wait_idle :: proc(server: ^IngressServer) {
	if server == nil {
		return
	}
	sync.mutex_lock(&server.conn_mutex)
	for server.active_conns > 0 {
		sync.cond_wait(&server.conn_cond, &server.conn_mutex)
	}
	sync.mutex_unlock(&server.conn_mutex)
}

ingress_server_wait_idle_timeout :: proc(server: ^IngressServer, grace: time.Duration) {
	if server == nil {
		return
	}
	start := time.now()
	for {
		sync.mutex_lock(&server.conn_mutex)
		idle := server.active_conns == 0
		sync.mutex_unlock(&server.conn_mutex)
		if idle {
			return
		}
		if grace <= 0 || time.since(start) >= grace {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
}

ingress_is_draining :: proc(server: ^IngressServer) -> bool {
	if server == nil {
		return false
	}
	return sync.atomic_load(&server.draining)
}

ingress_caller_usable :: proc(server: ^IngressServer) -> bool {
	if server == nil {
		return false
	}
	if !server.want_caller {
		return server.dialer.dial != nil
	}
	return server.caller_ok && server.caller.connected
}

ingress_dial_allowed :: proc(server: ^IngressServer) -> bool {
	if server == nil || server.dialer.dial == nil {
		return false
	}
	if !server.want_caller {
		return true
	}
	return server.caller_ok && server.caller.connected
}

ingress_ready :: proc(server: ^IngressServer) -> (ready: bool, reason: string) {
	if server == nil {
		return false, READYZ_NOT_READY
	}
	if ingress_is_draining(server) {
		return false, READYZ_DRAINING
	}
	if !server.listening {
		return false, READYZ_NOT_READY
	}
	if !server.config.insecure && ingress_config_has_terminated(server.config) && server.tls_ctx == nil {
		return false, READYZ_NOT_READY
	}
	if server.want_caller && !ingress_caller_usable(server) {
		return false, READYZ_NOT_READY
	}
	return true, READYZ_READY
}

ingress_server_stop :: proc(server: ^IngressServer) {
	if server == nil {
		return
	}
	server.stop = true
	server.retry_stop = true
	if server.listening {
		trans.listener_close(&server.listener)
		server.listening = false
	}
}

ingress_close_unrouted :: proc(server: ^IngressServer) {
	sync.mutex_lock(&server.lives_mutex)
	for live in server.lives {
		if live != nil && !live.routed && live.browser != nil {
			trans.connection_shutdown_both(live.browser)
		}
	}
	sync.mutex_unlock(&server.lives_mutex)
}

ingress_force_close_lives :: proc(server: ^IngressServer) {
	sync.mutex_lock(&server.lives_mutex)
	for live in server.lives {
		if live == nil {
			continue
		}
		if live.stream != nil {
			cl.conn_close(live.stream)
		}
		if live.browser != nil {
			trans.connection_shutdown_both(live.browser)
		}
	}
	sync.mutex_unlock(&server.lives_mutex)
}

ingress_server_drain :: proc(server: ^IngressServer) {
	if server == nil {
		return
	}
	sync.atomic_store(&server.draining, true)
	ingress_log(server, .Info, "ingress_draining")
	ingress_server_stop(server)
	ingress_close_unrouted(server)
	ingress_server_wait_idle_timeout(server, server.config.shutdown_grace)
	ingress_force_close_lives(server)
	ingress_server_wait_idle_timeout(server, 2 * time.Second)
	if server.caller_ok {
		cl.caller_destroy(&server.caller)
		server.caller_ok = false
	}
	ingress_log(server, .Info, "ingress_stopped")
}

ingress_server_destroy :: proc(server: ^IngressServer) {
	if server == nil {
		return
	}
	if !ingress_is_draining(server) {
		ingress_server_stop(server)
	}
	if server.serve_thread != nil {
		thread.join(server.serve_thread)
		thread.destroy(server.serve_thread)
		server.serve_thread = nil
	}
	if server.retry_thread != nil {
		server.retry_stop = true
		thread.join(server.retry_thread)
		thread.destroy(server.retry_thread)
		server.retry_thread = nil
	}
	if server.caller_ok {
		cl.caller_destroy(&server.caller)
		server.caller_ok = false
	}
	ingress_force_close_lives(server)
	ingress_server_wait_idle_timeout(server, 3 * time.Second)
	ingress_metrics_stop(server)
	ingress_server_clear_tls(server)
	ingress_server_clear_allocs(server)
	server^ = {}
}

ingress_server_clear_tls :: proc(server: ^IngressServer) {
	if server.tls_ctx != nil {
		trans.tls_server_context_destroy(server.tls_ctx)
		server.tls_ctx = nil
	}
}

ingress_server_clear_allocs :: proc(server: ^IngressServer) {
	delete(server.ip_conns)
	delete(server.lives)
	server.ip_conns = {}
	server.lives = {}
}
