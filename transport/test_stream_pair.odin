package transport

when ODIN_TEST {
	// Loopback TCP exercises the platform's socket I/O and send progress.
	test_stream_pair :: proc() -> (first, second: ^Connection, err: TransportError) {
		listener, listen_err := test_listener_listen(loopback_endpoint(0))
		if listen_err != .None {
			return nil, nil, listen_err
		}
		defer listener_close(&listener)
		endpoint, endpoint_err := listener_endpoint(listener)
		if endpoint_err != .None {
			return nil, nil, endpoint_err
		}
		first, err = connection_dial(endpoint)
		if err != .None {
			return nil, nil, err
		}
		second, err = listener_accept(&listener)
		if err != .None {
			connection_destroy(first)
			return nil, nil, err
		}
		return first, second, .None
	}
}
