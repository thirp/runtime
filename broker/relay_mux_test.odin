package broker

import auth "../auth"
import proto "../protocol"
import trans "../transport"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

MuxAgentStream :: struct {
	local: ^trans.Connection,
}

MuxAgentPumpArg :: struct {
	agent:     ^MuxAgent,
	stream_id: proto.StreamId,
	local:     ^trans.Connection,
}

MuxAgent :: struct {
	mutex:      sync.Mutex,
	conn:       ^trans.Connection,
	decoder:    ^proto.FrameDecoder,
	echo_ep:    net.Endpoint,
	streams:    map[proto.StreamId]MuxAgentStream,
	live_pumps: int,
	running:    bool,
}

mux_agent_stream_count :: proc(a: ^MuxAgent) -> int {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	return len(a.streams)
}

mux_agent_wait_stream_count :: proc(a: ^MuxAgent, want: int, timeout: time.Duration) -> bool {
	start := time.now()
	for time.since(start) < timeout {
		if mux_agent_stream_count(a) == want {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return mux_agent_stream_count(a) == want
}

mux_agent_write :: proc(
	conn: ^trans.Connection,
	opcode: proto.Opcode,
	payload: []u8,
	stream_id: proto.StreamId,
) -> bool {
	terr, perr := trans.write_frame(conn, opcode, payload, stream_id)
	return terr == .None && perr == .None
}

mux_agent_take :: proc(a: ^MuxAgent, stream_id: proto.StreamId) -> (MuxAgentStream, bool) {
	sync.mutex_lock(&a.mutex)
	defer sync.mutex_unlock(&a.mutex)
	stream, found := a.streams[stream_id]
	if found {
		delete_key(&a.streams, stream_id)
	}
	return stream, found
}

mux_agent_clear :: proc(a: ^MuxAgent) {
	taken := make([dynamic]MuxAgentStream)
	defer delete(taken)
	sync.mutex_lock(&a.mutex)
	for _, stream in a.streams {
		append(&taken, stream)
	}
	clear(&a.streams)
	sync.mutex_unlock(&a.mutex)
	for stream in taken {
		if stream.local != nil {
			trans.connection_destroy(stream.local)
		}
	}
	deadline := time.now()
	for sync.atomic_load(&a.live_pumps) != 0 {
		if time.since(deadline) > 2 * time.Second {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
}

mux_agent_pump :: proc(arg: ^MuxAgentPumpArg) {
	defer {
		trans.connection_release(arg.local)
		sync.atomic_sub(&arg.agent.live_pumps, 1)
		free(arg)
	}
	buf: [1024]u8
	for {
		sync.mutex_lock(&arg.agent.mutex)
		_, found := arg.agent.streams[arg.stream_id]
		conn := arg.agent.conn
		sync.mutex_unlock(&arg.agent.mutex)
		if !found {
			return
		}
		n, err := trans.connection_read(arg.local, buf[:])
		if err != .None {
			stream, taken := mux_agent_take(arg.agent, arg.stream_id)
			if taken {
				_ = mux_agent_write(conn, .HalfClose, nil, arg.stream_id)
				_ = mux_agent_write(conn, .Close, nil, arg.stream_id)
				if stream.local != nil {
					trans.connection_destroy(stream.local)
				}
			}
			return
		}
		if !mux_agent_write(conn, .Data, buf[:n], arg.stream_id) {
			return
		}
	}
}

mux_agent_handle_open :: proc(a: ^MuxAgent, frame: proto.Frame) {
	msg, err := proto.decode_open(frame.payload)
	if err != .None {
		return
	}
	delete(string(msg.service_id))
	stream_id := frame.header.stream_id

	sync.mutex_lock(&a.mutex)
	_, exists := a.streams[stream_id]
	sync.mutex_unlock(&a.mutex)
	if exists {
		payload, _ := proto.encode_wire_failure(
			proto.WireFailure{code = proto.wire_error_to_u16(.StreamAlreadyExists), diagnostic = ""},
		)
		_ = mux_agent_write(a.conn, .OpenFailed, payload, stream_id)
		delete(payload)
		return
	}

	local, derr := trans.connection_dial(a.echo_ep)
	if derr != .None {
		payload, _ := proto.encode_wire_failure(
			proto.WireFailure {
				code       = proto.wire_error_to_u16(.LocalServiceUnavailable),
				diagnostic = "",
			},
		)
		_ = mux_agent_write(a.conn, .OpenFailed, payload, stream_id)
		delete(payload)
		return
	}

	arg := new(MuxAgentPumpArg)
	arg.agent = a
	arg.stream_id = stream_id
	arg.local = local
	if !trans.connection_acquire(local) {
		free(arg)
		trans.connection_destroy(local)
		return
	}

	sync.mutex_lock(&a.mutex)
	a.streams[stream_id] = MuxAgentStream {
		local = local,
	}
	sync.atomic_add(&a.live_pumps, 1)
	sync.mutex_unlock(&a.mutex)
	thread.run_with_poly_data(arg, mux_agent_pump)
	_ = mux_agent_write(a.conn, .OpenOk, nil, stream_id)
}

mux_agent_run :: proc(a: ^MuxAgent) {
	sync.atomic_store(&a.running, true)
	defer {
		sync.atomic_store(&a.running, false)
		mux_agent_clear(a)
	}
	for {
		_ = trans.connection_set_recv_timeout(a.conn, 2 * time.Second)
		frame, terr, perr := trans.read_frame(a.conn, a.decoder)
		if terr == .Timeout {
			continue
		}
		if terr != .None || perr != .None {
			return
		}
		switch frame.header.opcode {
		case .Open:
			mux_agent_handle_open(a, frame)
		case .Data:
			sync.mutex_lock(&a.mutex)
			stream, found := a.streams[frame.header.stream_id]
			local := stream.local
			if found && local != nil {
				_ = trans.connection_acquire(local)
			}
			sync.mutex_unlock(&a.mutex)
			if found && local != nil {
				_ = trans.connection_write(local, frame.payload)
				trans.connection_release(local)
			}
		case .HalfClose:
			sync.mutex_lock(&a.mutex)
			stream, found := a.streams[frame.header.stream_id]
			local := stream.local
			if found && local != nil {
				_ = trans.connection_acquire(local)
			}
			sync.mutex_unlock(&a.mutex)
			if found && local != nil {
				_ = trans.connection_shutdown_write(local)
				trans.connection_release(local)
			}
		case .Close, .Reset:
			stream, found := mux_agent_take(a, frame.header.stream_id)
			if found && stream.local != nil {
				trans.connection_destroy(stream.local)
			}
		case .Ping:
			msg, merr := proto.decode_ping(frame.payload)
			if merr == .None {
				payload, _ := proto.encode_pong(proto.Pong{nonce = msg.nonce})
				_ = mux_agent_write(a.conn, .Pong, payload, proto.CONNECTION_STREAM_ID)
				delete(payload)
			}
		case .Pong:
		case .Hello, .HelloAck, .Authenticate, .AuthenticateOk, .AuthenticateFailed,
		     .Register, .RegisterOk, .RegisterFailed, .Unregister, .UnregisterOk,
		     .UnregisterFailed, .Connect, .ConnectOk, .ConnectFailed, .OpenOk, .OpenFailed:
		case .Error:
			proto.frame_destroy(&frame)
			return
		}
		proto.frame_destroy(&frame)
	}
}

echo_mirror_conn :: proc(conn: ^trans.Connection) {
	defer trans.connection_destroy(conn)
	buf: [1024]u8
	for {
		n, err := trans.connection_read(conn, buf[:])
		if err != .None {
			return
		}
		if trans.connection_write(conn, buf[:n]) != .None {
			return
		}
	}
}

MultiEcho :: struct {
	ln:   ^trans.Listener,
	stop: bool,
}

multi_echo_accept :: proc(e: ^MultiEcho) {
	_ = trans.listener_set_recv_timeout(e.ln, 50 * time.Millisecond)
	for {
		if sync.atomic_load(&e.stop) {
			return
		}
		conn, err := trans.listener_accept(e.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		thread.run_with_poly_data(conn, echo_mirror_conn)
	}
}

MuxFixture :: struct {
	echo_ln:     trans.Listener,
	echo:        MultiEcho,
	echo_thread: ^thread.Thread,
	agent:       ^trans.Connection,
	agent_dec:   proto.FrameDecoder,
	mux:         MuxAgent,
	mux_thread:  ^thread.Thread,
}

start_mux_fixture :: proc(t: ^testing.T, server: ^Server, f: ^MuxFixture, loc := #caller_location) {
	echo_ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	f.echo_ln = echo_ln
	echo_ep, eerr := trans.listener_endpoint(f.echo_ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	f.echo.ln = &f.echo_ln
	f.echo_thread = thread.create_and_start_with_poly_data(&f.echo, multi_echo_accept)
	testing.expect(t, f.echo_thread != nil, loc = loc)

	f.agent, f.agent_dec = register_test_agent(t, server, loc)
	f.mux.conn = f.agent
	f.mux.decoder = &f.agent_dec
	f.mux.echo_ep = echo_ep
	f.mux.streams = make(map[proto.StreamId]MuxAgentStream)
	f.mux_thread = thread.create_and_start_with_poly_data(&f.mux, mux_agent_run)
	testing.expect(t, f.mux_thread != nil, loc = loc)
}

stop_mux_fixture :: proc(f: ^MuxFixture) {
	if f.agent != nil {
		trans.connection_close(f.agent)
	}
	if f.mux_thread != nil {
		thread.join(f.mux_thread)
		thread.destroy(f.mux_thread)
		f.mux_thread = nil
	}
	delete(f.mux.streams)
	proto.decoder_destroy(&f.agent_dec)
	if f.agent != nil {
		trans.connection_destroy(f.agent)
		f.agent = nil
	}
	sync.atomic_store(&f.echo.stop, true)
	trans.listener_close(&f.echo_ln)
	if f.echo_thread != nil {
		thread.join(f.echo_thread)
		thread.destroy(f.echo_thread)
		f.echo_thread = nil
	}
}

CallerMuxWorker :: struct {
	conn:       ^trans.Connection,
	decoder:    proto.FrameDecoder,
	payload:    []u8,
	stream_id:  proto.StreamId,
	connect_ok: bool,
	echo_ok:    bool,
	failed:     bool,
}

caller_mux_read :: proc(w: ^CallerMuxWorker, want: proto.Opcode) -> (proto.Frame, bool) {
	_ = trans.connection_set_recv_timeout(w.conn, 2 * time.Second)
	for {
		frame, terr, perr := trans.read_frame(w.conn, &w.decoder)
		if terr != .None || perr != .None {
			return {}, false
		}
		#partial switch frame.header.opcode {
		case .Ping:
			msg, merr := proto.decode_ping(frame.payload)
			proto.frame_destroy(&frame)
			if merr == .None {
				payload, _ := proto.encode_pong(proto.Pong{nonce = msg.nonce})
				_ = mux_agent_write(w.conn, .Pong, payload, proto.CONNECTION_STREAM_ID)
				delete(payload)
			}
			continue
		case .Pong:
			proto.frame_destroy(&frame)
			continue
		}
		if frame.header.opcode != want {
			proto.frame_destroy(&frame)
			return {}, false
		}
		return frame, true
	}
}

caller_mux_connect_echo :: proc(w: ^CallerMuxWorker) {
	id, serr := proto.make_service_id(TEST_SERVICE)
	if serr != .None {
		w.failed = true
		return
	}
	payload, err := proto.encode_connect(proto.Connect{service_id = id})
	if err != .None {
		w.failed = true
		return
	}
	terr, perr := trans.write_frame(w.conn, .Connect, payload)
	delete(payload)
	if terr != .None || perr != .None {
		w.failed = true
		return
	}

	ok_frame, ok := caller_mux_read(w, .ConnectOk)
	if !ok {
		w.failed = true
		return
	}
	w.stream_id = ok_frame.header.stream_id
	w.connect_ok = w.stream_id != proto.CONNECTION_STREAM_ID
	proto.frame_destroy(&ok_frame)
	if !w.connect_ok {
		w.failed = true
		return
	}

	terr, perr = trans.write_frame(w.conn, .Data, w.payload, w.stream_id)
	if terr != .None || perr != .None {
		w.failed = true
		return
	}
	data, dok := caller_mux_read(w, .Data)
	if !dok {
		w.failed = true
		return
	}
	w.echo_ok = string(data.payload) == string(w.payload) && data.header.stream_id == w.stream_id
	proto.frame_destroy(&data)
	if !w.echo_ok {
		w.failed = true
	}
}

caller_mux_echo_again :: proc(w: ^CallerMuxWorker) {
	terr, perr := trans.write_frame(w.conn, .Data, w.payload, w.stream_id)
	if terr != .None || perr != .None {
		w.failed = true
		return
	}
	data, ok := caller_mux_read(w, .Data)
	if !ok {
		w.failed = true
		return
	}
	w.echo_ok = string(data.payload) == string(w.payload) && data.header.stream_id == w.stream_id
	proto.frame_destroy(&data)
	if !w.echo_ok {
		w.failed = true
	}
}

@(test)
test_relay_ten_callers_concurrent_echo :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	CALLERS :: 10
	workers: [CALLERS]CallerMuxWorker
	threads: [CALLERS]^thread.Thread
	payloads: [CALLERS][6]u8
	for i in 0 ..< CALLERS {
		payloads[i] = {'c', 'a', 'l', 'l', u8('0' + i / 10), u8('0' + i % 10)}
		workers[i].conn = dial_server(t, &server)
		handshake_caller(t, workers[i].conn, &workers[i].decoder)
		workers[i].payload = payloads[i][:]
	}
	defer {
		for i in 0 ..< CALLERS {
			proto.decoder_destroy(&workers[i].decoder)
			trans.connection_destroy(workers[i].conn)
		}
	}

	for i in 0 ..< CALLERS {
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], caller_mux_connect_echo)
		testing.expect(t, threads[i] != nil)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	seen: map[proto.StreamId]struct{}
	defer delete(seen)
	for i in 0 ..< CALLERS {
		testing.expect(t, !workers[i].failed)
		testing.expect(t, workers[i].connect_ok)
		testing.expect(t, workers[i].echo_ok)
		testing.expect(t, workers[i].stream_id != proto.CONNECTION_STREAM_ID)
		_, dup := seen[workers[i].stream_id]
		testing.expect(t, !dup)
		seen[workers[i].stream_id] = {}
	}
	testing.expect_value(t, len(seen), CALLERS)
}

@(test)
test_relay_close_one_stream_others_unaffected :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	CALLERS :: 3
	workers: [CALLERS]CallerMuxWorker
	payloads: [CALLERS][4]u8
	for i in 0 ..< CALLERS {
		payloads[i] = {'x', 'x', 'x', u8('0' + i)}
		workers[i].conn = dial_server(t, &server)
		handshake_caller(t, workers[i].conn, &workers[i].decoder)
		workers[i].payload = payloads[i][:]
	}

	threads: [CALLERS]^thread.Thread
	for i in 0 ..< CALLERS {
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], caller_mux_connect_echo)
		testing.expect(t, threads[i] != nil)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for i in 0 ..< CALLERS {
		testing.expect(t, workers[i].connect_ok)
		testing.expect(t, workers[i].echo_ok)
		testing.expect(t, !workers[i].failed)
	}

	proto.decoder_destroy(&workers[0].decoder)
	trans.connection_destroy(workers[0].conn)
	workers[0].conn = nil

	testing.expect(t, mux_agent_wait_stream_count(&fx.mux, 2, 2 * time.Second))
	testing.expect(t, sync.atomic_load(&fx.mux.running))

	payloads[1] = {'y', 'y', 'y', '1'}
	payloads[2] = {'z', 'z', 'z', '2'}
	workers[1].payload = payloads[1][:]
	workers[2].payload = payloads[2][:]
	workers[1].echo_ok = false
	workers[2].echo_ok = false
	workers[1].failed = false
	workers[2].failed = false

	t1 := thread.create_and_start_with_poly_data(&workers[1], caller_mux_echo_again)
	t2 := thread.create_and_start_with_poly_data(&workers[2], caller_mux_echo_again)
	thread.join(t1)
	thread.destroy(t1)
	thread.join(t2)
	thread.destroy(t2)

	testing.expect(t, workers[1].echo_ok)
	testing.expect(t, workers[2].echo_ok)
	testing.expect(t, !workers[1].failed)
	testing.expect(t, !workers[2].failed)

	svc := must_service_id(t, TEST_SERVICE)
	_, found := lookup_service(&reg, svc)
	testing.expect(t, found)
	testing.expect_value(t, service_count(&reg), 1)

	for i in 1 ..< CALLERS {
		proto.decoder_destroy(&workers[i].decoder)
		trans.connection_destroy(workers[i].conn)
	}
}

@(test)
test_relay_concurrent_connect_distinct_stream_ids :: proc(t: ^testing.T) {
	reg: Registry
	store: auth.StaticTokenAuth
	server: Server
	quiet_test_server(t, &server, &reg, &store)
	defer stop_test_server(&server, &store, &reg)

	fx: MuxFixture
	start_mux_fixture(t, &server, &fx)
	defer stop_mux_fixture(&fx)

	CALLERS :: 8
	workers: [CALLERS]CallerMuxWorker
	threads: [CALLERS]^thread.Thread
	payloads: [CALLERS][1]u8
	for i in 0 ..< CALLERS {
		payloads[i] = {u8('a' + i)}
		workers[i].conn = dial_server(t, &server)
		handshake_caller(t, workers[i].conn, &workers[i].decoder)
		workers[i].payload = payloads[i][:]
	}
	defer {
		for i in 0 ..< CALLERS {
			proto.decoder_destroy(&workers[i].decoder)
			trans.connection_destroy(workers[i].conn)
		}
	}

	for i in 0 ..< CALLERS {
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], caller_mux_connect_echo)
		testing.expect(t, threads[i] != nil)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	seen: map[proto.StreamId]struct{}
	defer delete(seen)
	for i in 0 ..< CALLERS {
		testing.expect(t, workers[i].connect_ok)
		testing.expect(t, !workers[i].failed)
		_, dup := seen[workers[i].stream_id]
		testing.expect(t, !dup)
		seen[workers[i].stream_id] = {}
	}
	testing.expect_value(t, len(seen), CALLERS)
}
