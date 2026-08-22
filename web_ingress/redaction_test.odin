package web_ingress

import ag "../agent"
import log "../logging"
import trans "../transport"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

SECRET_TOKEN :: "redact-me-unique-token-wi4-9f3a"
SECRET_COOKIE :: "invite=redact-cookie-wi4-zz91"
SECRET_AUTH :: "Bearer redact-auth-wi4-qq17"
SECRET_PATH :: "/invite/redact-path-wi4-secret?tok=redact-query-wi4"
SECRET_BODY :: "redact-body-payload-wi4-aabb"

redaction_cap: ^log.Capture

redaction_sink :: proc(text: string) {
	if redaction_cap != nil {
		log.capture_sink(redaction_cap, text)
	}
}

@(test)
test_ingress_logs_omit_token_cookie_auth_path_and_body :: proc(t: ^testing.T) {
	cap: log.Capture
	cap.text = make([dynamic]u8)
	defer delete(cap.text)
	redaction_cap = &cap
	defer {redaction_cap = nil}
	logger: log.Logger
	log.logger_init(&logger, .Debug, redaction_sink)

	fx: TestBroker
	start_test_broker(t, &fx)
	defer stop_test_broker(&fx)

	origin: HttpOriginFixture
	origin_ep := start_http_origin(t, &origin)
	defer stop_http_origin(&origin)

	agent: ag.Agent
	run: AgentRunArg
	th := start_registered_agent(t, &fx, origin_ep, &agent, &run)
	defer stop_agent(&agent, th)

	cert_path, cert_ok := write_temp_pem("cert", INGRESS_TEST_CERT)
	testing.expect(t, cert_ok)
	defer remove_temp_pem(cert_path)
	key_path, key_ok := write_temp_pem("key", INGRESS_TEST_KEY)
	testing.expect(t, key_ok)
	defer remove_temp_pem(key_path)

	broker := broker_endpoint_string(t, &fx)
	defer delete(broker)

	server: IngressServer
	start_full_ingress_routes(
		t,
		broker,
		cert_path,
		key_path,
		&server,
		[]string{"ingress.test=demo/echo"},
		logger = &logger,
	)
	// Token is only in config for caller; overwrite displayed copy used by logs.
	server.config.token = SECRET_TOKEN
	defer stop_full_ingress(&server)

	ep, eerr := ingress_server_endpoint(&server)
	testing.expect_value(t, eerr, trans.TransportError.None)
	client := dial_ingress_tls(t, ep, cert_path, TEST_PUBLIC_HOST)
	defer trans.connection_destroy(client)

	extra := "Cookie: " + SECRET_COOKIE + "\r\nAuthorization: " + SECRET_AUTH + "\r\n"
	body := transmute([]u8)string(SECRET_BODY)
	testing.expect_value(
		t,
		write_http_request(client, "POST", SECRET_PATH, TEST_PUBLIC_HOST, body, extra_headers = extra),
		trans.TransportError.None,
	)
	head, resp, ok := read_http_message(client)
	defer delete(head)
	defer delete(resp)
	testing.expect(t, ok)

	sync.mutex_lock(&cap.mutex)
	got := strings.clone(string(cap.text[:]))
	sync.mutex_unlock(&cap.mutex)
	defer delete(got)

	testing.expect(t, strings.contains(got, "\"event\":\"route_selected\""))
	testing.expect(t, !strings.contains(got, SECRET_TOKEN))
	testing.expect(t, !strings.contains(got, SECRET_COOKIE))
	testing.expect(t, !strings.contains(got, SECRET_AUTH))
	testing.expect(t, !strings.contains(got, SECRET_PATH))
	testing.expect(t, !strings.contains(got, "redact-query-wi4"))
	testing.expect(t, !strings.contains(got, SECRET_BODY))
}
