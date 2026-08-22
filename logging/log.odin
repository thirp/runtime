package logging

import "core:fmt"
import "core:os"
import "core:time"

log_sink_stderr :: proc(text: string) {
	fmt.fprint(os.stderr, text)
}

logger_init :: proc(logger: ^Logger, min_level: LogLevel, sink: LogSink = log_sink_stderr) {
	logger.min_level = min_level
	logger.sink = sink
}

log_level_from_string :: proc(value: string) -> (LogLevel, bool) {
	switch value {
	case "error":
		return .Error, true
	case "warn", "warning":
		return .Warn, true
	case "info":
		return .Info, true
	case "debug":
		return .Debug, true
	}
	return .Info, false
}

log_level_name :: proc(level: LogLevel) -> string {
	switch level {
	case .Error:
		return "error"
	case .Warn:
		return "warn"
	case .Info:
		return "info"
	case .Debug:
		return "debug"
	}
	return "info"
}

log_event :: proc(logger: ^Logger, level: LogLevel, event: string, fields: LogFields = {}) {
	if logger == nil || logger.sink == nil {
		return
	}
	if int(level) > int(logger.min_level) {
		return
	}

	buf: [dynamic]u8
	defer delete(buf)
	append_string(&buf, "{\"ts\":")
	append_ts(&buf)
	append_string(&buf, ",\"level\":")
	append_json_string(&buf, log_level_name(level))
	append_string(&buf, ",\"event\":")
	append_json_string(&buf, event)
	if fields.session_id != 0 {
		append_string(&buf, ",\"session_id\":")
		append_u64(&buf, fields.session_id)
	}
	if fields.stream_id != 0 {
		append_string(&buf, ",\"stream_id\":")
		append_u64(&buf, fields.stream_id)
	}
	append_opt_string(&buf, "principal_id", fields.principal_id)
	append_opt_string(&buf, "organization_id", fields.organization_id)
	append_opt_string(&buf, "credential_label", fields.credential_label)
	append_opt_string(&buf, "service_id", fields.service_id)
	append_opt_string(&buf, "public_host", fields.public_host)
	append_opt_string(&buf, "mode", fields.mode)
	append_opt_string(&buf, "remote_address", fields.remote_address)
	append_opt_string(&buf, "error_code", fields.error_code)
	append_opt_string(&buf, "reason", fields.reason)
	append_string(&buf, "}\n")
	logger.sink(string(buf[:]))
}

append_string :: proc(buf: ^[dynamic]u8, s: string) {
	if len(s) == 0 {
		return
	}
	append(buf, ..transmute([]u8)s)
}

append_opt_string :: proc(buf: ^[dynamic]u8, key: string, value: string) {
	if len(value) == 0 {
		return
	}
	clipped := value
	if len(clipped) > MAX_LOG_FIELD {
		clipped = clipped[:MAX_LOG_FIELD]
	}
	append_string(buf, ",\"")
	append_string(buf, key)
	append_string(buf, "\":")
	append_json_string(buf, clipped)
}

append_u64 :: proc(buf: ^[dynamic]u8, n: u64) {
	append_string(buf, fmt.tprintf("%d", n))
}

append_ts :: proc(buf: ^[dynamic]u8) {
	nanos := time.time_to_unix_nano(time.now())
	sec := nanos / 1_000_000_000
	nsec := nanos % 1_000_000_000
	if nsec < 0 {
		nsec += 1_000_000_000
		sec -= 1
	}
	append_string(buf, fmt.tprintf("%d.%09d", sec, nsec))
}

append_json_string :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			append_string(buf, "\\\"")
		case '\\':
			append_string(buf, "\\\\")
		case '\n':
			append_string(buf, "\\n")
		case '\r':
			append_string(buf, "\\r")
		case '\t':
			append_string(buf, "\\t")
		case:
			if c < 0x20 {
				append_string(buf, fmt.tprintf("\\u%04x", u32(c)))
			} else {
				append(buf, c)
			}
		}
	}
	append(buf, '"')
}
