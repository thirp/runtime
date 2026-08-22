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
}

LogSink :: proc(text: string)

Logger :: struct {
	min_level: LogLevel,
	sink:      LogSink,
}
