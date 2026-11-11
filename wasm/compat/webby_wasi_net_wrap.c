/* libc's descriptor calls, wrapped (`wasm-ld --wrap=close` and so on, cmake/wasi.cmake) so socket descriptors from
 * webby_wasi_net.c and local sockets from webby_wasi_local.c work with them. Nothing here references wasi:sockets: that file is only linked in by socket(). */
#include "webby_wasi_compat.h"
#include "webby_wasi_local.h"
#include "webby_wasi_net.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wasi/api.h>

const struct webby_net_ops *webby_net_ops;


#define IS_SOCKET(fd) (webby_net_ops && (fd) >= WEBBY_NET_FD_BASE && (fd) < WEBBY_NET_FD_END)
#define IS_LOCAL(fd) WEBBY_IS_LOCAL_FD(fd)

int __real_close(int fd);
ssize_t __real_read(int fd, void *buffer, size_t length);
ssize_t __real_write(int fd, const void *buffer, size_t length);
ssize_t __real_readv(int fd, const struct iovec *iov, int count);
ssize_t __real_writev(int fd, const struct iovec *iov, int count);
ssize_t __real_send(int fd, const void *buffer, size_t length, int flags);
ssize_t __real_recv(int fd, void *buffer, size_t length, int flags);
int __real_shutdown(int fd, int how);
int __real_poll(struct pollfd *fds, nfds_t n, int timeout);
int __real_fcntl(int fd, int cmd, ...);
int __real_ioctl(int fd, int request, ...);
int __real_getsockopt(int fd, int level, int name, void *value, socklen_t *len);

/* WEBBY_NET_TRACE=1: every socket call and its result on stderr. */
int webby_net_trace_on = -1;
void webby_net_trace(const char *format, ...)
{
    if (webby_net_trace_on < 0) {
        const char *v = getenv("WEBBY_NET_TRACE");
        webby_net_trace_on = v && *v && *v != '0';
    }
    if (!webby_net_trace_on)
        return;
    int saved = errno;
    char line[256];
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(line, sizeof line - 1, format, ap);
    va_end(ap);
    if (n < 0)
        n = 0;
    if (n > (int)sizeof line - 2)
        n = (int)sizeof line - 2;
    line[n++] = '\n';
    /* Straight to WASI: a __real_ reference to a function the program never calls itself makes wasm-ld resolve it
     * to the wrong function. */
    __wasi_ciovec_t iov = { (const uint8_t *)line, (size_t)n };
    __wasi_size_t written;
    (void)__wasi_fd_write(2, &iov, 1, &written);
    errno = saved;
}

#define TRACED(name, fd, call)                                                                    \
    ({                                                                                            \
        long _r = (long)(call);                                                                   \
        webby_net_trace("net: %s(%d) = %ld%s%s", name, fd, _r, _r < 0 ? " " : "", _r < 0 ? strerror(errno) : ""); \
        _r;                                                                                       \
    })

int __wrap_close(int fd)
{
    if (IS_LOCAL(fd))
        return webby_local_close(fd);
    /* Passed to this same instance and still held by the other side (webby_wasi_local.c). */
    if (webby_fd_release_share(fd))
        return 0;
    return IS_SOCKET(fd) ? TRACED("close", fd, webby_net_ops->close(fd)) : __real_close(fd);
}

ssize_t __wrap_read(int fd, void *buffer, size_t length)
{
    if (IS_LOCAL(fd))
        return webby_local_read(fd, buffer, length, 0);
    return IS_SOCKET(fd) ? TRACED("read", fd, webby_net_ops->recvfrom(fd, buffer, length, 0, 0, 0)) : __real_read(fd, buffer, length);
}

ssize_t __wrap_write(int fd, const void *buffer, size_t length)
{
    if (IS_LOCAL(fd))
        return webby_local_write(fd, buffer, length, 0);
    return IS_SOCKET(fd) ? TRACED("write", fd, webby_net_ops->sendto(fd, buffer, length, 0, 0, 0)) : __real_write(fd, buffer, length);
}

ssize_t __wrap_recv(int fd, void *buffer, size_t length, int flags)
{
    if (IS_LOCAL(fd))
        return webby_local_read(fd, buffer, length, flags);
    return IS_SOCKET(fd) ? TRACED("recv", fd, webby_net_ops->recvfrom(fd, buffer, length, flags, 0, 0)) : __real_recv(fd, buffer, length, flags);
}

ssize_t __wrap_send(int fd, const void *buffer, size_t length, int flags)
{
    if (IS_LOCAL(fd))
        return webby_local_write(fd, buffer, length, flags);
    return IS_SOCKET(fd) ? TRACED("send", fd, webby_net_ops->sendto(fd, buffer, length, flags, 0, 0)) : __real_send(fd, buffer, length, flags);
}

/* One buffer at a time; a short transfer ends the call, as it would on a socket. */
ssize_t __wrap_readv(int fd, const struct iovec *iov, int count)
{
    if (IS_LOCAL(fd)) {
        struct msghdr message = { 0 };
        message.msg_iov = (struct iovec *)iov;
        message.msg_iovlen = count;
        return webby_local_recvmsg(fd, &message, 0);
    }
    if (!IS_SOCKET(fd))
        return __real_readv(fd, iov, count);
    ssize_t total = 0;
    for (int i = 0; i < count; i++) {
        if (!iov[i].iov_len)
            continue;
        ssize_t n = webby_net_ops->recvfrom(fd, iov[i].iov_base, iov[i].iov_len, total ? MSG_DONTWAIT : 0, 0, 0);
        if (n < 0)
            return total ? total : n;
        total += n;
        if ((size_t)n < iov[i].iov_len)
            break;
    }
    return total;
}

ssize_t __wrap_writev(int fd, const struct iovec *iov, int count)
{
    if (IS_LOCAL(fd)) {
        struct msghdr message = { 0 };
        message.msg_iov = (struct iovec *)iov;
        message.msg_iovlen = count;
        return webby_local_sendmsg(fd, &message, 0);
    }
    if (!IS_SOCKET(fd))
        return __real_writev(fd, iov, count);
    ssize_t total = 0;
    for (int i = 0; i < count; i++) {
        if (!iov[i].iov_len)
            continue;
        ssize_t n = webby_net_ops->sendto(fd, iov[i].iov_base, iov[i].iov_len, total ? MSG_DONTWAIT : 0, 0, 0);
        if (n < 0)
            return total ? total : n;
        total += n;
        if ((size_t)n < iov[i].iov_len)
            break;
    }
    return total;
}

int __wrap_shutdown(int fd, int how) { return IS_LOCAL(fd) ? webby_local_shutdown(fd, how) : IS_SOCKET(fd) ? TRACED("shutdown", fd, webby_net_ops->shutdown(fd, how)) : __real_shutdown(fd, how); }

int __wrap_getsockopt(int fd, int level, int name, void *value, socklen_t *len)
{
    if (IS_LOCAL(fd))
        return webby_local_getsockopt(fd, level, name, value, len);
    return IS_SOCKET(fd) ? TRACED("getsockopt", fd, webby_net_ops->getsockopt(fd, level, name, value, len)) : __real_getsockopt(fd, level, name, value, len);
}

static int poll_without_local(struct pollfd *fds, nfds_t n, int timeout)
{
    if (webby_net_ops)
        for (nfds_t i = 0; i < n; i++)
            if (IS_SOCKET(fds[i].fd))
                return TRACED("poll", (int)n, webby_net_ops->poll(fds, n, timeout, __real_poll));
    return __real_poll(fds, n, timeout);
}

int __wrap_poll(struct pollfd *fds, nfds_t n, int timeout)
{
    for (nfds_t i = 0; i < n; i++)
        if (IS_LOCAL(fds[i].fd))
            return webby_local_poll(fds, n, timeout, poll_without_local);
    return poll_without_local(fds, n, timeout);
}

/* fcntl and ioctl take one int or pointer argument for every command wasi-libc knows. */
int __wrap_fcntl(int fd, int cmd, ...)
{
    va_list ap;
    va_start(ap, cmd);
    int arg = va_arg(ap, int);
    va_end(ap);
    if (IS_LOCAL(fd))
        return webby_local_fcntl(fd, cmd, arg);
    return IS_SOCKET(fd) ? TRACED("fcntl", fd, webby_net_ops->fcntl(fd, cmd, arg)) : __real_fcntl(fd, cmd, arg);
}

int __wrap_ioctl(int fd, int request, ...)
{
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (IS_LOCAL(fd))
        return webby_local_ioctl(fd, request, arg);
    return IS_SOCKET(fd) ? TRACED("ioctl", fd, webby_net_ops->ioctl(fd, request, arg)) : __real_ioctl(fd, request, arg);
}

/* Not libc functions (webby_wasi_compat.h declares them): socket options and names for both kinds of socket. */
int setsockopt(int fd, int level, int name, const void *value, socklen_t len)
{
    if (IS_LOCAL(fd))
        return 0;
    if (!IS_SOCKET(fd)) {
        errno = ENOTSOCK;
        return -1;
    }
    return webby_net_ops->setsockopt(fd, level, name, value, len);
}

static int sock_name(int fd, struct sockaddr *addr, socklen_t *len, int peer)
{
    if (IS_LOCAL(fd))
        return webby_local_name(fd, addr, len);
    if (!IS_SOCKET(fd)) {
        errno = ENOTSOCK;
        return -1;
    }
    return webby_net_ops->name(fd, addr, len, peer);
}

int getsockname(int fd, struct sockaddr *addr, socklen_t *len) { return sock_name(fd, addr, len, 0); }
int getpeername(int fd, struct sockaddr *addr, socklen_t *len) { return sock_name(fd, addr, len, 1); }
