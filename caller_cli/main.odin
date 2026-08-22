package main

import auth "../auth"
import cl "../caller"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import ver "../version"
import "core:fmt"
import "core:net"
import "core:os"
import "core:thread"

LOCAL_READ_BUF :: 16 * 1024

usage :: proc() {
	fmt.eprintf(
		"usage: thirp-connect [--version] --broker HOST:PORT (--token TOKEN | --token-file PATH) --service SERVICE_ID --listen HOST:PORT\n" +
		"       [--tls-ca PATH] [--tls-server-name NAME | --insecure]\n",
	)
}

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	broker := ""
	token := ""
	token_file := ""
	service := ""
	listen := ""
	insecure := false
	tls_ca := ""
	tls_server_name := ""

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--insecure":
			insecure = true
		case "--tls-ca":
			if i + 1 >= len(args) {
				fmt.eprintf("--tls-ca requires PATH\n")
				usage()
				return 1
			}
			i += 1
			tls_ca = args[i]
		case "--tls-server-name":
			if i + 1 >= len(args) {
				fmt.eprintf("--tls-server-name requires NAME\n")
				usage()
				return 1
			}
			i += 1
			tls_server_name = args[i]
		case "--broker":
			if i + 1 >= len(args) {
				fmt.eprintf("--broker requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			broker = args[i]
		case "--token":
			if i + 1 >= len(args) {
				fmt.eprintf("--token requires TOKEN\n")
				usage()
				return 1
			}
			i += 1
			token = args[i]
		case "--token-file":
			if i + 1 >= len(args) {
				fmt.eprintf("--token-file requires PATH\n")
				usage()
				return 1
			}
			i += 1
			token_file = args[i]
		case "--service":
			if i + 1 >= len(args) {
				fmt.eprintf("--service requires SERVICE_ID\n")
				usage()
				return 1
			}
			i += 1
			service = args[i]
		case "--listen":
			if i + 1 >= len(args) {
				fmt.eprintf("--listen requires HOST:PORT\n")
				usage()
				return 1
			}
			i += 1
			listen = args[i]
		case "--version":
			line := ver.version_line("thirp-connect")
			fmt.printf("%s\n", line)
			delete(line)
			return 0
		case "-h", "--help":
			usage()
			return 0
		case:
			fmt.eprintf("unknown flag: %s\n", args[i])
			usage()
			return 1
		}
	}

	if insecure && (len(tls_ca) > 0 || len(tls_server_name) > 0) {
		fmt.eprintf("--insecure cannot be combined with --tls-ca or --tls-server-name\n")
		return 1
	}
	if len(broker) == 0 || len(service) == 0 || len(listen) == 0 {
		fmt.eprintf("--broker, --service, and --listen are required\n")
		usage()
		return 1
	}
	if (len(token) == 0) == (len(token_file) == 0) {
		fmt.eprintf("exactly one of --token or --token-file is required\n")
		usage()
		return 1
	}
	if len(token_file) > 0 {
		if auth.file_group_or_world_readable(token_file) {
			fmt.eprintf("WARNING: token file is group- or world-readable; prefer mode 0600\n")
		}
		secret, serr := auth.read_secret_file(token_file)
		if serr != .None {
			fmt.eprintf("failed to read --token-file\n")
			return 1
		}
		token = secret
		defer delete(token)
	}

	service_id, sid_err := proto.make_service_id(service)
	if sid_err != .None {
		fmt.eprintf("invalid service id\n")
		return 1
	}

	broker_ep, berr := trans.parse_endpoint(broker)
	if berr != .None {
		fmt.eprintf("invalid --broker address\n")
		return 1
	}
	listen_ep, lerr := trans.parse_endpoint(listen)
	if lerr != .None {
		fmt.eprintf("invalid --listen address\n")
		return 1
	}
	if !endpoint_is_loopback(listen_ep) {
		fmt.eprintf("WARNING: --listen is not loopback; any host that can reach this address can use the bridge\n")
	}

	logger: log.Logger
	log.logger_init(&logger, .Info)

	c: cl.Caller
	cerr := cl.caller_init(
		&c,
		cl.CallerConfig {
			broker          = broker_ep,
			token           = token,
			insecure        = insecure,
			tls_ca          = tls_ca,
			tls_server_name = tls_server_name,
			implementation  = cl.DEFAULT_IMPLEMENTATION,
			logger          = &logger,
		},
	)
	if cerr != .None {
		fmt.eprintf("broker dial failed\n")
		return 1
	}
	defer cl.caller_destroy(&c)

	ln, nerr := trans.listener_listen(listen_ep)
	if nerr != .None {
		fmt.eprintf("listen failed\n")
		return 1
	}
	defer trans.listener_close(&ln)
	bound, _ := trans.listener_endpoint(ln)
	fmt.printf("thirp-connect listening on %s for %s\n", net.endpoint_to_string(bound), service)

	for {
		local, aerr := trans.listener_accept(&ln)
		if aerr != .None {
			return 1
		}
		stream, derr := cl.dial(&c, service_id)
		if derr != .None {
			trans.connection_destroy(local)
			fmt.eprintf("connect failed\n")
			continue
		}
		arg, nerr := new(BridgeArg)
		if nerr != .None {
			cl.conn_destroy(stream)
			trans.connection_destroy(local)
			return 1
		}
		arg.local = local
		arg.stream = stream
		thread.run_with_poly_data(arg, bridge_local)
	}
}

BridgeArg :: struct {
	local:  ^trans.Connection,
	stream: ^cl.Conn,
}

bridge_local :: proc(arg: ^BridgeArg) {
	defer {
		trans.connection_destroy(arg.local)
		free(arg)
	}
	pump: BridgePump
	pump.local = arg.local
	pump.stream = arg.stream
	th := thread.create_and_start_with_poly_data(&pump, bridge_conn_to_local)
	buf: [LOCAL_READ_BUF]u8
	for {
		n, err := trans.connection_read(arg.local, buf[:])
		if err != .None {
			break
		}
		_, werr := cl.conn_write(arg.stream, buf[:n])
		if werr != .None {
			break
		}
	}
	cl.conn_close(arg.stream)
	if th != nil {
		thread.join(th)
		thread.destroy(th)
	}
	cl.conn_destroy(arg.stream)
}

BridgePump :: struct {
	local:  ^trans.Connection,
	stream: ^cl.Conn,
}

endpoint_is_loopback :: proc(ep: net.Endpoint) -> bool {
	switch a in ep.address {
	case net.IP4_Address:
		return a[0] == 127
	case net.IP6_Address:
		return a == net.IP6_Loopback
	}
	return false
}

bridge_conn_to_local :: proc(p: ^BridgePump) {
	buf: [LOCAL_READ_BUF]u8
	for {
		n, err := cl.conn_read(p.stream, buf[:])
		if err != .None {
			_ = trans.connection_shutdown_write(p.local)
			return
		}
		if trans.connection_write(p.local, buf[:n]) != .None {
			cl.conn_close(p.stream)
			return
		}
	}
}
