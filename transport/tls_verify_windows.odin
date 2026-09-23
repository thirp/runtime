package transport

import "core:c"
import win "core:sys/windows"

tls_client_context_load_system_ca :: proc(ctx: SSL_CTX) -> bool {
	store_handle := win.CertOpenSystemStoreW(nil, win.L("ROOT"))
	if store_handle == nil {
		return false
	}
	defer win.CertCloseStore(store_handle, 0)

	x509_store := SSL_CTX_get_cert_store(ctx)
	if x509_store == nil {
		return false
	}

	cert_context: ^win.CERT_CONTEXT
	for {
		cert_context = win.CertEnumCertificatesInStore(store_handle, cert_context)
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
