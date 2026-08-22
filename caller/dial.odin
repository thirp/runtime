package caller

import proto "../protocol"
import "core:strings"
import "core:sync"
import "core:time"

DIAL_WAIT_SLICE :: 5 * time.Millisecond

dial :: proc(c: ^Caller, service_id: proto.ServiceId) -> (^Conn, CallerError) {
	if c == nil {
		return nil, .InvalidConfig
	}
	if proto.check_service_id(string(service_id)) != .None {
		return nil, .InvalidServiceId
	}

	stream, aerr := new(Conn)
	if aerr != .None {
		return nil, .OutOfMemory
	}
	stream.caller = c
	stream.inbound = make([dynamic]u8)

	start := time.now()
	timeout := c.config.dial_timeout
	sync.mutex_lock(&c.mutex)
	for (c.pending != nil || !c.connected) && !sync.atomic_load(&c.stop) {
		if dial_deadline_hit(start, timeout) {
			sync.mutex_unlock(&c.mutex)
			delete(stream.inbound)
			free(stream)
			return nil, .Timeout
		}
		if timeout > 0 {
			sync.mutex_unlock(&c.mutex)
			time.sleep(DIAL_WAIT_SLICE)
			sync.mutex_lock(&c.mutex)
		} else {
			sync.cond_wait(&c.cond, &c.mutex)
		}
	}
	if sync.atomic_load(&c.stop) {
		sync.mutex_unlock(&c.mutex)
		delete(stream.inbound)
		free(stream)
		return nil, .Closed
	}
	c.pending = stream
	c.pending_err = .None
	broker := c.conn
	sync.mutex_unlock(&c.mutex)

	payload, perr := proto.encode_connect(proto.Connect{service_id = service_id})
	if perr != .None {
		sync.mutex_lock(&c.mutex)
		if c.pending == stream {
			c.pending = nil
		}
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mutex)
		delete(stream.inbound)
		free(stream)
		return nil, .Internal
	}
	ok := caller_write(broker, .Connect, payload)
	delete(payload)
	if !ok {
		sync.mutex_lock(&c.mutex)
		if c.pending == stream {
			c.pending = nil
		}
		sync.cond_broadcast(&c.cond)
		sync.mutex_unlock(&c.mutex)
		delete(stream.inbound)
		free(stream)
		return nil, .Transport
	}

	sync.mutex_lock(&c.mutex)
	for c.pending == stream && !sync.atomic_load(&c.stop) {
		if dial_deadline_hit(start, timeout) {
			if c.pending == stream {
				c.pending = nil
				c.pending_err = .Timeout
			}
			sync.cond_broadcast(&c.cond)
			sync.mutex_unlock(&c.mutex)
			delete(stream.inbound)
			free(stream)
			return nil, .Timeout
		}
		if timeout > 0 {
			sync.mutex_unlock(&c.mutex)
			time.sleep(DIAL_WAIT_SLICE)
			sync.mutex_lock(&c.mutex)
		} else {
			sync.cond_wait(&c.cond, &c.mutex)
		}
	}
	err := c.pending_err
	sync.mutex_unlock(&c.mutex)
	if err != .None {
		delete(stream.inbound)
		free(stream)
		return nil, err
	}
	return stream, .None
}

dial_deadline_hit :: proc(start: time.Time, timeout: time.Duration) -> bool {
	return timeout > 0 && time.since(start) >= timeout
}

dial_join_code :: proc(c: ^Caller, namespace: string, join_code: string) -> (^Conn, CallerError) {
	if len(namespace) == 0 || len(join_code) == 0 {
		return nil, .InvalidServiceId
	}
	parts := [?]string{namespace, "/", join_code}
	id_str, cerr := strings.concatenate(parts[:])
	if cerr != .None {
		return nil, .OutOfMemory
	}
	defer delete(id_str)
	sid, serr := proto.make_service_id(id_str)
	if serr != .None {
		return nil, .InvalidServiceId
	}
	return dial(c, sid)
}
