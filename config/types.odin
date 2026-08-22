package config

import "core:mem"

MAX_CONFIG_FILE_LEN :: 1024 * 1024
MAX_IDENTITY_LEN :: 128

ConfigError :: enum {
	None,
	Io,
	Empty,
	TooLarge,
	InvalidLine,
	UnknownKey,
	DuplicateKey,
	InvalidValue,
	MissingRequired,
	InsecureProduction,
	OutOfMemory,
}

IniEntry :: struct {
	key:   string,
	value: string,
	line:  int,
}

IniDocument :: struct {
	allocator: mem.Allocator,
	entries:   [dynamic]IniEntry,
}

SourcedString :: struct {
	value: string,
	line:  int,
	flag:  string,
	set:   bool,
}

SourcedInt :: struct {
	value: int,
	line:  int,
	flag:  string,
	set:   bool,
}

SourcedBool :: struct {
	value: bool,
	line:  int,
	flag:  string,
	set:   bool,
}

ValidationIssue :: struct {
	line:    int,
	flag:    string,
	message: string,
}

BrokerSettings :: struct {
	allocator:                    mem.Allocator,
	listen:                       SourcedString,
	tls_cert:                     SourcedString,
	tls_key:                      SourcedString,
	insecure:                     SourcedBool,
	policy_mode:                  SourcedString,
	tokens:                       [dynamic]SourcedString,
	token_files:                  [dynamic]SourcedString,
	capabilities:                 [dynamic]SourcedString,
	allow_register:               [dynamic]SourcedString,
	allow_connect:                [dynamic]SourcedString,
	org_namespace:                [dynamic]SourcedString,
	max_stream_buffer:            SourcedInt,
	max_connection_buffer:        SourcedInt,
	max_streams_per_session:      SourcedInt,
	max_registrations_per_session: SourcedInt,
	max_frame_size:               SourcedInt,
	max_connections:              SourcedInt,
	max_connections_per_ip:       SourcedInt,
	auth_rate_limit:              SourcedInt,
	register_rate_limit:          SourcedInt,
	connect_rate_limit:           SourcedInt,
	max_buffered_bytes:           SourcedInt,
	stream_idle_timeout:          SourcedInt,
	heartbeat_interval:           SourcedInt,
	session_timeout:              SourcedInt,
	shutdown_grace:               SourcedInt,
	metrics_listen:               SourcedString,
	log_level:                    SourcedString,
}

AgentSettings :: struct {
	allocator:       mem.Allocator,
	broker:          SourcedString,
	token:           SourcedString,
	token_file:      SourcedString,
	maps:            [dynamic]SourcedString,
	service:         SourcedString,
	target:          SourcedString,
	tls_ca:          SourcedString,
	tls_server_name: SourcedString,
	insecure:        SourcedBool,
}
