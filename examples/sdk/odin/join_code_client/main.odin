package main

import cl "thirp:caller"
import trans "thirp:transport"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

DEFAULT_NAMESPACE :: "sdk-demo"
DEFAULT_PAYLOAD :: "hello"
DIAL_TRIES :: 50
DIAL_WAIT :: 50 * time.Millisecond

usage :: proc() {
	fmt.eprintf(
		"usage: join_code_client --broker HOST:PORT --token-file PATH --join-code CODE\n" +
		"       [--namespace NAME] [--payload TEXT] [--tls-ca PATH] [--tls-server-name NAME | --insecure]\n",
	)
	fmt.eprintf("The join code identifies a service. AUTH still uses the token; the code is not a credential.\n")
}

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	broker := ""
	token_file := ""
	namespace := DEFAULT_NAMESPACE
	join_code := ""
	payload_text := DEFAULT_PAYLOAD
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
		case "--join-code":
			value, next, ok := require_flag_value(args, i, "--join-code")
			if !ok {
				return 1
			}
			i = next
			join_code = value
		case "--payload":
			value, next, ok := require_flag_value(args, i, "--payload")
			if !ok {
				return 1
			}
			i = next
			payload_text = value
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
	if len(broker) == 0 || len(token_file) == 0 || len(join_code) == 0 {
		fmt.eprintf("--broker, --token-file, and --join-code are required\n")
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

	c: cl.Caller
	cerr := cl.caller_init(
		&c,
		cl.CallerConfig {
			broker          = broker_ep,
			token           = token,
			insecure        = insecure,
			tls_ca          = tls_ca,
			tls_server_name = tls_server_name,
		},
	)
	if cerr != .None {
		fmt.eprintf("caller_init failed\n")
		return 1
	}
	defer cl.caller_destroy(&c)

	conn: ^cl.Conn
	derr: cl.CallerError
	for _ in 0 ..< DIAL_TRIES {
		conn, derr = cl.dial_join_code(&c, namespace, join_code)
		if derr == .None {
			break
		}
		if derr != .ServiceNotFound {
			fmt.eprintf("dial_join_code failed\n")
			return 1
		}
		time.sleep(DIAL_WAIT)
	}
	if derr != .None || conn == nil {
		fmt.eprintf("dial_join_code timed out waiting for service\n")
		return 1
	}
	defer cl.conn_destroy(conn)

	payload := transmute([]u8)payload_text
	n, werr := cl.conn_write(conn, payload)
	if werr != .None || n != len(payload) {
		fmt.eprintf("conn_write failed\n")
		return 1
	}

	buf: [64]u8
	got, rerr := cl.conn_read(conn, buf[:])
	if rerr != .None || got != len(payload) || string(buf[:got]) != payload_text {
		fmt.eprintf("conn_read mismatch\n")
		return 1
	}

	cl.conn_close(conn)
	fmt.printf("ok\n")
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
