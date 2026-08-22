package protocol

ServiceId :: distinct string
StreamId :: distinct u64

Opcode :: enum u8 {
	Hello              = 1,
	HelloAck           = 2,
	Authenticate       = 3,
	AuthenticateOk     = 4,
	AuthenticateFailed = 5,
	Register           = 6,
	RegisterOk         = 7,
	RegisterFailed     = 8,
	Unregister         = 9,
	Connect            = 10,
	ConnectOk          = 11,
	ConnectFailed      = 12,
	Open               = 13,
	OpenOk             = 14,
	OpenFailed         = 15,
	Data               = 16,
	HalfClose          = 17,
	Close              = 18,
	Reset              = 19,
	Ping               = 20,
	Pong               = 21,
	Error              = 22,
	UnregisterOk       = 23,
	UnregisterFailed   = 24,
}

PeerRole :: enum u8 {
	Agent  = 1,
	Caller = 2,
}

FrameHeader :: struct {
	version:   u8,
	opcode:    Opcode,
	flags:     u16,
	length:    u32,
	stream_id: StreamId,
}

Frame :: struct {
	header:  FrameHeader,
	payload: []u8,
}

Hello :: struct {
	major:            u8,
	minor:            u8,
	role:             PeerRole,
	capability_bits:  u64,
	implementation:   string,
}

HelloAck :: struct {
	major:            u8,
	minor:            u8,
	capability_bits:  u64,
	implementation:   string,
}

Authenticate :: struct {
	token: []u8,
}

AuthenticateOk :: struct {
	principal_id: string,
}

Register :: struct {
	service_id: ServiceId,
}

RegisterOk :: struct {
	service_id: ServiceId,
}

Unregister :: struct {
	service_id: ServiceId,
}

UnregisterOk :: struct {
	service_id: ServiceId,
}

Connect :: struct {
	service_id: ServiceId,
}

Open :: struct {
	service_id: ServiceId,
}

Ping :: struct {
	nonce: u64,
}

Pong :: struct {
	nonce: u64,
}

WireFailure :: struct {
	code:        u16,
	diagnostic:  string,
}

FrameDecoder :: struct {
	buf:         [dynamic]u8,
	max_payload: u32,
	failed:      bool,
	fail_err:    ProtocolError,
}
