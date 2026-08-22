/*
 * SDK C example: Caller that dials a join code and echoes a payload.
 * The join code identifies a service. AUTH still uses the token; the code
 * is not a credential.
 *
 * Build against an extracted SDK only:
 *   cc -o echo_client echo_client.c \
 *      -I /opt/thirp-runtime-sdk-<VERSION>/c/include \
 *      -L /opt/thirp-runtime-sdk-<VERSION>/c/lib/linux-x86_64 \
 *      -lthirp -Wl,-rpath,/opt/thirp-runtime-sdk-<VERSION>/c/lib/linux-x86_64
 */

#include "thirp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int
read_token_file(const char *path, char *buf, size_t cap)
{
	FILE *f;
	size_t n;
	char *nl;

	f = fopen(path, "r");
	if (f == NULL) {
		return -1;
	}
	n = fread(buf, 1, cap - 1, f);
	fclose(f);
	if (n == 0) {
		return -1;
	}
	buf[n] = '\0';
	nl = strchr(buf, '\n');
	if (nl != NULL) {
		*nl = '\0';
	}
	if (buf[0] == '\0') {
		return -1;
	}
	return 0;
}

static int
dial_retry(ThirpCaller *caller, const char *namespace, const char *join_code, ThirpConn **out)
{
	int i;
	int err;

	for (i = 0; i < 50; i++) {
		err = thirp_dial_join_code(caller, namespace, join_code, out);
		if (err == THIRP_OK) {
			return 0;
		}
		if (err != THIRP_SERVICE_NOT_FOUND) {
			fprintf(stderr, "thirp_dial_join_code: %d\n", err);
			return 1;
		}
		usleep(50000);
	}
	fprintf(stderr, "thirp_dial_join_code: timed out waiting for service\n");
	return 1;
}

static void
usage(const char *argv0)
{
	fprintf(stderr,
	    "usage: %s --broker HOST:PORT --token-file PATH --join-code CODE\n"
	    "       [--namespace NAME] [--payload TEXT] [--tls-ca PATH | --insecure]\n",
	    argv0);
}

int
main(int argc, char **argv)
{
	ThirpCallerConfig cc;
	ThirpCaller *caller;
	ThirpConn *conn;
	const char *broker = NULL;
	const char *token_file = NULL;
	const char *namespace = "sdk-demo";
	const char *join_code = NULL;
	const char *payload = "hello";
	const char *tls_ca = NULL;
	int insecure = 0;
	char token[4096];
	char buf[64];
	size_t put;
	size_t got;
	int err;
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--insecure") == 0) {
			insecure = 1;
		} else if (strcmp(argv[i], "--broker") == 0 && i + 1 < argc) {
			broker = argv[++i];
		} else if (strcmp(argv[i], "--token-file") == 0 && i + 1 < argc) {
			token_file = argv[++i];
		} else if (strcmp(argv[i], "--namespace") == 0 && i + 1 < argc) {
			namespace = argv[++i];
		} else if (strcmp(argv[i], "--join-code") == 0 && i + 1 < argc) {
			join_code = argv[++i];
		} else if (strcmp(argv[i], "--payload") == 0 && i + 1 < argc) {
			payload = argv[++i];
		} else if (strcmp(argv[i], "--tls-ca") == 0 && i + 1 < argc) {
			tls_ca = argv[++i];
		} else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			usage(argv[0]);
			return 0;
		} else {
			fprintf(stderr, "unknown flag: %s\n", argv[i]);
			usage(argv[0]);
			return 1;
		}
	}

	if (insecure && tls_ca != NULL) {
		fprintf(stderr, "--insecure cannot be combined with --tls-ca\n");
		return 1;
	}
	if (broker == NULL || token_file == NULL || join_code == NULL) {
		fprintf(stderr, "--broker, --token-file, and --join-code are required\n");
		usage(argv[0]);
		return 1;
	}
	if (read_token_file(token_file, token, sizeof(token)) != 0) {
		fprintf(stderr, "failed to read --token-file\n");
		return 1;
	}

	memset(&cc, 0, sizeof(cc));
	cc.broker = broker;
	cc.token = token;
	cc.insecure = insecure;
	cc.tls_ca = tls_ca;

	caller = NULL;
	err = thirp_caller_create(&cc, &caller);
	if (err != THIRP_OK) {
		fprintf(stderr, "thirp_caller_create: %d\n", err);
		return 1;
	}

	conn = NULL;
	if (dial_retry(caller, namespace, join_code, &conn) != 0) {
		thirp_caller_destroy(caller);
		return 1;
	}

	put = 0;
	err = thirp_conn_write(conn, payload, strlen(payload), &put);
	if (err != THIRP_OK || put != strlen(payload)) {
		fprintf(stderr, "thirp_conn_write: %d put=%zu\n", err, put);
		thirp_conn_destroy(conn);
		thirp_caller_destroy(caller);
		return 1;
	}

	got = 0;
	memset(buf, 0, sizeof(buf));
	err = thirp_conn_read(conn, buf, sizeof(buf), &got);
	if (err != THIRP_OK || got != strlen(payload) || memcmp(buf, payload, got) != 0) {
		fprintf(stderr, "thirp_conn_read: %d got=%zu buf=%.*s\n", err, got, (int)got, buf);
		thirp_conn_destroy(conn);
		thirp_caller_destroy(caller);
		return 1;
	}

	thirp_conn_close(conn);
	thirp_conn_destroy(conn);
	thirp_caller_destroy(caller);
	printf("ok\n");
	return 0;
}
