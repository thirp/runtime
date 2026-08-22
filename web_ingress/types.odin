package web_ingress

import cfg "../config"
import cl "../caller"
import log "../logging"
import proto "../protocol"
import trans "../transport"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

PublicHost :: distinct string

IngressMode :: enum {
	TerminateHttp,
	TlsPassthrough,
}

IngressRoute :: struct {
	public_host: PublicHost,
	service_id:  proto.ServiceId,
	mode:        IngressMode,
}

IngressLimits :: struct {
	max_connections:        int,
	max_connections_per_ip: int,
	max_client_hello_bytes: int,
	client_hello_timeout:   time.Duration,
	broker_dial_timeout:    time.Duration,
	idle_timeout:           time.Duration,
}

IngressConfig :: struct {
	allocator:       mem.Allocator,
	listen:          string,
	broker:          string,
	token:           string,
	token_file:      string,
	routes:          []IngressRoute,
	tls_cert:        string,
	tls_key:         string,
	tls_ca:          string,
	tls_server_name: string,
	insecure:        bool,
	insecure_broker: bool,
	limits:          IngressLimits,
	shutdown_grace:  time.Duration,
	metrics_listen:  string,
	log_level:       log.LogLevel,
}

IngressSettings :: struct {
	allocator:              mem.Allocator,
	listen:                 cfg.SourcedString,
	broker:                 cfg.SourcedString,
	token:                  cfg.SourcedString,
	token_file:             cfg.SourcedString,
	routes:                 [dynamic]cfg.SourcedString,
	tls_cert:               cfg.SourcedString,
	tls_key:                cfg.SourcedString,
	tls_ca:                 cfg.SourcedString,
	tls_server_name:        cfg.SourcedString,
	insecure:               cfg.SourcedBool,
	insecure_broker:        cfg.SourcedBool,
	max_connections:        cfg.SourcedInt,
	max_connections_per_ip: cfg.SourcedInt,
	max_client_hello_bytes: cfg.SourcedInt,
	client_hello_timeout:   cfg.SourcedInt,
	broker_dial_timeout:    cfg.SourcedInt,
	idle_timeout:           cfg.SourcedInt,
	shutdown_grace:         cfg.SourcedInt,
	metrics_listen:         cfg.SourcedString,
	log_level:              cfg.SourcedString,
}

ServiceDialer :: struct {
	ctx:  rawptr,
	dial: proc(ctx: rawptr, service_id: proto.ServiceId) -> (^cl.Conn, cl.CallerError),
}

IngressIpKey :: struct {
	kind:  u8,
	bytes: [16]u8,
}

IngressSlotResult :: enum {
	Ok,
	Connections,
	ConnectionsPerIp,
}

IngressLiveConn :: struct {
	id:      u64,
	browser: ^trans.Connection,
	stream:  ^cl.Conn,
	routed:  bool,
}

IngressServer :: struct {
	allocator:         mem.Allocator,
	config:            IngressConfig,
	caller:            cl.Caller,
	caller_ok:         bool,
	want_caller:       bool,
	dialer:            ServiceDialer,
	listener:          trans.Listener,
	tls_ctx:           ^trans.TlsServerContext,
	logger:            ^log.Logger,
	stop:              bool,
	listening:         bool,
	draining:          bool,
	serve_thread:      ^thread.Thread,
	retry_thread:      ^thread.Thread,
	retry_stop:        bool,
	conn_mutex:        sync.Mutex,
	conn_cond:         sync.Cond,
	active_conns:      int,
	slot_count:        int,
	ip_conns:          map[IngressIpKey]int,
	limits_mutex:      sync.Mutex,
	next_conn_id:      u64,
	lives:             [dynamic]^IngressLiveConn,
	lives_mutex:       sync.Mutex,
	metrics:           IngressMetrics,
	metrics_listener:  trans.Listener,
	metrics_listening: bool,
	metrics_stop:      bool,
	metrics_thread:    ^thread.Thread,
}
