package logging

LogLevel :: enum {
	Error,
	Warn,
	Info,
	Debug,
}

MAX_LOG_FIELD :: 256

LogFields :: struct {
	session_id:        u64,
	stream_id:         u64,
	principal_id:      string,
	organization_id:   string,
	credential_label:  string,
	service_id:        string,
	public_host:       string,
	mode:              string,
	remote_address:    string,
	error_code:        string,
	reason:            string,
	// stream_id is omitted when zero unless stream_id_set. streams is omitted
	// unless streams_set, so a session drop can report that it killed none.
	stream_id_set:     bool,
	streams:           int,
	streams_set:       bool,
	// Milliseconds. Omitted from the JSON when zero, so existing events
	// stay the same shape. The short dial-timeout warning sets both.
	dial_timeout_ms:   int,
	cap_floor_ms:      int,
}

LogSink :: proc(text: string)

Logger :: struct {
	min_level: LogLevel,
	sink:      LogSink,
}
