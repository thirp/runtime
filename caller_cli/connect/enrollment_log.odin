package connect

import cl "../../caller"
import log "../../logging"
import "core:fmt"
import "core:sync"
import "core:time"

ENROLLMENT_FAILURE_LOG_INTERVAL :: 10*time.Second

EnrollmentFailureKey :: struct {source, reason: string}

// Source and reason are fixed labels. The table stays bounded even when many
// services or local clients see the same failure. The first failure logs at once.
enrollment_failure :: proc(e: ^Enrollment, source, reason: string, service := "", status := "", phase := "",
	at: time.Tick = {}) {
	sync.mutex_lock(&e.failure_mutex)
	defer sync.mutex_unlock(&e.failure_mutex)
	now := at == {} ? time.tick_now() : at
	key := EnrollmentFailureKey{source, reason}
	if until, seen := e.failure_next[key]; seen && time.tick_diff(now, until) > 0 {return}
	if e.failure_next == nil {e.failure_next = make(map[EnrollmentFailureKey]time.Tick)}
	e.failure_next[key] = time.tick_add(now, ENROLLMENT_FAILURE_LOG_INTERVAL)
	fields := log.LogFields{mode = "caller-conf", organization_id = e.cfg.org, service_id = service,
		reason = reason, error_code = status, phase = phase == "" ? source : phase}
	switch source {
	case "api": log.log_event(&e.logger, .Warn, "caller API setup failed", fields)
	case "broker": log.log_event(&e.logger, .Warn, "caller broker setup failed", fields)
	case "stream": log.log_event(&e.logger, .Warn, "caller stream setup failed", fields)
	case "approval": log.log_event(&e.logger, .Info, "waiting for approval", fields)
	}
}

enrollment_broker_failure :: proc(user: rawptr, phase, reason: string) {
	run := (^Run)(user)
	enrollment_setup_failure(run.enrollment, run.catalog_service, phase, reason)
}

enrollment_setup_failure :: proc(e: ^Enrollment, service, phase, reason: string, at: time.Tick = {}) {
	enrollment_failure(e, "broker", reason, service, phase = phase, at = at)
}

enrollment_stream_failure :: proc(run: ^Run, err: cl.CallerError) {
	if err == .Closed {return}
	reason := "connect_failed"
	#partial switch err {
	case .ServiceNotFound: reason = "unknown_service"
	case .AuthFailed, .Unauthorized: reason = "unauthorized_or_revoked"
	case .Timeout: reason = "timeout"
	case:
	}
	enrollment_failure(run.enrollment, "stream", reason, run.catalog_service, status = fmt.tprintf("%v", err))
}
