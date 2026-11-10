#+build linux
package transport

import "core:os"
import "core:testing"
import "core:time"

// An exec in an embedding process must not keep an accepted socket alive.
// The SDK boundary test also execs a shell while the parallel suite serves
// connections. A ready byte and a release pipe hold this window explicitly.
@(test)
test_accepted_socket_eof_is_not_held_by_exec :: proc(t: ^testing.T) {
	ln, lerr := listener_listen(loopback_endpoint(0))
	testing.expect_value(t, lerr, TransportError.None)
	if lerr != .None { return }
	defer listener_close(&ln)
	ep, _ := listener_endpoint(ln)
	client, derr := connection_dial(ep)
	testing.expect_value(t, derr, TransportError.None)
	if derr != .None { return }
	defer connection_destroy(client)
	server, aerr := listener_accept(&ln)
	testing.expect_value(t, aerr, TransportError.None)
	if aerr != .None { return }

	release_r, release_w, perr := os.pipe()
	testing.expect_value(t, perr, nil)
	if perr != nil { connection_destroy(server); return }
	defer os.close(release_r)
	defer os.close(release_w)
	ready_r, ready_w, rerr := os.pipe()
	testing.expect_value(t, rerr, nil)
	if rerr != nil { connection_destroy(server); return }
	defer os.close(ready_r)
	defer os.close(ready_w)
	child, cerr := os.process_start({
		command = []string{"/bin/bash", "-c", "printf r; read -r release"},
		stdin = release_r,
		stdout = ready_w,
	})
	testing.expect_value(t, cerr, nil)
	if cerr != nil { connection_destroy(server); return }
	defer {
		_, _ = os.write(release_w, []u8{'\n'})
		state, werr := os.process_wait(child)
		testing.expect_value(t, werr, nil)
		testing.expect_value(t, state.exit_code, 0)
	}
	ready: [1]u8
	n, err := os.read(ready_r, ready[:])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, ready[0], u8('r'))

	connection_destroy(server)
	_ = connection_set_recv_timeout(client, time.Second)
	_, eof := connection_read(client, ready[:])
	testing.expect_value(t, eof, TransportError.Closed)
}
