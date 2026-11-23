package broker

import trans "../transport"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

TLS_RELOAD_POLL_INTERVAL :: time.Second
TLS_RELOAD_SUFFIX :: ".reload"

TLS_RELOAD_ID_LENGTH :: 32
TlsReloadId :: [TLS_RELOAD_ID_LENGTH]byte

TlsReloadWatcher :: struct {
	server:   ^Server,
	cert:     string,
	key:      string,
	request:  string,
	last:     TlsReloadId,
	stop:     sync.Sema,
	worker:   ^thread.Thread,
}

tls_reload_watcher_init :: proc(w: ^TlsReloadWatcher, server: ^Server, cert, key: string) -> bool {
	path, err := strings.concatenate({cert, TLS_RELOAD_SUFFIX})
	if err != .None {
		return false
	}
	w^ = TlsReloadWatcher{server = server, cert = cert, key = key, request = path}
	// A request left behind by an earlier process is already covered by startup.
	w.last, _ = tls_reload_read_request(path)
	return true
}

@(private)
tls_reload_read_request :: proc(path: string) -> (TlsReloadId, bool) {
	file, ok := trans.open_regular_input(path, follow_final_symlink = false)
	if !ok {
		return {}, false
	}
	defer trans.close_regular_input(file)
	// A request is complete only when the full ID and line ending are visible.
	line: [TLS_RELOAD_ID_LENGTH + 2]byte
	if file.size != len(line) - 1 && file.size != len(line) {
		return {}, false
	}
	if !trans.read_regular_input(file, line[:int(file.size)]) ||
	   line[file.size - 1] != '\n' ||
	   (file.size == len(line) && line[TLS_RELOAD_ID_LENGTH] != '\r') {
		return {}, false
	}
	id: TlsReloadId
	for ch, i in line[:TLS_RELOAD_ID_LENGTH] {
		if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') && !(ch >= 'A' && ch <= 'F') {
			return {}, false
		}
		id[i] = ch
	}
	return id, true
}

@(private)
tls_reload_poll :: proc(w: ^TlsReloadWatcher) {
	id, ok := tls_reload_read_request(w.request)
	if !ok || id == w.last {
		return
	}
	// Consume the request before loading so failed attempts are logged once.
	w.last = id
	_ = server_reload_tls(w.server, w.cert, w.key)
}

@(private)
tls_reload_watch :: proc(w: ^TlsReloadWatcher) {
	for !sync.sema_wait_with_timeout(&w.stop, TLS_RELOAD_POLL_INTERVAL) {
		tls_reload_poll(w)
	}
}

tls_reload_watcher_start :: proc(w: ^TlsReloadWatcher) -> bool {
	w.worker = thread.create_and_start_with_poly_data(w, tls_reload_watch)
	return w.worker != nil
}

tls_reload_watcher_destroy :: proc(w: ^TlsReloadWatcher) {
	if w.worker != nil {
		sync.sema_post(&w.stop)
		thread.join(w.worker)
		thread.destroy(w.worker)
	}
	delete(w.request)
}
