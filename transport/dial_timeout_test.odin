package transport

import "core:fmt"
import "core:net"
import "core:testing"
import "core:time"

DialTimeoutSink :: struct {
	socket:       net.TCP_Socket,
	endpoint:     net.Endpoint,
	fillers:      [2]net.TCP_Socket,
	filler_count: int,
}

dial_timeout_fill_queue :: proc(t: ^testing.T, sink: ^DialTimeoutSink, count: int) -> bool {
	for sink.filler_count < count {
		socket, err := net.dial_tcp(sink.endpoint)
		if !testing.expectf(t, err == nil, "queue filler dial failed (%v)", err) {
			return false
		}
		sink.fillers[sink.filler_count] = socket
		sink.filler_count += 1
	}
	return true
}

@(test)
test_dial_timeout_bounds_syn_retries :: proc(t: ^testing.T) {
	socket, create_err := net.create_socket(.IP4, .TCP)
	if !testing.expect_value(t, create_err, net.Create_Socket_Error.None) {
		return
	}
	sink := DialTimeoutSink{socket = socket.(net.TCP_Socket)}
	defer {
		net.close(sink.socket)
		for filler in sink.fillers[:sink.filler_count] {
			net.close(filler)
		}
	}
	if !testing.expect_value(t, net.bind(sink.socket, loopback_endpoint(0)), net.Bind_Error.None) {
		return
	}
	endpoint, bound_err := net.bound_endpoint(sink.socket)
	if !testing.expect_value(t, bound_err, net.Socket_Info_Error.None) {
		return
	}
	sink.endpoint = endpoint
	if !dial_timeout_sink_listen(t, &sink) {
		return
	}

	// Separate budgets show that the elapsed time follows the caller's
	// deadline. Allow for scheduling and the kernel's poll granularity.
	tolerance :: 100 * time.Millisecond
	budgets := [2]time.Duration{150 * time.Millisecond, 400 * time.Millisecond}
	for budget in budgets {
		start := time.now()
		conn, err := connection_dial_timeout(sink.endpoint, budget)
		elapsed := time.since(start)
		testing.expect_value(t, err, TransportError.Timeout)
		testing.expect(t, conn == nil, "a stalled SYN returned a connection")
		if conn != nil {
			connection_destroy(conn)
		}
		testing.expectf(t, elapsed >= budget - tolerance, "dial returned early (budget=%v elapsed=%v)", budget, elapsed)
		testing.expectf(t, elapsed <= budget + tolerance, "dial exceeded its budget (budget=%v elapsed=%v)", budget, elapsed)
		fmt.printfln("dial timeout: budget=%v elapsed=%v result=%v", budget, elapsed, err)
	}
}

@(test)
test_dial_timeout_zero_still_connects :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	defer listener_close(&ln)
	ep, eerr := listener_endpoint(ln)
	testing.expect_value(t, eerr, TransportError.None)
	conn, derr := connection_dial_timeout(ep, 0)
	testing.expect_value(t, derr, TransportError.None)
	if conn != nil {
		connection_destroy(conn)
	}
}
