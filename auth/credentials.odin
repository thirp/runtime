package auth

import "core:os"
import "core:strings"
import "core:time"

is_ascii_space :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

trim_ascii_space :: proc(s: string) -> string {
	start := 0
	end := len(s)
	for start < end && is_ascii_space(s[start]) {
		start += 1
	}
	for end > start && is_ascii_space(s[end - 1]) {
		end -= 1
	}
	return s[start:end]
}

check_label :: proc(value: string) -> bool {
	if len(value) == 0 {
		return true
	}
	if len(value) > MAX_PRINCIPAL_LEN {
		return false
	}
	for i in 0 ..< len(value) {
		b := value[i]
		switch b {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '/', '.':
			continue
		case:
			return false
		}
	}
	return true
}

parse_token_capabilities :: proc(value: string) -> (caps: TokenCapabilities, ok: bool) {
	if len(value) == 0 {
		return {}, false
	}
	start := 0
	for i := 0; i <= len(value); i += 1 {
		if i < len(value) && value[i] != ',' {
			continue
		}
		part := trim_ascii_space(value[start:i])
		start = i + 1
		if len(part) == 0 {
			return {}, false
		}
		switch part {
		case "register":
			caps += {.RegisterService}
		case "connect":
			caps += {.ConnectService}
		case:
			return {}, false
		}
	}
	return caps, true
}

parse_credential_line :: proc(line: string) -> (spec: CredentialSpec, skip: bool, err: AuthError) {
	trimmed := trim_ascii_space(line)
	if len(trimmed) == 0 || trimmed[0] == '#' {
		return {}, true, .None
	}
	eq := strings.index_byte(trimmed, '=')
	if eq <= 0 || eq >= len(trimmed) - 1 {
		return {}, false, .InvalidToken
	}
	spec.token = trimmed[:eq]
	rest := trimmed[eq + 1:]
	semi := strings.index_byte(rest, ';')
	ident := rest
	fields := ""
	if semi >= 0 {
		ident = rest[:semi]
		fields = rest[semi + 1:]
	}
	ident = trim_ascii_space(ident)
	colon := strings.index_byte(ident, ':')
	if colon < 0 {
		if len(ident) == 0 {
			return {}, false, .InvalidPrincipal
		}
		spec.principal_id = ident
	} else {
		if colon == 0 || colon >= len(ident) - 1 {
			return {}, false, .InvalidPrincipal
		}
		spec.principal_id = ident[:colon]
		spec.organization = ident[colon + 1:]
	}
	if len(fields) == 0 {
		return spec, false, .None
	}
	seen_caps := false
	seen_label := false
	seen_expires := false
	start := 0
	for i := 0; i <= len(fields); i += 1 {
		if i < len(fields) && fields[i] != ';' {
			continue
		}
		part := trim_ascii_space(fields[start:i])
		start = i + 1
		if len(part) == 0 {
			return {}, false, .InvalidToken
		}
		peq := strings.index_byte(part, '=')
		if peq <= 0 || peq >= len(part) - 1 {
			return {}, false, .InvalidToken
		}
		key := trim_ascii_space(part[:peq])
		value := trim_ascii_space(part[peq + 1:])
		switch key {
		case "capabilities":
			if seen_caps {
				return {}, false, .InvalidToken
			}
			seen_caps = true
			caps, cok := parse_token_capabilities(value)
			if !cok {
				return {}, false, .InvalidToken
			}
			spec.capabilities = caps
		case "label":
			if seen_label {
				return {}, false, .InvalidToken
			}
			seen_label = true
			if !check_label(value) {
				return {}, false, .InvalidPrincipal
			}
			spec.label = value
		case "expires":
			if seen_expires {
				return {}, false, .InvalidToken
			}
			seen_expires = true
			ts, n := time.rfc3339_to_time_utc(value)
			if n == 0 || n != len(value) {
				return {}, false, .InvalidToken
			}
			spec.expires_at = ts
		case:
			return {}, false, .InvalidToken
		}
	}
	return spec, false, .None
}

credential_spec_clone :: proc(src: CredentialSpec, allocator := context.allocator) -> (CredentialSpec, AuthError) {
	out := CredentialSpec {
		capabilities = src.capabilities,
		expires_at   = src.expires_at,
	}
	tok, terr := strings.clone(src.token, allocator)
	if terr != .None {
		return {}, .OutOfMemory
	}
	out.token = tok
	pid, perr := strings.clone(src.principal_id, allocator)
	if perr != .None {
		delete(out.token, allocator)
		return {}, .OutOfMemory
	}
	out.principal_id = pid
	if len(src.organization) > 0 {
		org, oerr := strings.clone(src.organization, allocator)
		if oerr != .None {
			delete(out.token, allocator)
			delete(out.principal_id, allocator)
			return {}, .OutOfMemory
		}
		out.organization = org
	}
	if len(src.label) > 0 {
		label, lerr := strings.clone(src.label, allocator)
		if lerr != .None {
			delete(out.token, allocator)
			delete(out.principal_id, allocator)
			delete(out.organization, allocator)
			return {}, .OutOfMemory
		}
		out.label = label
	}
	return out, .None
}

credential_spec_destroy :: proc(spec: CredentialSpec, allocator := context.allocator) {
	delete(spec.token, allocator)
	delete(spec.principal_id, allocator)
	delete(spec.organization, allocator)
	delete(spec.label, allocator)
}

credential_specs_destroy :: proc(specs: [dynamic]CredentialSpec) {
	for spec in specs {
		credential_spec_destroy(spec, specs.allocator)
	}
	delete(specs)
}

file_group_or_world_readable :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.allocator)
	if err != nil {
		return false
	}
	defer os.file_info_delete(fi, context.allocator)
	return .Read_Group in fi.mode ||
		.Write_Group in fi.mode ||
		.Execute_Group in fi.mode ||
		.Read_Other in fi.mode ||
		.Write_Other in fi.mode ||
		.Execute_Other in fi.mode
}

read_secret_file :: proc(path: string, allocator := context.allocator) -> (token: string, err: AuthError) {
	fi, serr := os.stat(path, allocator)
	if serr != nil {
		return "", .InvalidToken
	}
	size := fi.size
	os.file_info_delete(fi, allocator)
	if size <= 0 || size > i64(MAX_SECRET_FILE_LEN) {
		return "", .InvalidToken
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return "", .InvalidToken
	}
	defer delete(data, allocator)
	body := trim_ascii_space(string(data))
	if len(body) == 0 || len(body) > MAX_TOKEN_LEN {
		return "", .InvalidToken
	}
	for i in 0 ..< len(body) {
		if body[i] == '\n' || body[i] == '\r' {
			return "", .InvalidToken
		}
	}
	owned, cerr := strings.clone(body, allocator)
	if cerr != .None {
		return "", .OutOfMemory
	}
	return owned, .None
}

load_credential_file :: proc(path: string, allocator := context.allocator) -> (specs: [dynamic]CredentialSpec, err: AuthError) {
	fi, serr := os.stat(path, allocator)
	if serr != nil {
		return nil, .InvalidToken
	}
	size := fi.size
	os.file_info_delete(fi, allocator)
	if size <= 0 || size > i64(MAX_CREDENTIAL_FILE_LEN) {
		return nil, .InvalidToken
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return nil, .InvalidToken
	}
	defer delete(data, allocator)
	specs = make([dynamic]CredentialSpec, allocator)
	text := string(data)
	line_start := 0
	for i := 0; i <= len(text); i += 1 {
		if i < len(text) && text[i] != '\n' {
			continue
		}
		line := text[line_start:i]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		line_start = i + 1
		spec, skip, perr := parse_credential_line(line)
		if perr != .None {
			credential_specs_destroy(specs)
			return nil, perr
		}
		if skip {
			continue
		}
		owned, cerr := credential_spec_clone(spec, allocator)
		if cerr != .None {
			credential_specs_destroy(specs)
			return nil, cerr
		}
		_, aerr := append(&specs, owned)
		if aerr != .None {
			credential_spec_destroy(owned, allocator)
			credential_specs_destroy(specs)
			return nil, .OutOfMemory
		}
	}
	if len(specs) == 0 {
		credential_specs_destroy(specs)
		return nil, .InvalidToken
	}
	return specs, .None
}
