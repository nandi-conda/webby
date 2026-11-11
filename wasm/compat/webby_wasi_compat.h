/* Included before every source of webby's wasm build (cmake/wasi.cmake): POSIX pieces wasm32-wasip1 lacks that
 * Ladybird and its dependencies name. Sockets that need a host (bind, listen, socket, connect) fail with ENOTSUP;
 * there is one time zone (UTC); threads are wasi-libc's stubs. */
#pragma once
#ifdef __wasi__
#include <stddef.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef MSG_NOSIGNAL
#    define MSG_NOSIGNAL 0
#endif
#ifndef AF_LOCAL
#    define AF_LOCAL AF_UNIX
#endif
#ifndef SOCK_CLOEXEC
#    define SOCK_CLOEXEC 0
#endif

int socket(int domain, int type, int protocol);
int bind(int fd, const struct sockaddr *addr, socklen_t len);
int listen(int fd, int backlog);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
int socketpair(int domain, int type, int protocol, int fds[2]);
int setsockopt(int fd, int level, int name, const void *value, socklen_t len);
int getsockname(int fd, struct sockaddr *addr, socklen_t *len);
int getpeername(int fd, struct sockaddr *addr, socklen_t *len);

void tzset(void);
extern char *tzname[2];
extern long timezone;
extern int daylight;

struct sched_param;
int pthread_setschedparam(pthread_t thread, int policy, const struct sched_param *param);
int pthread_getschedparam(pthread_t thread, int *policy, struct sched_param *param);

#ifdef __cplusplus
}
#endif
#endif
