package caller

import log "../logging"
import trans "../transport"
import "core:sync"
import "core:thread"
import "core:time"

LOG_BROKER_SETUP_TIMEOUT :: "broker_setup_timeout"
SETUP_PHASE_TCP :: "tcp"
SETUP_PHASE_TLS :: "tls"
SETUP_PHASE_HANDSHAKE :: "handshake"

// Stack-owned by the setup thread; the waiter is always cancelled and joined
// before the socket can be destroyed or handed to the session reader. One
// absolute deadline, including TCP, bounds trickling peers as well as silence.
// Transport close shuts down the socket (and cancels pending Windows IO).
// Its IO lifetime guard defers freeing TLS/fd until SSL_connect/read/write exit.
BrokerSetup :: struct {
	mutex: sync.Mutex,
	cond: sync.Cond,
	deadline: time.Time,
	conn: ^trans.Connection,
	waiter: ^thread.Thread,
	cancelled: bool,
	timed_out: bool,
	phase: string,
}

broker_setup_wait :: proc(s: ^BrokerSetup) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	for !s.cancelled {
		left := time.diff(time.now(), s.deadline)
		if left <= 0 {
			s.timed_out = true
			trans.connection_close(s.conn)
			return
		}
		_ = sync.cond_wait_with_timeout(&s.cond, &s.mutex, left)
	}
}

broker_setup_begin :: proc(s: ^BrokerSetup, c: ^Caller) {
	s^ = {phase = SETUP_PHASE_TCP}
	if c.config.dial_timeout > 0 {
		s.deadline = time.time_add(time.now(), c.config.dial_timeout)
	}
}

broker_setup_finish :: proc(s: ^BrokerSetup, c: ^Caller, err: CallerError) -> CallerError {
	if s.deadline == {} {return err}
	sync.mutex_lock(&s.mutex)
	s.cancelled = true
	s.timed_out = s.timed_out || time.diff(time.now(), s.deadline) <= 0 || err == .Timeout
	sync.cond_signal(&s.cond)
	sync.mutex_unlock(&s.mutex)
	if s.waiter != nil {
		thread.join(s.waiter)
		thread.destroy(s.waiter)
		s.waiter = nil
	}
	if s.timed_out {
		caller_log(c, .Info, LOG_BROKER_SETUP_TIMEOUT, log.LogFields{reason = LOG_BROKER_SETUP_TIMEOUT, phase = s.phase})
		return .Timeout
	}
	if err == .None {
		// No setup waiter or setup socket options survive success. The reader
		// installs CALLER_POLL_INTERVAL as usual; DATA writes remain unbounded.
		_ = trans.connection_set_recv_timeout(s.conn, 0)
		_ = trans.connection_set_send_timeout(s.conn, 0)
	}
	return err
}
