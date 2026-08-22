package main

import trans "../transport"
import "core:fmt"
import "core:net"
import "core:os"
import "core:thread"

ECHO_BUF :: 16 * 1024

usage :: proc() {
	fmt.eprintf("usage: thirp-echo --listen HOST:PORT\n")
}

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	listen := ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--listen":
			if i + 1 >= len(args) {
				fmt.eprintf("--listen requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			listen = args[i]
		case "-h", "--help":
			usage()
			return 0
		case:
			fmt.eprintf("unknown flag: %s\n", args[i])
			usage()
			return 1
		}
	}
	if len(listen) == 0 {
		fmt.eprintf("--listen is required\n")
		usage()
		return 1
	}

	ep, eerr := trans.parse_endpoint(listen)
	if eerr != .None {
		fmt.eprintf("invalid --listen address\n")
		return 1
	}

	ln, lerr := trans.listener_listen(ep)
	if lerr != .None {
		fmt.eprintf("listen failed\n")
		return 1
	}
	defer trans.listener_close(&ln)
	bound, _ := trans.listener_endpoint(ln)
	fmt.printf("thirp-echo listening on %s\n", net.endpoint_to_string(bound))

	for {
		conn, aerr := trans.listener_accept(&ln)
		if aerr != .None {
			return 1
		}
		thread.run_with_poly_data(conn, echo_conn)
	}
}

echo_conn :: proc(conn: ^trans.Connection) {
	defer trans.connection_destroy(conn)
	buf: [ECHO_BUF]u8
	for {
		n, rerr := trans.connection_read(conn, buf[:])
		if rerr != .None {
			return
		}
		if trans.connection_write(conn, buf[:n]) != .None {
			return
		}
	}
}
