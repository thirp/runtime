package main

import ag "thirp:agent"
import trans "thirp:transport"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

DEFAULT_NAMESPACE :: "sdk-demo"
ECHO_BUF :: 1024
CONNECT_WAIT :: 5 * time.Second

usage :: proc() {
	fmt.eprintf(
		"usage: ephemeral_host --broker HOST:PORT --token-file PATH [--namespace NAME]\n" +
		"       [--tls-ca PATH] [--tls-server-name NAME | --insecure]\n",
	)
}

EchoState :: struct {
	ln:   trans.Listener,
	stop: bool,
}

AgentRunArg :: struct {
	agent: ^ag.Agent,
}

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	broker := ""
	token_file := ""
	namespace := DEFAULT_NAMESPACE
	insecure := false
	tls_ca := ""
	tls_server_name := ""

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--insecure":
			insecure = true
		case "--broker":
			value, next, ok := require_flag_value(args, i, "--broker")
			if !ok {
				return 1
			}
			i = next
			broker = value
		case "--token-file":
			value, next, ok := require_flag_value(args, i, "--token-file")
			if !ok {
				return 1
			}
			i = next
			token_file = value
		case "--namespace":
			value, next, ok := require_flag_value(args, i, "--namespace")
			if !ok {
				return 1
			}
			i = next
			namespace = value
		case "--tls-ca":
			value, next, ok := require_flag_value(args, i, "--tls-ca")
			if !ok {
				return 1
			}
			i = next
			tls_ca = value
		case "--tls-server-name":
			value, next, ok := require_flag_value(args, i, "--tls-server-name")
			if !ok {
				return 1
			}
			i = next
			tls_server_name = value
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
	if len(broker) == 0 || len(token_file) == 0 {
		fmt.eprintf("--broker and --token-file are required\n")
		usage()
		return 1
	}

	token, tok_ok := read_token_file(token_file)
	if !tok_ok {
		fmt.eprintf("failed to read --token-file\n")
		return 1
	}
	defer delete(token)

	broker_ep, berr := trans.parse_endpoint(broker)
	if berr != .None {
		fmt.eprintf("invalid --broker address\n")
		return 1
	}

	echo: EchoState
	ln, lerr := trans.listener_listen(trans.loopback_endpoint(0))
	if lerr != .None {
		fmt.eprintf("echo listen failed\n")
		return 1
	}
	echo.ln = ln
	_ = trans.listener_set_recv_timeout(&echo.ln, 50 * time.Millisecond)
	target, terr := trans.listener_endpoint(echo.ln)
	if terr != .None {
		trans.listener_close(&echo.ln)
		fmt.eprintf("echo endpoint failed\n")
		return 1
	}
	echo_th := thread.create_and_start_with_poly_data(&echo, echo_accept_loop)
	defer {
		sync.atomic_store(&echo.stop, true)
		trans.listener_close(&echo.ln)
		if echo_th != nil {
			thread.join(echo_th)
			thread.destroy(echo_th)
		}
	}

	agent: ag.Agent
	aerr := ag.agent_init(
		&agent,
		ag.AgentConfig {
			broker          = broker_ep,
			token           = token,
			insecure        = insecure,
			tls_ca          = tls_ca,
			tls_server_name = tls_server_name,
		},
	)
	if aerr != .None {
		fmt.eprintf("agent_init failed\n")
		return 1
	}
	defer ag.agent_destroy(&agent)

	run_arg := AgentRunArg {
		agent = &agent,
	}
	run_th := thread.create_and_start_with_poly_data(&run_arg, agent_run_proc)
	if run_th == nil {
		fmt.eprintf("failed to start agent_run\n")
		return 1
	}
	defer {
		ag.agent_stop(&agent)
		thread.join(run_th)
		thread.destroy(run_th)
	}

	if !wait_agent_connected(&agent, CONNECT_WAIT) {
		fmt.eprintf("agent did not connect\n")
		return 1
	}

	hosting, herr := ag.host_ephemeral(&agent, ag.EphemeralConfig{namespace = namespace, local_address = target})
	if herr != .None {
		fmt.eprintf("host_ephemeral failed\n")
		return 1
	}
	defer ag.hosting_destroy(&hosting)

	fmt.printf("join_code: %s\n", hosting.join_code)
	fmt.printf("service_id: %s\n", string(hosting.service_id))
	_ = os.flush(os.stdout)

	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, .SIGINT)
	posix.sigaddset(&set, .SIGTERM)
	posix.pthread_sigmask(.BLOCK, &set, nil)
	sig: posix.Signal
	_ = posix.sigwait(&set, &sig)

	_ = ag.unregister_service(&agent, hosting.service_id)
	return 0
}

require_flag_value :: proc(args: []string, i: int, flag: string) -> (value: string, next: int, ok: bool) {
	if i + 1 >= len(args) {
		fmt.eprintf("%s requires a value\n", flag)
		usage()
		return "", i, false
	}
	return args[i + 1], i + 1, true
}

read_token_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return "", false
	}
	defer delete(data)
	text := strings.trim_space(string(data))
	if nl := strings.index_byte(text, '\n'); nl >= 0 {
		text = strings.trim_space(text[:nl])
	}
	if len(text) == 0 {
		return "", false
	}
	out, cerr := strings.clone(text)
	return out, cerr == .None
}

wait_agent_connected :: proc(agent: ^ag.Agent, timeout: time.Duration) -> bool {
	start := time.now()
	for time.since(start) < timeout {
		if ag.agent_is_connected(agent) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

agent_run_proc :: proc(arg: ^AgentRunArg) {
	_ = ag.agent_run(arg.agent)
}

echo_accept_loop :: proc(st: ^EchoState) {
	for {
		if sync.atomic_load(&st.stop) {
			return
		}
		conn, err := trans.listener_accept(&st.ln)
		if err == .Timeout {
			continue
		}
		if err != .None {
			return
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
