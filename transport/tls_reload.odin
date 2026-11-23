package transport

import "core:c"
import "core:mem"
import "core:strings"

TLS_RELOAD_MAX_PEM_BYTES :: 1024 * 1024

@(private)
tls_no_pem_password :: proc "c" (_: [^]c.char, _, _: c.int, _: rawptr) -> c.int {
	return -1
}

@(private)
tls_read_pem_file :: proc(path: string, allocator: mem.Allocator) -> []byte {
	file, ok := open_regular_input(path)
	if !ok {
		return nil
	}
	defer close_regular_input(file)
	if file.size <= 0 || file.size > TLS_RELOAD_MAX_PEM_BYTES {
		return nil
	}
	bytes, err := make([]byte, int(file.size), allocator)
	if err != .None {
		return nil
	}
	if !read_regular_input(file, bytes) {
		OPENSSL_cleanse(raw_data(bytes), c.size_t(len(bytes)))
		delete(bytes, allocator)
		return nil
	}
	return bytes
}

@(private)
tls_load_reload_pem :: proc(ctx: SSL_CTX, cert_path, key_path: string, allocator: mem.Allocator) -> bool {
	cert := tls_read_pem_file(cert_path, allocator)
	if cert == nil {
		return false
	}
	defer delete(cert, allocator)
	if !tls_load_cert_chain(ctx, cert) {
		return false
	}

	bytes := tls_read_pem_file(key_path, allocator)
	if bytes == nil {
		return false
	}
	defer delete(bytes, allocator)
	defer OPENSSL_cleanse(raw_data(bytes), c.size_t(len(bytes)))
	bio := BIO_new_mem_buf(raw_data(bytes), c.int(len(bytes)))
	if bio == nil {
		return false
	}
	defer BIO_free(bio)
	key := PEM_read_bio_PrivateKey(bio, nil, tls_no_pem_password, nil)
	if key == nil {
		return false
	}
	defer EVP_PKEY_free(key)
	// The context's certificate/key match only compares the public components.
	check := EVP_PKEY_CTX_new(key, nil)
	if check == nil {
		return false
	}
	defer EVP_PKEY_CTX_free(check)
	return EVP_PKEY_pairwise_check(check) == 1 && SSL_CTX_use_PrivateKey(ctx, key) == 1
}

@(private)
tls_load_cert_chain :: proc(ctx: SSL_CTX, bytes: []byte) -> bool {
	count := tls_count_cert_blocks(string(bytes))
	if count == 0 {
		return false
	}
	bio := BIO_new_mem_buf(raw_data(bytes), c.int(len(bytes)))
	if bio == nil {
		return false
	}
	defer BIO_free(bio)
	leaf := tls_read_pem_cert(bio)
	if leaf == nil {
		return false
	}
	defer X509_free(leaf)
	if X509_check_purpose(leaf, X509_PURPOSE_SSL_SERVER, 0) != 1 || SSL_CTX_use_certificate(ctx, leaf) != 1 {
		return false
	}
	for _ in 1..<count {
		cert := tls_read_pem_cert(bio)
		// SSL_CTX_add0_chain_cert transfers ownership on success.
		if cert == nil || X509_check_ca(cert) == 0 ||
		   SSL_CTX_ctrl(ctx, SSL_CTRL_CHAIN_CERT, 0, rawptr(cert)) != 1 {
			X509_free(cert)
			return false
		}
	}
	return count == 1 || tls_verify_supplied_chain(ctx, leaf, c.int(count))
}

@(private)
tls_read_pem_cert :: proc(bio: BIO) -> X509 {
	name, header: cstring
	der: ^u8
	size: c.long
	if PEM_read_bio(bio, &name, &header, &der, &size) != 1 {
		return nil
	}
	defer CRYPTO_free(rawptr(name), nil, 0)
	defer CRYPTO_free(rawptr(header), nil, 0)
	defer CRYPTO_free(der, nil, 0)
	// Certificate records on the reload path must be unencrypted.
	if string(header) != "" || size <= 0 {
		return nil
	}

	cursor := der
	cert: X509
	switch string(name) {
	case "CERTIFICATE", "X509 CERTIFICATE":
		cert = d2i_X509(nil, &cursor, size)
	case "TRUSTED CERTIFICATE":
		cert = d2i_X509_AUX(nil, &cursor, size)
	}
	if cert == nil || cursor != mem.ptr_offset(der, int(size)) || !tls_reload_cert_fields_valid(cert) {
		X509_free(cert)
		return nil
	}
	return cert
}

@(private)
tls_reload_cert_fields_valid :: proc(cert: X509) -> bool {
	// The last supplied CA can be the temporary anchor, so check its two
	// signature algorithm identifiers even when its issuer is absent.
	algorithm: X509_ALGOR
	X509_get0_signature(nil, &algorithm, cert)
	if X509_ALGOR_cmp(algorithm, X509_get0_tbs_sigalg(cert)) != 0 {
		return false
	}

	not_before := X509_get0_notBefore(cert)
	not_after := X509_get0_notAfter(cert)
	// Zero from X509_cmp_current_time indicates invalid X.509 time encoding.
	// Clients check the interval against the current time.
	return X509_cmp_current_time(not_before) != 0 && X509_cmp_current_time(not_after) != 0 &&
	       ASN1_TIME_compare(not_after, not_before) >= 0
}

@(private)
tls_verify_supplied_chain :: proc(ctx: SSL_CTX, leaf: X509, count: c.int) -> bool {
	supplied: X509_STACK
	if SSL_CTX_ctrl(ctx, SSL_CTRL_GET_CHAIN_CERTS, 0, &supplied) != 1 {
		return false
	}
	// Use the last supplied CA as a temporary anchor. This checks the local
	// chain without requiring its root or a client trust store. Each certificate's
	// time fields have already been parsed, and clients enforce validity periods.
	anchor := OPENSSL_sk_value(supplied, count - 2)
	store := X509_STORE_new()
	if store == nil {
		return false
	}
	defer X509_STORE_free(store)
	if X509_STORE_add_cert(store, anchor) != 1 ||
	   X509_STORE_set_flags(store, X509_V_FLAG_PARTIAL_CHAIN | X509_V_FLAG_NO_CHECK_TIME) != 1 {
		return false
	}
	verify := X509_STORE_CTX_new()
	if verify == nil {
		return false
	}
	defer X509_STORE_CTX_free(verify)
	if X509_STORE_CTX_init(verify, store, leaf, supplied) != 1 ||
	   X509_STORE_CTX_set_purpose(verify, X509_PURPOSE_SSL_SERVER) != 1 ||
	   X509_verify_cert(verify) != 1 {
		return false
	}
	// OpenSSL can reorder or skip candidates while building a path. Require
	// the verified path to match the sequence the broker will send.
	path := X509_STORE_CTX_get0_chain(verify)
	if OPENSSL_sk_num(path) != count {
		return false
	}
	for i in 1..<count {
		if X509_cmp(OPENSSL_sk_value(path, i), OPENSSL_sk_value(supplied, i - 1)) != 0 {
			return false
		}
	}
	return true
}

@(private)
tls_count_cert_blocks :: proc(pem: string) -> int {
	// OpenSSL can search ahead for labels and discard bytes in the PEM body.
	// Check each block's framing and base64 before handing it to the decoder.
	rest := pem
	expected_end := ""
	count, body_chars, padding := 0, 0, 0
	for line in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(line, " \t")
		if expected_end != "" {
			if line == expected_end {
				if body_chars == 0 || (body_chars + padding) % 4 != 0 {
					return 0
				}
				count += 1
				expected_end = ""
				body_chars, padding = 0, 0
				continue
			}
			for ch in transmute([]byte)line {
				switch ch {
				case ' ', '\t':
				case '=':
					padding += 1
					if padding > 2 {
						return 0
					}
				case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/':
					if padding != 0 {
						return 0
					}
					body_chars += 1
				case:
					return 0
				}
			}
			continue
		}
		switch line {
		case "":
		case "-----BEGIN CERTIFICATE-----":
			expected_end = "-----END CERTIFICATE-----"
		case "-----BEGIN X509 CERTIFICATE-----":
			expected_end = "-----END X509 CERTIFICATE-----"
		case "-----BEGIN TRUSTED CERTIFICATE-----":
			if count != 0 {
				return 0
			}
			expected_end = "-----END TRUSTED CERTIFICATE-----"
		case:
			return 0
		}
	}
	return count if expected_end == "" else 0
}
