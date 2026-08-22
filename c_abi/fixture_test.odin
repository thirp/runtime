package c_abi

import ag "../agent"
import auth "../auth"
import brk "../broker"
import cl "../caller"
import trans "../transport"
import "core:c"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

TEST_TOKEN_HOST :: "host-dev-token"
TEST_TOKEN_CALLER :: "caller-dev-token"
TEST_PRINCIPAL_HOST :: "host-a"
TEST_PRINCIPAL_CALLER :: "client-a"
TEST_SERVICE :: "demo/echo"
TEST_SERVICE_B :: "demo/echo-b"

TestBroker :: struct {
	reg:    brk.Registry,
	store:  auth.StaticTokenAuth,
	server: brk.Server,
}

EchoWorker :: struct {
	ln: ^trans.Listener,
}

EchoFixture :: struct {
	ln:     trans.Listener,
	worker: EchoWorker,
	th:     ^thread.Thread,
}

start_test_broker :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) {
	testing.expect_value(t, brk.registry_init(&fx.reg), brk.RegistryError.None, loc)
	testing.expect_value(t, auth.auth_init(&fx.store), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(&fx.store, TEST_TOKEN_HOST, TEST_PRINCIPAL_HOST), auth.AuthError.None, loc)
	testing.expect_value(t, auth.auth_add_token(&fx.store, TEST_TOKEN_CALLER, TEST_PRINCIPAL_CALLER), auth.AuthError.None, loc)
	brk.server_init(&fx.server, &fx.reg, auth.static_token_authenticator(&fx.store))
	brk.server_disable_test_hardening(&fx.server)
	fx.server.heartbeat_interval = 30 * time.Second
	fx.server.session_timeout = 30 * time.Second
	testing.expect_value(t, brk.server_listen(&fx.server, trans.loopback_endpoint(0)), trans.TransportError.None, loc)
	brk.server_start(&fx.server)
}

stop_test_broker :: proc(fx: ^TestBroker) {
	brk.server_stop(&fx.server)
	_ = brk.server_wait_idle(&fx.server, 2 * time.Second)
	brk.server_destroy(&fx.server)
	auth.auth_destroy(&fx.store)
	brk.registry_destroy(&fx.reg)
}

broker_endpoint :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) -> net.Endpoint {
	ep, err := brk.server_endpoint(&fx.server)
	testing.expect_value(t, err, trans.TransportError.None, loc)
	return ep
}

start_echo :: proc(t: ^testing.T, fx: ^EchoFixture, loc := #caller_location) -> net.Endpoint {
	lerr: trans.TransportError
	fx.ln, lerr = trans.listener_listen(trans.loopback_endpoint(0))
	testing.expect_value(t, lerr, trans.TransportError.None, loc)
	_ = trans.listener_set_recv_timeout(&fx.ln, 50 * time.Millisecond)
	ep, eerr := trans.listener_endpoint(fx.ln)
	testing.expect_value(t, eerr, trans.TransportError.None, loc)
	fx.worker.ln = &fx.ln
	fx.th = thread.create_and_start_with_poly_data(&fx.worker, echo_accept_loop)
	return ep
}

stop_echo :: proc(fx: ^EchoFixture) {
	trans.listener_close(&fx.ln)
	if fx.th != nil {
		thread.join(fx.th)
		thread.destroy(fx.th)
		fx.th = nil
	}
}

echo_accept_loop :: proc(w: ^EchoWorker) {
	for {
		conn, err := trans.listener_accept(w.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
		}
		thread.run_with_poly_data(conn, echo_mirror_one)
	}
}

echo_mirror_one :: proc(conn: ^trans.Connection) {
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

endpoint_cstring :: proc(t: ^testing.T, ep: net.Endpoint, loc := #caller_location) -> cstring {
	cs, err := strings.clone_to_cstring(net.endpoint_to_string(ep))
	testing.expect_value(t, err, mem.Allocator_Error.None, loc)
	return cs
}

wait_c_agent_connected :: proc(t: ^testing.T, agent: ^CAgent, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		if ag.agent_is_connected(&agent.inner) {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, loc = loc)
}

must_create_agent :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) -> (^CAgent, cstring) {
	broker_cs := endpoint_cstring(t, broker_endpoint(t, fx, loc), loc)
	cfg := ThirpAgentConfig {
		broker   = broker_cs,
		token    = TEST_TOKEN_HOST,
		insecure = 1,
	}
	agent: ^CAgent
	err := thirp_agent_create(&cfg, &agent)
	testing.expect_value(t, err, ERR_OK, loc)
	testing.expect(t, agent != nil, loc = loc)
	wait_c_agent_connected(t, agent, loc)
	return agent, broker_cs
}

must_create_caller :: proc(t: ^testing.T, fx: ^TestBroker, loc := #caller_location) -> (^CCaller, cstring) {
	broker_cs := endpoint_cstring(t, broker_endpoint(t, fx, loc), loc)
	cfg := ThirpCallerConfig {
		broker   = broker_cs,
		token    = TEST_TOKEN_CALLER,
		insecure = 1,
	}
	caller: ^CCaller
	err := thirp_caller_create(&cfg, &caller)
	testing.expect_value(t, err, ERR_OK, loc)
	testing.expect(t, caller != nil, loc = loc)
	return caller, broker_cs
}

must_register :: proc(t: ^testing.T, agent: ^CAgent, service: cstring, target: cstring, loc := #caller_location) {
	testing.expect_value(t, thirp_register_service(agent, service, target), ERR_OK, loc)
}

must_dial :: proc(t: ^testing.T, caller: ^CCaller, service: cstring, loc := #caller_location) -> ^cl.Conn {
	conn: ^cl.Conn
	err := thirp_dial(caller, service, &conn)
	testing.expect_value(t, err, ERR_OK, loc)
	testing.expect(t, conn != nil, loc = loc)
	return conn
}

echo_payload :: proc(t: ^testing.T, conn: ^cl.Conn, payload: string, loc := #caller_location) {
	got: c.size_t
	testing.expect_value(
		t,
		thirp_conn_write(conn, raw_data(payload), c.size_t(len(payload)), &got),
		ERR_OK,
		loc,
	)
	testing.expect_value(t, int(got), len(payload), loc)
	buf: [16]u8
	n: c.size_t
	testing.expect_value(t, thirp_conn_read(conn, raw_data(buf[:]), c.size_t(len(buf)), &n), ERR_OK, loc)
	testing.expect_value(t, string(buf[:n]), payload, loc)
}

wait_dial_error :: proc(
	t: ^testing.T,
	caller: ^CCaller,
	service: cstring,
	want: c.int,
	loc := #caller_location,
) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		conn: ^cl.Conn
		err := thirp_dial(caller, service, &conn)
		if conn != nil {
			thirp_conn_destroy(conn)
		}
		if err == want {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, loc = loc)
}
