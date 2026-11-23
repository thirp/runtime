#+build linux, darwin
package transport

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

TlsFifoProbe :: struct {
	cert, key: string,
	err:       TransportError,
	finished:  sync.Sema,
}

tls_fifo_probe :: proc(probe: ^TlsFifoProbe) {
	ctx, err := tls_server_context_init(probe.cert, probe.key, allow_key_prompt = false)
	tls_server_context_destroy(ctx)
	probe.err = err
	sync.sema_post(&probe.finished)
}

@(test)
test_tls_reload_rejects_fifo_without_writer :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "thirp-reload-fifo-*", context.allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer delete(dir)
	defer os.remove_all(dir)
	cert := fmt.aprintf("%s/cert.pem", dir)
	defer delete(cert)
	key := fmt.aprintf("%s/key.pem", dir)
	defer delete(key)
	fifo := fmt.aprintf("%s/fifo.pem", dir)
	defer delete(fifo)
	fifo_c := strings.clone_to_cstring(fifo)
	defer delete(fifo_c)
	if !testing.expect(t, os.write_entire_file_from_string(cert, TEST_SERVER_CERT) == nil) ||
	   !testing.expect(t, os.write_entire_file_from_string(key, TEST_SERVER_KEY) == nil) ||
	   !testing.expect_value(t, posix.mkfifo(fifo_c, {.IRUSR, .IWUSR}), posix.result.OK) {
		return
	}

	probes := [2]TlsFifoProbe{{cert = fifo, key = key}, {cert = cert, key = fifo}}
	for &probe in probes {
		worker := thread.create_and_start_with_poly_data(&probe, tls_fifo_probe)
		if !testing.expect(t, worker != nil) {
			return
		}
		if !testing.expect(t, sync.sema_wait_with_timeout(&probe.finished, 5 * time.Second),
		                   "reload must reject a FIFO without waiting for a writer") {
			// On a regression, give a blocking open its writer and EOF so
			// the test can join the worker and report the failure.
			writer := posix.open(fifo_c, {.WRONLY, .NONBLOCK})
			if writer >= 0 {
				posix.close(writer)
			}
		}
		thread.join(worker)
		thread.destroy(worker)
		testing.expect_value(t, probe.err, TransportError.Tls)
	}
}
