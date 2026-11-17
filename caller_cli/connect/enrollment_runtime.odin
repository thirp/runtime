package connect

import cl "../../caller"
import log "../../logging"
import proto "../../protocol"
import trans "../../transport"
import ver "../../version"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

EnrollmentCaller :: struct {
	run: Run,
	grant_end: time.Time,
	expires_ns: i64, // atomic: renewed credential deadline
	force: bool, // protected by link.mutex
}
EnrollmentJob :: struct {
	e: ^Enrollment,
	link: ^EnrollmentLink,
	caller: ^EnrollmentCaller,
	ok, done: bool,
	th: ^thread.Thread,
	allocator: mem.Allocator,
}
EnrollmentLink :: struct {
	cfg: EnrollmentLinkConfig,
	// Repeated catalog ids have separate listeners but share one grant
	// credential: minting twice for the same enrollment holder revokes it.
	owner: ^EnrollmentLink,
	plan, pending: EnrollmentPlan,
	request_id: string,
	next: time.Time,
	backoff: time.Duration,
	job: ^EnrollmentJob,
	discard_job: bool,
	mutex: sync.Mutex,
	current: ^EnrollmentCaller,
	retired: [dynamic]^EnrollmentCaller,
	ln: trans.Listener,
	opened: bool,
	accept_th: ^thread.Thread,
	stop: bool, // atomic
	stall: time.Duration,
	buffer: int,
}

enrollment_share_links :: proc(links: []EnrollmentLink) {
	for &l, i in links {
		for &prior in links[:i] {
			if prior.cfg.service == l.cfg.service {l.owner = &prior; break}
		}
	}
}

enrollment_new_caller :: proc(e: ^Enrollment, l: ^EnrollmentLink) -> (^EnrollmentCaller, bool) {
	ep, ok := enrollment_resolve(e.cfg.broker, time.time_add(time.now(), cl.DEFAULT_DIAL_TIMEOUT))
	if !ok {return nil, false}
	sid, serr := proto.make_service_id(l.pending.service_id)
	if serr != .None {return nil, false}
	c := new(EnrollmentCaller)
	c.grant_end = l.pending.grant_end
	c.run.service_id, c.run.stall = sid, l.stall
	name := e.cfg.tls_server_name
	if len(name) == 0 {name, _ = trans.endpoint_host(e.cfg.broker)}
	impl := ver.version_line("thirp-connect")
	defer delete(impl)
	cerr := cl.caller_init(&c.run.c, {
		broker = ep, token = l.pending.token, tls_ca = e.cfg.tls_ca,
		tls_server_name = name, implementation = impl, logger = &e.logger,
		max_stream_buffer = l.buffer, dial_timeout = cl.DEFAULT_DIAL_TIMEOUT,
	})
	if cerr != .None {free(c); return nil, false}
	return c, true
}

enrollment_destroy_caller :: proc(c: ^EnrollmentCaller) {
	_ = run_stop_bridges(&c.run, 0)
	cl.caller_destroy(&c.run.c)
	delete(c.run.bridges)
	free(c)
}

enrollment_job_run :: proc(j: ^EnrollmentJob) {
	context.allocator = j.allocator
	j.caller, j.ok = enrollment_new_caller(j.e, j.link)
	sync.atomic_store(&j.done, true)
}

enrollment_retire_locked :: proc(l: ^EnrollmentLink, force: bool) {
	if l.current != nil {
		l.current.force = force
		append(&l.retired, l.current)
		l.current = nil
	}
}

// Never destroy a Caller on the control scheduler. This also keeps TLS/bridge
// teardown from postponing another link's renewal or token rotation.
enrollment_reap :: proc(e: ^Enrollment, l: ^EnrollmentLink) {
	for {
		dead: ^EnrollmentCaller
		sync.mutex_lock(&l.mutex)
		if c := l.current; c != nil && (enrollment_now(e)._nsec >= c.grant_end._nsec || enrollment_now(e)._nsec >= sync.atomic_load(&c.expires_ns)) {
			enrollment_retire_locked(l, true)
		}
		for c, i in l.retired {
			if c.force || enrollment_now(e)._nsec >= c.grant_end._nsec || sync.atomic_load(&c.run.live) == 0 {
				dead = c
				unordered_remove(&l.retired, i)
				break
			}
		}
		sync.mutex_unlock(&l.mutex)
		if dead == nil {return}
		fn := e.destroy_caller
		if fn == nil {fn = enrollment_destroy_caller}
		fn(dead)
	}
}

EnrollmentReaper :: struct {e: ^Enrollment, stop: bool, allocator: mem.Allocator}
enrollment_reaper :: proc(r: ^EnrollmentReaper) {
	context.allocator = r.allocator
	for !sync.atomic_load(&r.stop) {
		for &l in r.e.links {enrollment_reap(r.e, &l)}
		time.sleep(25*time.Millisecond)
	}
}

enrollment_accept :: proc(l: ^EnrollmentLink) {
	session := l
	if l.owner != nil {session = l.owner}
	for !sync.atomic_load(&l.stop) {
		sync.mutex_lock(&session.mutex)
		active := session.current != nil
		sync.mutex_unlock(&session.mutex)
		if !active {time.sleep(ACCEPT_POLL); continue}
		if trans.listener_wait_acceptable(&l.ln, ACCEPT_POLL) != .None {continue}
		local, err := trans.listener_accept(&l.ln)
		if err != .None {continue}
		sync.mutex_lock(&session.mutex)
		c := session.current
		if c == nil || time.now()._nsec >= c.grant_end._nsec || time.now()._nsec >= sync.atomic_load(&c.expires_ns) || sync.atomic_load(&c.run.live) >= MAX_BRIDGES {
			sync.mutex_unlock(&session.mutex)
			trans.connection_destroy(local)
			continue
		}
		b := new(BridgeArg)
		b.run, b.local = &c.run, local
		_ = trans.connection_set_recv_timeout(local, 0)
		_ = trans.connection_set_send_timeout(local, c.run.stall)
		run_track(&c.run, b)
		// The bridge is counted before releasing the pointer to its Caller.
		if thread.create_and_start_with_poly_data(b, bridge_local, self_cleanup = true) == nil {
			run_untrack(&c.run, b)
			trans.connection_destroy(local)
			free(b)
			run_bridge_done(&c.run)
		}
		sync.mutex_unlock(&session.mutex)
	}
}

enrollment_drop :: proc(e: ^Enrollment, l: ^EnrollmentLink) {
	sync.mutex_lock(&l.mutex)
	enrollment_retire_locked(l, true)
	for c in l.retired {c.force = true}
	sync.mutex_unlock(&l.mutex)
	enrollment_plan_destroy(&l.plan)
	if l.job != nil {l.discard_job = true} else {enrollment_plan_destroy(&l.pending)}
	delete(l.request_id); l.request_id = ""
}

enrollment_retry :: proc(e: ^Enrollment, l: ^EnrollmentLink, denied := false) {
	minimum, maximum, slow, _ := enrollment_intervals()
	if l.backoff == 0 {l.backoff = minimum}
	delay := l.backoff
	l.backoff = min(l.backoff*2, maximum)
	if denied {delay = slow}
	l.next = time.time_add(enrollment_now(e), delay)
}

enrollment_install :: proc(e: ^Enrollment, l: ^EnrollmentLink, c: ^EnrollmentCaller) {
	sync.atomic_store(&c.expires_ns, l.pending.expires_at._nsec)
	sync.mutex_lock(&l.mutex)
	enrollment_retire_locked(l, false)
	l.current = c
	sync.mutex_unlock(&l.mutex)
	enrollment_plan_destroy(&l.plan)
	l.plan = l.pending
	l.pending = {}
	l.next, l.backoff = {}, 0
	enrollment_log(e, "caller connected", &l.plan)
}

enrollment_link_step :: proc(e: ^Enrollment, l: ^EnrollmentLink) {
	if l.owner != nil {return}
	now := enrollment_now(e)
	sync.mutex_lock(&l.mutex)
	active := l.current != nil
	sync.mutex_unlock(&l.mutex)
	if len(l.plan.grant_id) > 0 && (!active || now._nsec >= l.plan.grant_end._nsec || now._nsec >= l.plan.expires_at._nsec) {
		sync.mutex_lock(&l.mutex)
		enrollment_retire_locked(l, true)
		sync.mutex_unlock(&l.mutex)
		enrollment_log(e, "waiting for approval", &l.plan)
		enrollment_plan_destroy(&l.plan)
		l.next = {}
	}
	if l.job != nil {
		j := l.job
		if !sync.atomic_load(&j.done) {return}
		thread.join(j.th); thread.destroy(j.th)
		l.job = nil
		valid := !l.discard_job && !e.denied && now._nsec < l.pending.expires_at._nsec && now._nsec < l.pending.grant_end._nsec
		if j.ok && valid {enrollment_install(e, l, j.caller)} else {
			if j.caller != nil {
				sync.mutex_lock(&l.mutex)
				j.caller.force = true
				append(&l.retired, j.caller)
				sync.mutex_unlock(&l.mutex)
			}
			// A broker denial needs a fresh control-plane mint, never a
			// session refresh. The mint rechecks enrollment and grant authority.
			delete(l.pending.token); l.pending.token = ""
			delete(l.pending.credential_id); l.pending.credential_id = ""
			if l.discard_job {enrollment_plan_destroy(&l.pending)}
			enrollment_retry(e, l)
		}
		l.discard_job = false
		free(j)
	}
	if e.denied || now._nsec < l.next._nsec {return}
	if len(l.plan.grant_id) > 0 && now._nsec >= l.plan.renew_at._nsec {
		err := enrollment_renew(e, &l.plan)
		if err == .Denied {
			enrollment_drop(e, l)
			enrollment_log(e, "waiting for approval")
			enrollment_retry(e, l, true)
			return
		}
		if err != .None {enrollment_retry(e, l); return}
		sync.mutex_lock(&l.mutex)
		if l.current != nil {sync.atomic_store(&l.current.expires_ns, l.plan.expires_at._nsec)}
		sync.mutex_unlock(&l.mutex)
		enrollment_log(e, "caller renewed", &l.plan)
	}
	if len(l.plan.grant_id) > 0 && now._nsec < l.plan.rollover_at._nsec {return}
	err := EnrollmentError.None
	if len(l.pending.grant_id) > 0 && now._nsec >= l.pending.grant_end._nsec {enrollment_plan_destroy(&l.pending)}
	if len(l.pending.token) > 0 && now._nsec >= l.pending.expires_at._nsec {
		delete(l.pending.token); l.pending.token = ""
		delete(l.pending.credential_id); l.pending.credential_id = ""
	}
	if len(l.pending.grant_id) == 0 {
		found: bool
		found, err = enrollment_pick_grant(e, l)
		if err == .None && !found && len(e.cfg.environment) == 0 {err = enrollment_create_grant(e, l)}
		if err == .None && len(l.pending.grant_id) == 0 {
			if len(l.plan.grant_id) == 0 {enrollment_log(e, "waiting for approval")}
			enrollment_retry(e, l)
			return
		}
	}
	if err == .None && len(l.pending.token) == 0 {err = enrollment_mint(e, &l.pending)}
	if err != .None {
		if err == .Denied {enrollment_drop(e, l); enrollment_log(e, "waiting for approval")}
		enrollment_retry(e, l, err == .Denied)
		return
	}
	if e.new_caller != nil {
		c, ok := e.new_caller(e, l)
		if ok {enrollment_install(e, l, c)} else {enrollment_retry(e, l)}
		return
	}
	j := new(EnrollmentJob)
	j.e, j.link, j.allocator = e, l, context.allocator
	j.th = thread.create_and_start_with_poly_data(j, enrollment_job_run)
	if j.th == nil {free(j); enrollment_retry(e, l); return}
	l.job = j
}

enrollment_step :: proc(e: ^Enrollment) -> EnrollmentError {
	now := enrollment_now(e)
	if len(e.pending_token) > 0 && now._nsec >= e.pending_expiry._nsec {return .Expired}
	// A successful rotate whose file write failed is retried before judging
	// the old overlap deadline. Its response remains owned in memory.
	if now._nsec >= e.self_next._nsec {
		err := enrollment_self(e)
		if err == .Config || err == .Expired {return err}
		if err == .Denied {
			e.denied = true
			for &l in e.links {enrollment_drop(e, &l)}
			enrollment_log(e, "waiting for approval")
		}
	}
	if e.expires_at != {} && enrollment_now(e)._nsec >= e.expires_at._nsec && len(e.pending_token) == 0 {return .Expired}
	// Do not mint before GET self has authenticated this enrollment/config.
	if e.expires_at == {} {return .None}
	for &l in e.links {enrollment_link_step(e, &l)}
	return .None
}

enrollment_main :: proc(path: string, stall: time.Duration, buffer: int, ctl: ^RunControl) -> int {
	cfg, token, ok := enrollment_config_load(path)
	if !ok {fmt.eprintln("invalid caller.conf or token file (require private mode 0600)"); return 1}
	defer enrollment_config_destroy(&cfg)
	e := Enrollment{cfg = &cfg, token = token}
	log.logger_init(&e.logger, .Info)
	e.links = make([]EnrollmentLink, len(cfg.links))
	defer {
		for &l in e.links {sync.atomic_store(&l.stop, true)}
		for &l in e.links {
			if l.accept_th != nil {thread.join(l.accept_th); thread.destroy(l.accept_th)}
			if l.job != nil {
				thread.join(l.job.th); thread.destroy(l.job.th)
				if l.job.caller != nil {l.job.caller.force = true; append(&l.retired, l.job.caller)}
				free(l.job); l.job = nil
			}
			enrollment_drop(&e, &l)
			enrollment_reap(&e, &l)
			delete(l.retired)
			if l.opened {trans.listener_close(&l.ln)}
		}
		delete(e.links); delete(e.token); delete(e.pending_token)
	}
	for &l, i in e.links {l.cfg, l.stall, l.buffer = cfg.links[i], stall, buffer}
	enrollment_share_links(e.links)
	for &l in e.links {
		ep, _ := trans.parse_endpoint(l.cfg.listen)
		if !endpoint_is_loopback(ep) {fmt.eprintln("WARNING: caller.conf listen is not loopback; reachable hosts can use the bridge")}
		l.ln, _, l.opened = listen_local(ep)
		if !l.opened {fmt.eprintln("caller.conf listen failed"); return 1}
		for l.accept_th == nil {
			if ctl != nil && sync.atomic_load(&ctl.stop) {return 0}
			l.accept_th = thread.create_and_start_with_poly_data(&l, enrollment_accept)
			if l.accept_th == nil {
				poll, _, _, _ := enrollment_intervals()
				time.sleep(poll)
			}
		}
	}
	r := EnrollmentReaper{e = &e, allocator = context.allocator}
	reaper: ^thread.Thread
	for reaper == nil {
		if ctl != nil && sync.atomic_load(&ctl.stop) {return 0}
		reaper = thread.create_and_start_with_poly_data(&r, enrollment_reaper)
		if reaper == nil {
			poll, _, _, _ := enrollment_intervals()
			time.sleep(poll)
		}
	}
	defer {sync.atomic_store(&r.stop, true); thread.join(reaper); thread.destroy(reaper)}
	when #config(THIRP_LAB_TIMERS, false) {fmt.eprintln("THIRP_LAB_TIMERS_ENABLED")}
	for {
		if ctl != nil && sync.atomic_load(&ctl.stop) {return 0}
		if enrollment_step(&e) != .None {fmt.eprintln("caller enrollment expired or configuration invalid"); return 1}
		time.sleep(25*time.Millisecond)
	}
}
