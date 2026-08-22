package c_abi

import cl "../caller"
import "core:c"

@(export, link_name = "thirp_caller_create")
thirp_caller_create :: proc "c" (config: ^ThirpCallerConfig, out: ^^CCaller) -> c.int {
	context = abi_context()
	return caller_create(config, out)
}

@(export, link_name = "thirp_dial")
thirp_dial :: proc "c" (caller: ^CCaller, service_id: cstring, out: ^^cl.Conn) -> c.int {
	context = abi_context()
	return caller_dial(caller, service_id, out)
}

@(export, link_name = "thirp_dial_join_code")
thirp_dial_join_code :: proc "c" (
	caller: ^CCaller,
	namespace: cstring,
	join_code: cstring,
	out: ^^cl.Conn,
) -> c.int {
	context = abi_context()
	return caller_dial_join_code(caller, namespace, join_code, out)
}

@(export, link_name = "thirp_caller_destroy")
thirp_caller_destroy :: proc "c" (caller: ^CCaller) {
	context = abi_context()
	caller_destroy(caller)
}

@(export, link_name = "thirp_conn_read")
thirp_conn_read :: proc "c" (conn: ^cl.Conn, buf: rawptr, n: c.size_t, got: ^c.size_t) -> c.int {
	context = abi_context()
	return conn_read(conn, buf, n, got)
}

@(export, link_name = "thirp_conn_write")
thirp_conn_write :: proc "c" (conn: ^cl.Conn, buf: rawptr, n: c.size_t, put: ^c.size_t) -> c.int {
	context = abi_context()
	return conn_write(conn, buf, n, put)
}

@(export, link_name = "thirp_conn_close")
thirp_conn_close :: proc "c" (conn: ^cl.Conn) {
	context = abi_context()
	conn_close(conn)
}

@(export, link_name = "thirp_conn_destroy")
thirp_conn_destroy :: proc "c" (conn: ^cl.Conn) {
	context = abi_context()
	conn_destroy(conn)
}

caller_create :: proc(config: ^ThirpCallerConfig, out: ^^CCaller) -> c.int {
	if out == nil {
		return ERR_INVALID_ARGUMENT
	}
	out^ = nil
	cfg, cerr := caller_config_from_c(config)
	if cerr != 0 {
		return cerr
	}
	handle, aerr := new(CCaller)
	if aerr != .None {
		return ERR_OUT_OF_MEMORY
	}
	err := cl.caller_init(&handle.inner, cfg)
	if err != .None {
		free(handle)
		return caller_error_to_c(err)
	}
	out^ = handle
	return ERR_OK
}

caller_destroy :: proc(caller: ^CCaller) {
	if caller == nil {
		return
	}
	cl.caller_destroy(&caller.inner)
	free(caller)
}

caller_dial :: proc(caller: ^CCaller, service_id: cstring, out: ^^cl.Conn) -> c.int {
	if caller == nil || out == nil {
		return ERR_INVALID_ARGUMENT
	}
	out^ = nil
	id, ierr := service_id_from_cstr(service_id)
	if ierr != 0 {
		return ierr
	}
	conn, err := cl.dial(&caller.inner, id)
	if err != .None {
		return caller_error_to_c(err)
	}
	out^ = conn
	return ERR_OK
}

caller_dial_join_code :: proc(
	caller: ^CCaller,
	namespace: cstring,
	join_code: cstring,
	out: ^^cl.Conn,
) -> c.int {
	if caller == nil || out == nil {
		return ERR_INVALID_ARGUMENT
	}
	out^ = nil
	if namespace == nil || join_code == nil {
		return ERR_INVALID_ARGUMENT
	}
	conn, err := cl.dial_join_code(&caller.inner, cstr_str(namespace), cstr_str(join_code))
	if err != .None {
		return caller_error_to_c(err)
	}
	out^ = conn
	return ERR_OK
}

conn_read :: proc(conn: ^cl.Conn, buf: rawptr, n: c.size_t, got: ^c.size_t) -> c.int {
	if conn == nil {
		return ERR_INVALID_ARGUMENT
	}
	if n > 0 && buf == nil {
		return ERR_INVALID_ARGUMENT
	}
	slice: []u8
	if n > 0 {
		slice = ([^]u8)(buf)[:n]
	}
	rn, err := cl.conn_read(conn, slice)
	if got != nil {
		got^ = c.size_t(rn)
	}
	return conn_error_to_c(err)
}

conn_write :: proc(conn: ^cl.Conn, buf: rawptr, n: c.size_t, put: ^c.size_t) -> c.int {
	if conn == nil {
		return ERR_INVALID_ARGUMENT
	}
	if n > 0 && buf == nil {
		return ERR_INVALID_ARGUMENT
	}
	slice: []u8
	if n > 0 {
		slice = ([^]u8)(buf)[:n]
	}
	pn, err := cl.conn_write(conn, slice)
	if put != nil {
		put^ = c.size_t(pn)
	}
	return conn_error_to_c(err)
}

conn_close :: proc(conn: ^cl.Conn) {
	if conn == nil {
		return
	}
	cl.conn_close(conn)
}

conn_destroy :: proc(conn: ^cl.Conn) {
	if conn == nil {
		return
	}
	cl.conn_destroy(conn)
}
