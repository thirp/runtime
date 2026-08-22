package web_ingress

import cl "../caller"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

IngressConnArg :: struct {
	server:  ^IngressServer,
	browser: ^trans.Connection,
	ip_key:  IngressIpKey,
	conn_id: u64,
	live:    ^IngressLiveConn,
}

IngressPump :: struct {
	browser:          ^trans.Connection,
	stream:           ^cl.Conn,
	last_activity_ns: i64,
	idle_timeout:     time.Duration,
	bytes_to_origin:  u64,
	bytes_to_browser: u64,
}

ingress_caller_dial :: proc(
	ctx: rawptr,
	service_id: proto.ServiceId,
) -> (
	^cl.Conn,
	cl.CallerError,
) {
	c := (^cl.Caller)(ctx)
	return cl.dial(c, service_id)
}

ingress_connection_proc :: proc(arg: ^IngressConnArg) {
	server := arg.server
	alloc := server.allocator
	defer {
		ingress_live_remove(server, arg.live)
		if arg.live != nil {
			free(arg.live, alloc)
		}
		trans.connection_destroy(arg.browser)
		free(arg, alloc)
		ingress_conn_end(server, arg.ip_key)
	}
	ingress_handle_connection(server, arg.browser, arg.live, arg.conn_id)
}

ingress_handle_connection :: proc(
	server: ^IngressServer,
	browser: ^trans.Connection,
	live: ^IngressLiveConn,
	conn_id: u64,
) {
	if server == nil || browser == nil {
		return
	}
	started := time.now()
	remote := net.endpoint_to_string(browser.remote)
	result := ConnResult.Error
	defer {
		metrics_inc_conn(&server.metrics, result)
		metrics_observe(&server.metrics, .ConnectionDuration, time.since(started))
		ingress_log(
			server,
			.Info,
			"browser_connection_closed",
			log.LogFields{session_id = conn_id, remote_address = remote, reason = conn_result_label(result)},
		)
	}

	if ingress_is_draining(server) {
		result = .Rejected
		return
	}

	ingress_log(
		server,
		.Info,
		"browser_connection_accepted",
		log.LogFields{session_id = conn_id, remote_address = remote},
	)

	route: IngressRoute
	host: PublicHost
	host_owned := false
	host_text := ""
	can_http := false
	mode_text := ""
	defer if host_owned {
		public_host_destroy(host)
	}
	if server.config.insecure {
		if len(server.config.routes) != 1 {
			return
		}
		route = server.config.routes[0]
		host_text = string(route.public_host)
		mode_text = ingress_mode_label(route.mode)
		can_http = true
		ingress_live_mark_routed(live)
	} else {
		timeout := server.config.limits.client_hello_timeout
		max_bytes := server.config.limits.max_client_hello_bytes
		if max_bytes <= 0 {
			max_bytes = DEFAULT_MAX_CLIENT_HELLO_BYTES
		}
		herr: IngressError
		host, herr = ingress_inspect_client_hello(browser, max_bytes, timeout)
		if herr == .ClientHelloTimeout || herr == .ClientHelloTooLarge || herr == .MalformedClientHello {
			if herr == .ClientHelloTimeout {
				metrics_inc_tls(&server.metrics, .Timeout)
			} else {
				metrics_inc_tls(&server.metrics, .Error)
			}
			ingress_log(
				server,
				.Warn,
				"client_hello_rejected",
				log.LogFields {
					session_id     = conn_id,
					remote_address = remote,
					reason         = ingress_error_reason(herr),
				},
			)
			result = .HandshakeFailed
			return
		}
		if herr != .None && herr != .MissingSni && herr != .InvalidPublicHost {
			result = .Error
			return
		}
		if herr == .None {
			host_owned = true
			host_text = string(host)
			found, ok := lookup_ingress_route(server.config.routes, host)
			if ok {
				route = found
				mode_text = ingress_mode_label(route.mode)
				if route.mode == .TerminateHttp {
					if !ingress_terminate_browser(server, browser, conn_id, remote) {
						result = .HandshakeFailed
						return
					}
					can_http = true
				}
				ingress_live_mark_routed(live)
				ingress_log(
					server,
					.Info,
					"route_selected",
					log.LogFields {
						session_id     = conn_id,
						public_host    = host_text,
						service_id     = string(route.service_id),
						mode           = mode_text,
						remote_address = remote,
					},
				)
			} else {
				ingress_reject_unrouted(server, browser, conn_id, remote, host_text, .UnknownRoute, .UnknownRoute)
				result = .Rejected
				return
			}
		} else {
			reason := herr == .MissingSni ? RouteFailureReason.MissingSni : RouteFailureReason.InvalidPublicHost
			ingress_reject_unrouted(server, browser, conn_id, remote, host_text, herr, reason)
			result = .Rejected
			return
		}
	}

	if ingress_is_draining(server) {
		ingress_write_or_close(browser, can_http, http_status_for_ingress_error(.Draining))
		metrics_inc_route_failure(&server.metrics, .Draining)
		result = .Rejected
		return
	}
	if !ingress_dial_allowed(server) {
		ingress_write_or_close(browser, can_http, http_status_bad_gateway())
		ingress_log(
			server,
			.Warn,
			"service_dial_failed",
			log.LogFields {
				session_id     = conn_id,
				public_host    = host_text,
				service_id     = string(route.service_id),
				mode           = mode_text,
				remote_address = remote,
				reason         = "broker_unavailable",
			},
		)
		result = .Error
		return
	}

	dial_started := time.now()
	stream, derr := server.dialer.dial(server.dialer.ctx, route.service_id)
	metrics_observe(&server.metrics, .ServiceDial, time.since(dial_started))
	if derr != .None || stream == nil {
		metrics_inc_dial(&server.metrics, dial_result_from_caller(derr))
		ingress_write_or_close(browser, can_http, http_status_for_caller_error(derr))
		ingress_log(
			server,
			.Warn,
			"service_dial_failed",
			log.LogFields {
				session_id     = conn_id,
				public_host    = host_text,
				service_id     = string(route.service_id),
				mode           = mode_text,
				remote_address = remote,
				reason         = caller_error_reason(derr),
			},
		)
		result = derr == .Timeout ? .Timeout : .Error
		return
	}
	metrics_inc_dial(&server.metrics, .Ok)
	ingress_live_set_stream(live, stream)
	ingress_log(
		server,
		.Info,
		"service_dial_succeeded",
		log.LogFields {
			session_id     = conn_id,
			public_host    = host_text,
			service_id     = string(route.service_id),
			mode           = mode_text,
			remote_address = remote,
		},
	)

	// Half-close mapping:
	// browser read EOF/error -> conn_half_close (wire HalfClose, stream stays
	// readable so the origin can finish a response);
	// conn_read error (peer HalfClose or Close both surface as ConnError.Closed;
	// Reset is distinct) -> connection_shutdown_write(browser);
	// after both directions finish -> conn_close (wire Close).
	// TLS shutdown_write is TCP SHUT_WR (close_notify would end the TLS session
	// and block a remaining response). Peer SSL_read maps SYSCALL to Closed
	// and may surface SSL_ERROR_SSL as Tls.
	pump := IngressPump {
		browser      = browser,
		stream       = stream,
		idle_timeout = server.config.limits.idle_timeout,
	}
	ingress_pump_touch(&pump)
	if pump.idle_timeout > 0 {
		slice := INGRESS_IDLE_POLL_SLICE
		if pump.idle_timeout < slice {
			slice = pump.idle_timeout
		}
		_ = trans.connection_set_recv_timeout(browser, slice)
	}
	th := thread.create_and_start_with_poly_data(&pump, ingress_copy_stream_to_browser)
	buf: [INGRESS_COPY_BUF]u8
	idle := false
	for {
		n, err := trans.connection_read(browser, buf[:])
		if err == .Timeout {
			if ingress_pump_idle(&pump) {
				idle = true
				break
			}
			continue
		}
		if err != .None {
			break
		}
		ingress_pump_touch(&pump)
		_, werr := cl.conn_write(stream, buf[:n])
		if werr != .None {
			break
		}
		sync.atomic_add(&pump.bytes_to_origin, u64(n))
	}
	cl.conn_half_close(stream)
	if th != nil {
		thread.join(th)
		thread.destroy(th)
	}
	metrics_inc_bytes(&server.metrics, .BrowserToOrigin, sync.atomic_load(&pump.bytes_to_origin))
	metrics_inc_bytes(&server.metrics, .OriginToBrowser, sync.atomic_load(&pump.bytes_to_browser))
	ingress_live_set_stream(live, nil)
	cl.conn_destroy(stream)
	if idle {
		result = .Timeout
	} else {
		result = .Ok
	}
}

ingress_copy_stream_to_browser :: proc(p: ^IngressPump) {
	buf: [INGRESS_COPY_BUF]u8
	for {
		n, err := cl.conn_read(p.stream, buf[:])
		if err != .None {
			_ = trans.connection_shutdown_write(p.browser)
			return
		}
		ingress_pump_touch(p)
		if trans.connection_write(p.browser, buf[:n]) != .None {
			cl.conn_close(p.stream)
			return
		}
		sync.atomic_add(&p.bytes_to_browser, u64(n))
	}
}

ingress_pump_touch :: proc(p: ^IngressPump) {
	sync.atomic_store(&p.last_activity_ns, time.time_to_unix_nano(time.now()))
}

ingress_pump_idle :: proc(p: ^IngressPump) -> bool {
	if p.idle_timeout <= 0 {
		return false
	}
	last := sync.atomic_load(&p.last_activity_ns)
	now := time.time_to_unix_nano(time.now())
	if now <= last {
		return false
	}
	return time.Duration(now - last) >= p.idle_timeout
}

ingress_terminate_browser :: proc(
	server: ^IngressServer,
	browser: ^trans.Connection,
	conn_id: u64,
	remote: string,
) -> bool {
	if server.tls_ctx == nil {
		return false
	}
	timeout := server.config.limits.client_hello_timeout
	tls_err := ingress_tls_accept(browser, server.tls_ctx, timeout)
	if tls_err != .None {
		if tls_err == .ClientHelloTimeout {
			metrics_inc_tls(&server.metrics, .Timeout)
			ingress_log(
				server,
				.Warn,
				"client_hello_rejected",
				log.LogFields {
					session_id     = conn_id,
					remote_address = remote,
					reason         = ingress_error_reason(tls_err),
				},
			)
		} else {
			metrics_inc_tls(&server.metrics, .Error)
			ingress_log(
				server,
				.Warn,
				"tls_handshake_failed",
				log.LogFields {
					session_id     = conn_id,
					remote_address = remote,
					reason         = ingress_error_reason(tls_err),
				},
			)
		}
		return false
	}
	metrics_inc_tls(&server.metrics, .Ok)
	return true
}

ingress_reject_unrouted :: proc(
	server: ^IngressServer,
	browser: ^trans.Connection,
	conn_id: u64,
	remote: string,
	host_text: string,
	err: IngressError,
	reason: RouteFailureReason,
) {
	if server.tls_ctx != nil {
		if ingress_terminate_browser(server, browser, conn_id, remote) {
			_ = write_http_error(browser, http_status_for_ingress_error(err == .UnknownRoute ? .UnknownRoute : err))
		}
	} else {
		trans.connection_shutdown_both(browser)
	}
	metrics_inc_route_failure(&server.metrics, reason)
	ingress_log(
		server,
		.Info,
		"route_rejected",
		log.LogFields {
			session_id     = conn_id,
			public_host    = host_text,
			remote_address = remote,
			reason         = ingress_error_reason(err == .UnknownRoute ? .UnknownRoute : err),
		},
	)
}

ingress_write_or_close :: proc(conn: ^trans.Connection, can_http: bool, status: HttpErrorStatus) {
	if can_http {
		_ = write_http_error(conn, status)
		return
	}
	trans.connection_shutdown_both(conn)
}

caller_error_reason :: proc(err: cl.CallerError) -> string {
	switch err {
	case .None:
		return ""
	case .Unauthorized:
		return "unauthorized"
	case .RateLimited:
		return "rate_limited"
	case .Timeout:
		return "timeout"
	case .ServiceNotFound:
		return "service_not_found"
	case .AgentUnavailable:
		return "agent_unavailable"
	case .LocalServiceUnavailable:
		return "local_service_unavailable"
	case .QuotaExceeded:
		return "quota_exceeded"
	case .BrokerDraining:
		return "broker_draining"
	case .Transport:
		return "transport"
	case .Closed:
		return "closed"
	case .AuthFailed:
		return "auth_failed"
	case .InvalidConfig, .InvalidServiceId, .Internal, .OutOfMemory:
		return "internal"
	}
	return "internal"
}
