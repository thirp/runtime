package transport

import proto "../protocol"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:time"

when ODIN_TEST {
	TcpTraceSide :: enum { None, Agent, Broker }

	// Enable this only for the native slow-upload replay's session. The
	// broker learns the role from Hello, before sending any session replies.
	connection_trace_tcp :: proc(conn: ^Connection, side: TcpTraceSide) {
		sync.atomic_store(&conn.test_tcp_trace, side)
	}

	when ODIN_OS != .Windows {
		tcp_trace_native_error :: proc() -> int {
			return -1
		}
	}

	tcp_trace_result :: proc(conn: ^Connection, side: TcpTraceSide, sock: net.TCP_Socket, op: string, requested, n: int, err: $E) {
		native_error := tcp_trace_native_error() if err != .None else 0
		fmt.eprintf("legacy slow upload tcp ts_ns=%d side=%v conn=%p thread=%d socket=%v op=%s requested=%d bytes=%d error=%v error_code=%d native_error=%d\n",
			time.time_to_unix_nano(time.now()), side, conn, sync.current_thread_id(), sock, op, requested, n, err, int(err), native_error)
	}

	tcp_trace_close :: proc(conn: ^Connection, op: string) {
		if side := sync.atomic_load(&conn.test_tcp_trace); side != .None {
			fmt.eprintf("legacy slow upload tcp ts_ns=%d side=%v conn=%p thread=%d socket=%v op=%s\n",
				time.time_to_unix_nano(time.now()), side, conn, sync.current_thread_id(), conn.socket, op)
		}
	}

	tcp_trace_ping :: proc(conn: ^Connection, terr: TransportError, perr: proto.ProtocolError) {
		if side := sync.atomic_load(&conn.test_tcp_trace); side != .None {
			// Correlate the Ping with socket operations even if the fd was
			// closed after the write returned.
			fmt.eprintf("legacy slow upload ping ts_ns=%d side=%v conn=%p thread=%d transport=%v transport_code=%d protocol=%v protocol_code=%d\n",
				time.time_to_unix_nano(time.now()), side, conn, sync.current_thread_id(), terr, int(terr), perr, int(perr))
		}
	}
}

@(private)
tcp_recv :: proc(conn: ^Connection, sock: net.TCP_Socket, dst: []u8) -> (int, net.TCP_Recv_Error, i32) {
	n, err := net.recv_tcp(sock, dst)
	code := net.last_platform_error() if err != .None else 0
	when ODIN_TEST {
		if side := sync.atomic_load(&conn.test_tcp_trace); side != .None {
			tcp_trace_result(conn, side, sock, "recv", len(dst), n, err)
		}
	}
	return n, err, code
}

@(private)
tcp_send :: proc(conn: ^Connection, sock: net.TCP_Socket, src: []u8) -> (int, net.TCP_Send_Error, i32) {
	n, err := net.send_tcp(sock, src)
	code := net.last_platform_error() if err != .None else 0
	when ODIN_TEST {
		if side := sync.atomic_load(&conn.test_tcp_trace); side != .None {
			tcp_trace_result(conn, side, sock, "send", len(src), n, err)
		}
	}
	return n, err, code
}
