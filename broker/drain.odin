package broker

import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:sync"
import "core:time"

server_is_draining :: proc(server: ^Server) -> bool {
	if server == nil {
		return false
	}
	return sync.atomic_load(&server.draining)
}

server_ready :: proc(server: ^Server) -> (ready: bool, reason: string) {
	if server == nil {
		return false, READYZ_NOT_READY
	}
	if server_is_draining(server) {
		return false, READYZ_DRAINING
	}
	if !server.listening {
		return false, READYZ_NOT_READY
	}
	return true, READYZ_READY
}

server_copy_outbox_conns :: proc(server: ^Server) -> [dynamic]^trans.Connection {
	conns := make([dynamic]^trans.Connection, server.allocator)
	sync.mutex_lock(&server.outbox_mutex)
	defer sync.mutex_unlock(&server.outbox_mutex)
	for conn in server.outboxes {
		if trans.connection_acquire(conn) {
			append(&conns, conn)
		}
	}
	return conns
}

server_drain :: proc(server: ^Server, grace: time.Duration) {
	if server == nil {
		return
	}
	sync.atomic_store(&server.draining, true)
	server_log(server, .Info, LOG_EVENT_DRAIN_STARTED)
	server.stop = true
	if server.listening {
		trans.listener_close(&server.listener)
		server.listening = false
	}

	conns := server_copy_outbox_conns(server)
	for conn in conns {
		_ = relay_write_failure(
			conn,
			.Error,
			.BrokerDraining,
			proto.CONNECTION_STREAM_ID,
			server.allocator,
		)
		trans.connection_release(conn)
	}
	delete(conns)

	if grace > 0 {
		start := time.now()
		for time.since(start) < grace {
			if relay_stream_count(server) == 0 {
				break
			}
			time.sleep(5 * time.Millisecond)
		}
	}

	taken := relay_take_all_streams(server, server.allocator)
	defer delete(taken)
	for stream in taken {
		metrics_inc_reset(&server.metrics, .BrokerDraining)
		server_log(
			server,
			.Info,
			LOG_EVENT_STREAM_RESET,
			log.LogFields {
				stream_id  = u64(stream.id),
				service_id = string(stream.service_id),
				error_code = wire_error_name(.BrokerDraining),
				reason     = reset_reason_label(.BrokerDraining),
			},
		)
		server_drop_stream_queues(server, stream)
		if trans.connection_acquire(stream.caller_conn) {
			if stream.state == .Opening {
				_ = relay_write_failure(
					stream.caller_conn,
					.ConnectFailed,
					.BrokerDraining,
					proto.CONNECTION_STREAM_ID,
					server.allocator,
				)
			} else {
				_ = relay_write_failure(
					stream.caller_conn,
					.Reset,
					.BrokerDraining,
					stream.id,
					server.allocator,
				)
			}
			trans.connection_release(stream.caller_conn)
		}
		if trans.connection_acquire(stream.agent_conn) {
			_ = relay_write_failure(
				stream.agent_conn,
				.Reset,
				.BrokerDraining,
				stream.id,
				server.allocator,
			)
			trans.connection_release(stream.agent_conn)
		}
		relay_release_stream(server, stream)
	}

	left := server_copy_outbox_conns(server)
	for conn in left {
		trans.connection_close(conn)
		trans.connection_release(conn)
	}
	delete(left)
	server_log(server, .Info, LOG_EVENT_DRAIN_COMPLETE)
}
