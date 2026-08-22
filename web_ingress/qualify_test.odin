package web_ingress

import ag "../agent"
import brk "../broker"
import trans "../transport"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

QUALIFY_CHURN :: 20
QUALIFY_CONCURRENT :: 8

qualify_wait_idle :: proc(t: ^testing.T, server: ^IngressServer, fx: ^TestBroker, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		if server.active_conns == 0 &&
		   server.slot_count == 0 &&
		   len(server.ip_conns) == 0 &&
		   brk.relay_stream_count(&fx.server) == 0 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, server.active_conns, 0, loc)
	testing.expect_value(t, server.slot_count, 0, loc)
	testing.expect_value(t, len(server.ip_conns), 0, loc)
	testing.expect_value(t, brk.relay_stream_count(&fx.server), 0, loc)
}

qualify_wait_origin_requests :: proc(t: ^testing.T, origin: ^HttpOriginFixture, want: int, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 2 * time.Second {
		sync.mutex_lock(&origin.mutex)
		got := origin.requests
		sync.mutex_unlock(&origin.mutex)
		if got >= want {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, origin.requests >= want, loc = loc)
}

qualify_close_caller_broker :: proc(server: ^IngressServer) {
	sync.mutex_lock(&server.caller.mutex)
	conn := server.caller.conn
	sync.mutex_unlock(&server.caller.mutex)
	if conn != nil {
		trans.connection_close(conn)
	}
}

qualify_wait_caller_ready :: proc(t: ^testing.T, server: ^IngressServer, loc := #caller_location) {
	start := time.now()
	for time.since(start) < 3 * time.Second {
		ready, _ := ingress_ready(server)
		if ready {
			return
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, loc = loc)
}

qualify_get_ok :: proc(t: ^testing.T, st: ^TerminatedStack, target: string, loc := #caller_location) -> bool {
	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST, loc = loc)
	if client == nil {
		return false
	}
	defer trans.connection_destroy(client)
	if write_http_request(client, "GET", target, TEST_PUBLIC_HOST, nil) != .None {
		testing.expect(t, false, loc = loc)
		return false
	}
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok, loc = loc)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"), loc = loc)
	testing.expect(t, strings.contains(head, fmt.tprintf("X-Echo-Target: %s\r\n", target)), loc = loc)
	return ok && strings.has_prefix(head, "HTTP/1.1 200 OK\r\n")
}

qualify_complete_success :: proc(job: ^StreamClientJob) -> bool {
	return job.ok &&
		strings.has_prefix(stream_client_head(job), "HTTP/1.1 200 OK\r\n") &&
		job.body_len == SLOW_WRITE_SIZE
}

@(test)
test_qualify_connection_churn_clears_slots :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st)
	defer stop_terminated_stack(&st)

	before := metrics_snapshot(&st.server)
	for i in 0 ..< QUALIFY_CHURN {
		target := fmt.tprintf("/churn-%d", i)
		testing.expect(t, qualify_get_ok(t, &st, target))
	}
	qualify_wait_idle(t, &st.server, &st.broker)
	after := metrics_snapshot(&st.server)
	testing.expect_value(t, after.connections[.Ok] - before.connections[.Ok], u64(QUALIFY_CHURN))
}

@(test)
test_qualify_eight_concurrent_gets_no_cross_talk :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st)
	defer stop_terminated_stack(&st)

	targets := [QUALIFY_CONCURRENT]string{"/q0", "/q1", "/q2", "/q3", "/q4", "/q5", "/q6", "/q7"}
	jobs := make([]StreamClientJob, QUALIFY_CONCURRENT)
	defer delete(jobs)
	threads: [QUALIFY_CONCURRENT]^thread.Thread
	for i in 0 ..< QUALIFY_CONCURRENT {
		jobs[i] = StreamClientJob {
			ep          = st.ep,
			cert_path   = st.cert_path,
			server_name = TEST_PUBLIC_HOST,
			target      = targets[i],
			host        = TEST_PUBLIC_HOST,
		}
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], stream_client_get)
	}
	for i in 0 ..< QUALIFY_CONCURRENT {
		if threads[i] != nil {
			thread.join(threads[i])
			thread.destroy(threads[i])
		}
	}
	for i in 0 ..< QUALIFY_CONCURRENT {
		testing.expect(t, jobs[i].ok)
		testing.expect(t, strings.contains(stream_client_head(&jobs[i]), fmt.tprintf("X-Echo-Target: %s\r\n", targets[i])))
		for j in 0 ..< QUALIFY_CONCURRENT {
			if i == j {
				continue
			}
			testing.expect(t, !strings.contains(stream_client_head(&jobs[i]), fmt.tprintf("X-Echo-Target: %s\r\n", targets[j])))
		}
	}
	testing.expect_value(t, st.origin.requests, QUALIFY_CONCURRENT)
	qualify_wait_idle(t, &st.server, &st.broker)
}

@(test)
test_qualify_slow_writer_sibling_then_idle :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st)
	defer stop_terminated_stack(&st)

	slow := StreamClientJob {
		ep          = st.ep,
		cert_path   = st.cert_path,
		server_name = TEST_PUBLIC_HOST,
		target      = "/slow",
		host        = TEST_PUBLIC_HOST,
	}
	fast := StreamClientJob {
		ep          = st.ep,
		cert_path   = st.cert_path,
		server_name = TEST_PUBLIC_HOST,
		target      = "/fast",
		host        = TEST_PUBLIC_HOST,
	}
	th_slow := thread.create_and_start_with_poly_data(&slow, stream_client_get)
	time.sleep(20 * time.Millisecond)
	th_fast := thread.create_and_start_with_poly_data(&fast, stream_client_get)
	if th_fast != nil {
		thread.join(th_fast)
		thread.destroy(th_fast)
	}
	if th_slow != nil {
		thread.join(th_slow)
		thread.destroy(th_slow)
	}
	testing.expect(t, fast.ok)
	testing.expect(t, strings.has_prefix(stream_client_head(&fast), "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(stream_client_head(&fast), "X-Echo-Target: /fast\r\n"))
	testing.expect(t, !strings.contains(stream_client_head(&fast), "X-Echo-Target: /slow\r\n"))
	testing.expect(t, slow.ok)
	testing.expect(t, strings.contains(stream_client_head(&slow), "X-Echo-Target: /slow\r\n"))
	testing.expect_value(t, slow.body_len, SLOW_WRITE_SIZE)
	qualify_wait_idle(t, &st.server, &st.broker)
}

@(test)
test_qualify_agent_loss_fails_inflight_then_recovers :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st)
	defer stop_terminated_stack(&st)

	slow := StreamClientJob {
		ep          = st.ep,
		cert_path   = st.cert_path,
		server_name = TEST_PUBLIC_HOST,
		target      = "/slow",
		host        = TEST_PUBLIC_HOST,
	}
	th_slow := thread.create_and_start_with_poly_data(&slow, stream_client_get)
	qualify_wait_origin_requests(t, &st.origin, 1)
	stop_agent(&st.agent, st.agent_th)
	st.agent = {}
	st.run = {}
	st.agent_th = nil
	if th_slow != nil {
		thread.join(th_slow)
		thread.destroy(th_slow)
	}
	testing.expect(t, !qualify_complete_success(&slow))

	client := dial_ingress_tls(t, st.ep, st.cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)
	testing.expect_value(t, write_http_request(client, "GET", "/absent", TEST_PUBLIC_HOST, nil), trans.TransportError.None)
	head, body, ok := read_http_message(client)
	defer delete(head)
	defer delete(body)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 503 Service Unavailable\r\n"))

	origin_ep, oerr := trans.listener_endpoint(st.origin.ln)
	testing.expect_value(t, oerr, trans.TransportError.None)
	st.agent_th = start_registered_agent(t, &st.broker, origin_ep, &st.agent, &st.run)
	testing.expect(t, qualify_get_ok(t, &st, "/after-agent"))
	qualify_wait_idle(t, &st.server, &st.broker)
}

@(test)
test_qualify_agent_a_loss_keeps_route_b :: proc(t: ^testing.T) {
	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin_a: HttpOriginFixture
	ep_a := start_http_origin(t, &origin_a)
	defer stop_http_origin(&origin_a)
	origin_b: HttpOriginFixture
	ep_b := start_http_origin(t, &origin_b)
	defer stop_http_origin(&origin_b)

	agent_a: ag.Agent
	run_a: AgentRunArg
	th_a := start_registered_agent(t, &fx, ep_a, &agent_a, &run_a, TEST_SERVICE)
	agent_b: ag.Agent
	run_b: AgentRunArg
	th_b := start_registered_agent(t, &fx, ep_b, &agent_b, &run_b, TEST_SERVICE_B)
	defer stop_agent(&agent_b, th_b)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)
	server: IngressServer
	start_full_ingress_routes(
		t,
		broker,
		cert_path,
		key_path,
		&server,
		[]string{"ingress.test=demo/echo", "other.test=demo/other"},
	)
	defer stop_full_ingress(&server)

	listen_ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)

	job_a := StreamClientJob {
		ep          = listen_ep,
		cert_path   = cert_path,
		server_name = TEST_PUBLIC_HOST,
		target      = "/route-a",
		host        = TEST_PUBLIC_HOST,
	}
	job_b := StreamClientJob {
		ep          = listen_ep,
		cert_path   = cert_path,
		server_name = TEST_OTHER_HOST,
		target      = "/route-b",
		host        = TEST_OTHER_HOST,
	}
	stream_client_get(&job_a)
	stream_client_get(&job_b)
	testing.expect(t, job_a.ok)
	testing.expect(t, job_b.ok)
	testing.expect(t, strings.contains(stream_client_head(&job_a), "X-Echo-Target: /route-a\r\n"))
	testing.expect(t, strings.contains(stream_client_head(&job_b), "X-Echo-Target: /route-b\r\n"))
	requests_a := origin_a.requests

	stop_agent(&agent_a, th_a)

	job_b2 := StreamClientJob {
		ep          = listen_ep,
		cert_path   = cert_path,
		server_name = TEST_OTHER_HOST,
		target      = "/route-b-after",
		host        = TEST_OTHER_HOST,
	}
	stream_client_get(&job_b2)
	testing.expect(t, job_b2.ok)
	testing.expect(t, strings.contains(stream_client_head(&job_b2), "X-Echo-Target: /route-b-after\r\n"))
	testing.expect_value(t, origin_b.requests, 2)

	unknown := dial_ingress_tls(t, listen_ep, cert_path, "localhost")
	defer trans.connection_destroy(unknown)
	uhead, ubody, uok := read_http_message(unknown)
	defer delete(uhead)
	defer delete(ubody)
	testing.expect(t, uok)
	testing.expect(t, strings.has_prefix(uhead, "HTTP/1.1 421 Misdirected Request\r\n"))
	testing.expect_value(t, origin_a.requests, requests_a)

	qualify_wait_idle(t, &server, &fx)
}

@(test)
test_qualify_caller_session_loss_recovers_new_get :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st)
	defer stop_terminated_stack(&st)

	slow := StreamClientJob {
		ep          = st.ep,
		cert_path   = st.cert_path,
		server_name = TEST_PUBLIC_HOST,
		target      = "/slow",
		host        = TEST_PUBLIC_HOST,
	}
	th_slow := thread.create_and_start_with_poly_data(&slow, stream_client_get)
	qualify_wait_origin_requests(t, &st.origin, 1)
	qualify_close_caller_broker(&st.server)
	if th_slow != nil {
		thread.join(th_slow)
		thread.destroy(th_slow)
	}
	testing.expect(t, !qualify_complete_success(&slow))
	qualify_wait_caller_ready(t, &st.server)
	testing.expect(t, qualify_get_ok(t, &st, "/after-reconnect"))
	qualify_wait_idle(t, &st.server, &st.broker)
}

@(test)
test_qualify_ingress_restart_serves_again :: proc(t: ^testing.T) {
	st: TerminatedStack
	start_terminated_stack(t, &st)
	defer stop_terminated_stack(&st)

	testing.expect(t, qualify_get_ok(t, &st, "/before-restart"))
	stop_full_ingress(&st.server)
	st.server = {}
	_ = start_full_ingress(t, st.broker_addr, st.cert_path, st.key_path, &st.server)
	ep, eerr := ingress_server_endpoint(&st.server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	st.ep = ep
	testing.expect(t, qualify_get_ok(t, &st, "/after-restart"))
	qualify_wait_idle(t, &st.server, &st.broker)
}
