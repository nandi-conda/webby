/* The functions webby_wasi_compat.h and netdb.h declare, for wasm32-wasip1. */
#include "webby_wasi_compat.h"
#include "netdb.h"
#include <errno.h>
#include <stdlib.h>

#define FAIL_ENOTSUP { errno = ENOTSUP; return -1; }
int socket(int d, int t, int p) { (void)d; (void)t; (void)p; FAIL_ENOTSUP }
int bind(int f, const struct sockaddr *a, socklen_t l) { (void)f; (void)a; (void)l; FAIL_ENOTSUP }
int listen(int f, int b) { (void)f; (void)b; FAIL_ENOTSUP }
int connect(int f, const struct sockaddr *a, socklen_t l) { (void)f; (void)a; (void)l; FAIL_ENOTSUP }
int socketpair(int d, int t, int p, int fds[2]) { (void)d; (void)t; (void)p; (void)fds; FAIL_ENOTSUP }
int setsockopt(int f, int lv, int n, const void *v, socklen_t l) { (void)f; (void)lv; (void)n; (void)v; (void)l; FAIL_ENOTSUP }
int getsockname(int f, struct sockaddr *a, socklen_t *l) { (void)f; (void)a; (void)l; FAIL_ENOTSUP }
int getpeername(int f, struct sockaddr *a, socklen_t *l) { (void)f; (void)a; (void)l; FAIL_ENOTSUP }

static char utc[] = "UTC";
char *tzname[2] = { utc, utc };
long timezone = 0;
int daylight = 0;
void tzset(void) { }

int pthread_setschedparam(pthread_t t, int p, const struct sched_param *s) { (void)t; (void)p; (void)s; return ENOTSUP; }
int pthread_getschedparam(pthread_t t, int *p, struct sched_param *s) { (void)t; (void)s; if (p) *p = 0; return 0; }

int getaddrinfo(const char *n, const char *s, const struct addrinfo *h, struct addrinfo **r)
{
    (void)n; (void)s; (void)h;
    *r = NULL;
    return EAI_FAIL;
}
void freeaddrinfo(struct addrinfo *r) { (void)r; }
const char *gai_strerror(int e)
{
    return e == EAI_FAIL ? "name lookup is not available in this WebAssembly module" : "name lookup failed";
}
int getnameinfo(const struct sockaddr *sa, socklen_t sl, char *h, socklen_t hl, char *sv, socklen_t svl, int f)
{
    (void)sa; (void)sl; (void)h; (void)hl; (void)sv; (void)svl; (void)f;
    return EAI_FAIL;
}
