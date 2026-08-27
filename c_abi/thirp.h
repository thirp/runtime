#ifndef THIRP_H
#define THIRP_H

/*
 * C ABI for the Thirp Runtime agent and caller libraries.
 * Opaque handles; UTF-8 NUL-terminated strings; integer error codes.
 * Do not depend on Odin types, allocators, or context.
 *
 * thirp_conn_read and thirp_conn_write may block. Language bindings
 * that cannot block the main thread must call them from a worker thread.
 *
 * Programs branch on the integer error code, not on message text.
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Project version, not the wire protocol version. See COMPATIBILITY.md. */
#define THIRP_VERSION_STRING "0.16.1"

#ifndef THIRP_API
#  if defined(_WIN32)
#    if defined(THIRP_BUILD)
#      define THIRP_API __declspec(dllexport)
#    else
#      define THIRP_API __declspec(dllimport)
#    endif
#  else
#    define THIRP_API
#  endif
#endif

/* WireError (PROTOCOL.md §6). 0 is success. */
#define THIRP_OK                        0
#define THIRP_PROTOCOL_ERROR            1
#define THIRP_UNSUPPORTED_VERSION       2
#define THIRP_AUTHENTICATION_FAILED     3
#define THIRP_UNAUTHORIZED              4
#define THIRP_INVALID_SERVICE_ID        5
#define THIRP_SERVICE_NOT_FOUND         6
#define THIRP_SERVICE_ALREADY_REGISTERED 7
#define THIRP_AGENT_UNAVAILABLE         8
#define THIRP_LOCAL_SERVICE_UNAVAILABLE 9
#define THIRP_QUOTA_EXCEEDED            10
#define THIRP_RATE_LIMITED              11
#define THIRP_STREAM_NOT_FOUND          12
#define THIRP_STREAM_ALREADY_EXISTS     13
#define THIRP_FRAME_TOO_LARGE           14
#define THIRP_TIMEOUT                   15
#define THIRP_BROKER_DRAINING           16
#define THIRP_INTERNAL_ERROR            17

/* Local overlay; does not collide with wire codes 0–17. */
#define THIRP_ERR_INVALID_ARGUMENT      100
#define THIRP_ERR_OUT_OF_MEMORY         101
#define THIRP_ERR_NOT_CONNECTED         102
#define THIRP_ERR_STOPPED               103
#define THIRP_ERR_CLOSED                104
#define THIRP_ERR_RESET                 105
#define THIRP_ERR_TRANSPORT             106

typedef struct ThirpAgent ThirpAgent;
typedef struct ThirpCaller ThirpCaller;
typedef struct ThirpConn ThirpConn;

typedef struct ThirpAgentConfig {
	const char *broker;           /* "host:port" */
	const char *token;
	int         insecure;         /* nonzero = plaintext */
	const char *tls_ca;           /* NULL/empty = system CA */
	const char *tls_server_name;  /* NULL/empty = host from broker */
	const char *implementation;   /* NULL/empty = agent package default */
} ThirpAgentConfig;

typedef struct ThirpCallerConfig {
	const char *broker;
	const char *token;
	int         insecure;
	const char *tls_ca;
	const char *tls_server_name;
	const char *implementation;
} ThirpCallerConfig;

typedef struct ThirpHosting {
	char service_id[129]; /* MAX_SERVICE_ID_LEN + NUL */
	char join_code[9];    /* 8 + NUL */
} ThirpHosting;

THIRP_API int  thirp_agent_create(const ThirpAgentConfig *config, ThirpAgent **out);
THIRP_API int  thirp_register_service(ThirpAgent *agent, const char *service_id, const char *target);
THIRP_API int  thirp_unregister_service(ThirpAgent *agent, const char *service_id);
THIRP_API int  thirp_host_ephemeral(ThirpAgent *agent, const char *namespace, const char *target, ThirpHosting *out);
THIRP_API void thirp_agent_stop(ThirpAgent *agent);
THIRP_API void thirp_agent_destroy(ThirpAgent *agent);

THIRP_API int  thirp_caller_create(const ThirpCallerConfig *config, ThirpCaller **out);
THIRP_API int  thirp_dial(ThirpCaller *caller, const char *service_id, ThirpConn **out);
THIRP_API int  thirp_dial_join_code(ThirpCaller *caller, const char *namespace, const char *join_code, ThirpConn **out);
THIRP_API void thirp_caller_destroy(ThirpCaller *caller);

THIRP_API int  thirp_conn_read(ThirpConn *conn, void *buf, size_t n, size_t *got);
THIRP_API int  thirp_conn_write(ThirpConn *conn, const void *buf, size_t n, size_t *put);
THIRP_API void thirp_conn_close(ThirpConn *conn);
THIRP_API void thirp_conn_destroy(ThirpConn *conn);

#ifdef __cplusplus
}
#endif

#endif /* THIRP_H */
