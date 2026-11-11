/* Sockets over wasi:sockets 0.2 (webby_wasi_net.c) and the libc wrappers that route socket descriptors to them
 * (webby_wasi_net_wrap.c, linked with `wasm-ld --wrap`, see cmake/wasi.cmake). */
#pragma once
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>

/* Socket descriptors start here; wasip1 never hands out numbers this high. */
#define WEBBY_NET_FD_BASE 0x100000
#define WEBBY_NET_FD_END (WEBBY_NET_FD_BASE + 1024)

struct webby_net_ops {
    int (*close)(int fd);
    ssize_t (*recvfrom)(int fd, void *buffer, size_t length, int flags, struct sockaddr *addr, socklen_t *addr_len);
    ssize_t (*sendto)(int fd, const void *buffer, size_t length, int flags, const struct sockaddr *addr, socklen_t addr_len);
    int (*shutdown)(int fd, int how);
    int (*getsockopt)(int fd, int level, int name, void *value, socklen_t *len);
    int (*fcntl)(int fd, int cmd, int arg);
    int (*ioctl)(int fd, int request, void *arg);
    int (*poll)(struct pollfd *fds, nfds_t n, int timeout, int (*real_poll)(struct pollfd *, nfds_t, int));
};

/* Set by the first socket(); until then no descriptor is a socket and the wrappers go straight to libc. */
extern const struct webby_net_ops *webby_net_ops;
extern const struct webby_net_ops webby_net_ops_impl;

/* WEBBY_NET_TRACE=1 in the environment: each socket call and its result on stderr. */
void webby_net_trace(const char *format, ...) __attribute__((format(printf, 1, 2)));

/* The libc functions cmake/wasi.cmake wraps (keep the two lists the same). */
#define WEBBY_NET_WRAPPED close read write readv writev send recv shutdown poll fcntl ioctl getsockopt
