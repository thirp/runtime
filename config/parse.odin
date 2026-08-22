package config

import "core:os"
import "core:strings"

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

is_section_line :: proc(line: string) -> bool {
	return len(line) >= 2 && line[0] == '[' && line[len(line) - 1] == ']'
}

ini_document_init :: proc(doc: ^IniDocument, allocator := context.allocator) -> ConfigError {
	doc^ = {}
	doc.allocator = allocator
	doc.entries = make([dynamic]IniEntry, allocator)
	return .None
}

ini_document_destroy :: proc(doc: ^IniDocument) {
	if doc == nil {
		return
	}
	for entry in doc.entries {
		delete(entry.key, doc.allocator)
		delete(entry.value, doc.allocator)
	}
	delete(doc.entries)
	doc^ = {}
}

parse_ini_bytes :: proc(data: []u8, allocator := context.allocator) -> (doc: IniDocument, err: ConfigError) {
	if len(data) > MAX_CONFIG_FILE_LEN {
		return {}, .TooLarge
	}
	if ini_document_init(&doc, allocator) != .None {
		return {}, .OutOfMemory
	}
	text := string(data)
	line_start := 0
	line_no := 1
	for i := 0; i <= len(text); i += 1 {
		if i < len(text) && text[i] != '\n' {
			continue
		}
		line := text[line_start:i]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		line_start = i + 1
		trimmed := trim_ascii_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' || is_section_line(trimmed) {
			if i < len(text) {
				line_no += 1
			}
			continue
		}
		eq := strings.index_byte(trimmed, '=')
		if eq <= 0 || eq >= len(trimmed) - 1 {
			ini_document_destroy(&doc)
			return {}, .InvalidLine
		}
		key := trim_ascii_space(trimmed[:eq])
		value := trim_ascii_space(trimmed[eq + 1:])
		if len(key) == 0 || len(value) == 0 {
			ini_document_destroy(&doc)
			return {}, .InvalidLine
		}
		owned_key, kerr := strings.clone(key, allocator)
		if kerr != .None {
			ini_document_destroy(&doc)
			return {}, .OutOfMemory
		}
		owned_value, verr := strings.clone(value, allocator)
		if verr != .None {
			delete(owned_key, allocator)
			ini_document_destroy(&doc)
			return {}, .OutOfMemory
		}
		_, aerr := append(&doc.entries, IniEntry{key = owned_key, value = owned_value, line = line_no})
		if aerr != .None {
			delete(owned_key, allocator)
			delete(owned_value, allocator)
			ini_document_destroy(&doc)
			return {}, .OutOfMemory
		}
		if i < len(text) {
			line_no += 1
		}
	}
	if len(doc.entries) == 0 {
		ini_document_destroy(&doc)
		return {}, .Empty
	}
	return doc, .None
}

parse_ini_file :: proc(path: string, allocator := context.allocator) -> (doc: IniDocument, err: ConfigError) {
	fi, serr := os.stat(path, allocator)
	if serr != nil {
		return {}, .Io
	}
	size := fi.size
	os.file_info_delete(fi, allocator)
	if size < 0 {
		return {}, .Io
	}
	if size > i64(MAX_CONFIG_FILE_LEN) {
		return {}, .TooLarge
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return {}, .Io
	}
	defer delete(data, allocator)
	return parse_ini_bytes(data, allocator)
}
