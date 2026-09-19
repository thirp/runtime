package transport

import "core:c"
import win "core:sys/windows"

// crypt32 FFI so Windows dataplane builds on Odin months before Cert* landed in core:sys/windows.
HCERTSTORE :: distinct rawptr
CERT_CONTEXT :: struct {
	dwCertEncodingType: u32,
	pbCertEncoded:      [^]u8,
	cbCertEncoded:      u32,
	pCertInfo:          rawptr,
	hCertStore:         HCERTSTORE,
}

foreign import crypt32 "system:crypt32"

foreign crypt32 {
	CertOpenSystemStoreW :: proc(hProv: rawptr, szSubsystemProtocol: win.wstring) -> HCERTSTORE ---
	CertCloseStore :: proc(hCertStore: HCERTSTORE, dwFlags: u32) -> b32 ---
	CertEnumCertificatesInStore :: proc(hCertStore: HCERTSTORE, pPrev: ^CERT_CONTEXT) -> ^CERT_CONTEXT ---
}

tls_client_context_load_system_ca :: proc(ctx: SSL_CTX) -> bool {
	store_handle := CertOpenSystemStoreW(nil, win.L("ROOT"))
	if store_handle == nil {
		return false
	}
	defer CertCloseStore(store_handle, 0)

	x509_store := SSL_CTX_get_cert_store(ctx)
	if x509_store == nil {
		return false
	}

	cert_context: ^CERT_CONTEXT
	for {
		cert_context = CertEnumCertificatesInStore(store_handle, cert_context)
		if cert_context == nil {
			break
		}
		if cert_context.pbCertEncoded == nil || cert_context.cbCertEncoded == 0 {
			continue
		}
		cert_data: ^u8 = &cert_context.pbCertEncoded[0]
		x509 := d2i_X509(nil, &cert_data, c.long(cert_context.cbCertEncoded))
		if x509 != nil {
			_ = X509_STORE_add_cert(x509_store, x509)
			X509_free(x509)
		}
	}
	return true
}
