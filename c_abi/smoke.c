#include "thirp.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int
dial_retry(ThirpCaller *caller, const char *service, ThirpConn **out)
{
	int i;
	int err;

	for (i = 0; i < 50; i++) {
		err = thirp_dial(caller, service, out);
		if (err == THIRP_OK) {
			return 0;
		}
		if (err != THIRP_SERVICE_NOT_FOUND) {
			fprintf(stderr, "thirp_dial: %d\n", err);
			return 1;
		}
		usleep(50000);
	}
	fprintf(stderr, "thirp_dial: timed out waiting for service\n");
	return 1;
}

int
main(int argc, char **argv)
{
	ThirpAgentConfig ac;
	ThirpCallerConfig cc;
	ThirpAgent *agent;
	ThirpCaller *caller;
	ThirpConn *conn;
	const char *payload;
	char buf[64];
	size_t put;
	size_t got;
	int err;

	if (argc != 6) {
		fprintf(stderr, "usage: %s BROKER HOST_TOKEN CALLER_TOKEN SERVICE TARGET\n", argv[0]);
		return 1;
	}

	memset(&ac, 0, sizeof(ac));
	ac.broker = argv[1];
	ac.token = argv[2];
	ac.insecure = 1;
	agent = NULL;
	err = thirp_agent_create(&ac, &agent);
	if (err != THIRP_OK) {
		fprintf(stderr, "thirp_agent_create: %d\n", err);
		return 1;
	}

	err = thirp_register_service(agent, argv[4], argv[5]);
	if (err != THIRP_OK) {
		fprintf(stderr, "thirp_register_service: %d\n", err);
		thirp_agent_destroy(agent);
		return 1;
	}

	memset(&cc, 0, sizeof(cc));
	cc.broker = argv[1];
	cc.token = argv[3];
	cc.insecure = 1;
	caller = NULL;
	err = thirp_caller_create(&cc, &caller);
	if (err != THIRP_OK) {
		fprintf(stderr, "thirp_caller_create: %d\n", err);
		thirp_agent_destroy(agent);
		return 1;
	}

	conn = NULL;
	if (dial_retry(caller, argv[4], &conn) != 0) {
		thirp_caller_destroy(caller);
		thirp_agent_destroy(agent);
		return 1;
	}

	payload = "hello";
	put = 0;
	err = thirp_conn_write(conn, payload, strlen(payload), &put);
	if (err != THIRP_OK || put != strlen(payload)) {
		fprintf(stderr, "thirp_conn_write: %d put=%zu\n", err, put);
		thirp_conn_destroy(conn);
		thirp_caller_destroy(caller);
		thirp_agent_destroy(agent);
		return 1;
	}

	got = 0;
	memset(buf, 0, sizeof(buf));
	err = thirp_conn_read(conn, buf, sizeof(buf), &got);
	if (err != THIRP_OK || got != strlen(payload) || memcmp(buf, payload, got) != 0) {
		fprintf(stderr, "thirp_conn_read: %d got=%zu buf=%.*s\n", err, got, (int)got, buf);
		thirp_conn_destroy(conn);
		thirp_caller_destroy(caller);
		thirp_agent_destroy(agent);
		return 1;
	}

	thirp_conn_destroy(conn);
	thirp_caller_destroy(caller);
	thirp_agent_destroy(agent);
	return 0;
}
