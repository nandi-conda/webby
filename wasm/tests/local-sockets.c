/* Local sockets (compat/webby_wasi_local.c), as LibIPC's TransportSocket uses them: socketpair(), non-blocking
 * reads, poll(), SCM_RIGHTS, EOF when the peer goes, pipe(). tests/local-sockets.sh runs it twice: in memory under
 * wasmtime, and linked with the latha:proc backend under latha-run, where it also starts a copy of itself as a child
 * process and talks to it over a socket from webby_local_spawn(), passing a socket along. */
#include "webby_wasi_local.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define CHECK(c)                                                                              \
    do {                                                                                      \
        if (!(c)) {                                                                           \
            fprintf(stderr, "local-sockets: %s:%d: check failed: %s (errno %d %s)\n", __FILE__, __LINE__, #c, errno, \
                strerror(errno));                                                             \
            exit(1);                                                                          \
        }                                                                                     \
    } while (0)

static ssize_t send_fds(int fd, const void *data, size_t len, const int *fds, size_t nfds)
{
    struct iovec iov = { (void *)data, len };
    char control[CMSG_SPACE(sizeof(int) * 8)];
    struct msghdr m = { 0 };
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    if (nfds) {
        struct cmsghdr *c = (struct cmsghdr *)control;
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * nfds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * nfds);
        m.msg_control = control;
        m.msg_controllen = CMSG_LEN(sizeof(int) * nfds);
    }
    return sendmsg(fd, &m, 0);
}

static ssize_t recv_fds(int fd, void *data, size_t len, int *fds, size_t *nfds, int flags)
{
    struct iovec iov = { data, len };
    char control[CMSG_SPACE(sizeof(int) * 8)];
    struct msghdr m = { 0 };
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    m.msg_control = control;
    m.msg_controllen = sizeof control;
    ssize_t n = recvmsg(fd, &m, flags);
    *nfds = 0;
    if (n >= 0 && m.msg_controllen >= CMSG_LEN(sizeof(int))) {
        struct cmsghdr *c = CMSG_FIRSTHDR(&m);
        *nfds = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        memcpy(fds, CMSG_DATA(c), *nfds * sizeof(int));
    }
    return n;
}

static int poll1(int fd, short events, int timeout)
{
    struct pollfd p = { fd, events, 0 };
    int r = poll(&p, 1, timeout);
    return r <= 0 ? r : p.revents;
}

/* Child: echo every message back with "pong:", on the socket that came along with it if there was one. */
static int child(void)
{
    int p = webby_local_parent_fd();
    CHECK(p >= 0);
    for (;;) {
        char buf[64];
        int fds[8];
        size_t nfds;
        ssize_t n = recv_fds(p, buf, sizeof buf - 1, fds, &nfds, 0); /* blocking: waits for the parent */
        if (n == 0)
            return 0; /* (a component's exit code is only 0 or 1) */
        CHECK(n > 0);
        buf[n] = 0;
        char out[96];
        int len = snprintf(out, sizeof out, "pong:%s", buf);
        int to = nfds ? fds[0] : p;
        CHECK(write(to, out, len) == len);
        if (nfds)
            CHECK(close(fds[0]) == 0);
    }
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "child"))
        return child();
    int latha = webby_latha() != NULL;

    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) == 0);
    CHECK(WEBBY_IS_LOCAL_FD(sv[0]) && WEBBY_IS_LOCAL_FD(sv[1]));
    struct stat st;
    CHECK(fstat(sv[0], &st) == 0 && S_ISSOCK(st.st_mode));
    CHECK(fcntl(sv[1], F_SETFL, fcntl(sv[1], F_GETFL) | O_NONBLOCK) == 0);
    int buffer_size = 128 * 1024;
    CHECK(setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &buffer_size, sizeof buffer_size) == 0);

    /* Nothing there yet. */
    char buf[256];
    CHECK(read(sv[1], buf, sizeof buf) == -1 && errno == EAGAIN);
    CHECK(poll1(sv[1], POLLIN, 0) == 0);
    CHECK(poll1(sv[0], POLLOUT, 0) == POLLOUT);

    /* Bytes, read in pieces. */
    CHECK(write(sv[0], "hello world", 11) == 11);
    CHECK(poll1(sv[1], POLLIN, 1000) == POLLIN);
    int avail = 0;
    CHECK(ioctl(sv[1], FIONREAD, &avail) == 0 && avail == 11);
    CHECK(recv(sv[1], buf, 5, MSG_PEEK) == 5 && !memcmp(buf, "hello", 5));
    CHECK(read(sv[1], buf, 5) == 5 && !memcmp(buf, "hello", 5));
    CHECK(read(sv[1], buf, sizeof buf) == 6 && !memcmp(buf, " world", 6));

    /* Descriptors: another socket (and, in memory, a file), still working on the far side. */
    int other[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, other) == 0);
    int file = -1;
    if (!latha) {
        file = open("local-sockets.tmp", O_RDWR | O_CREAT | O_TRUNC, 0600);
        CHECK(file >= 0);
        CHECK(write(file, "file!", 5) == 5);
    }
    int passing[2] = { other[1], file };
    CHECK(send_fds(sv[0], "x", 1, passing, latha ? 1 : 2) == 1);
    CHECK(close(other[1]) == 0);
    if (!latha)
        CHECK(close(file) == 0); /* the receiver's copy stays open */
    int got[8];
    size_t ngot;
    CHECK(recv_fds(sv[1], buf, sizeof buf, got, &ngot, 0) == 1 && buf[0] == 'x');
    CHECK(ngot == (latha ? 1u : 2u));
    CHECK(write(got[0], "via passed socket", 17) == 17);
    CHECK(poll1(other[0], POLLIN, 1000) == POLLIN);
    CHECK(read(other[0], buf, sizeof buf) == 17 && !memcmp(buf, "via passed socket", 17));
    if (!latha) {
        CHECK(pread(got[1], buf, 5, 0) == 5 && !memcmp(buf, "file!", 5));
        CHECK(close(got[1]) == 0);
        CHECK(unlink("local-sockets.tmp") == 0);
    }

    /* The passed socket's last descriptor goes: its peer reads EOF, and sees POLLHUP. */
    CHECK(close(got[0]) == 0);
    CHECK(poll1(other[0], POLLIN, 1000) & POLLIN);
    CHECK(read(other[0], buf, sizeof buf) == 0);
    CHECK(close(other[0]) == 0);

    /* Queued bytes still come before EOF. */
    CHECK(write(sv[0], "last", 4) == 4);
    CHECK(close(sv[0]) == 0);
    CHECK(poll1(sv[1], POLLIN, 1000) & POLLIN);
    CHECK(read(sv[1], buf, sizeof buf) == 4);
    CHECK(read(sv[1], buf, sizeof buf) == 0);
    CHECK(close(sv[1]) == 0);
    CHECK(close(sv[1]) == -1 && errno == EBADF);

    /* A pipe. */
    int pp[2];
    CHECK(pipe(pp) == 0);
    CHECK(write(pp[1], "p", 1) == 1);
    CHECK(read(pp[0], buf, 1) == 1 && buf[0] == 'p');
    CHECK(close(pp[0]) == 0 && close(pp[1]) == 0);

    /* poll() with a local socket and a regular descriptor (stdout) together. */
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    struct pollfd ps[2] = { { sv[1], POLLIN, 0 }, { 1, POLLOUT, 0 } };
    CHECK(poll(ps, 2, 1000) >= 1 && ps[0].revents == 0 && (ps[1].revents & POLLOUT));
    CHECK(close(sv[0]) == 0 && close(sv[1]) == 0);

    if (latha) {
        /* A child instance: messages both ways, then a socket passed along and answered on. */
        uint32_t pid;
        int ch;
        char *child_argv[] = { argv[0], "child", NULL };
        CHECK(webby_local_spawn("", child_argv, &pid, &ch) == 0);
        CHECK(write(ch, "one", 3) == 3);
        CHECK(poll1(ch, POLLIN, 5000) & POLLIN);
        CHECK(read(ch, buf, sizeof buf) == 8 && !memcmp(buf, "pong:one", 8));
        int xy[2];
        CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, xy) == 0);
        CHECK(send_fds(ch, "two", 3, &xy[1], 1) == 3);
        CHECK(write(xy[1], "?", 1) == -1 && errno == EBADF); /* it moved to the child */
        CHECK(close(xy[1]) == 0);
        CHECK(poll1(xy[0], POLLIN, 5000) & POLLIN);
        CHECK(read(xy[0], buf, sizeof buf) == 8 && !memcmp(buf, "pong:two", 8));
        CHECK(poll1(xy[0], POLLIN, 5000) & POLLIN);
        CHECK(read(xy[0], buf, sizeof buf) == 0); /* the child closed its end */
        CHECK(close(xy[0]) == 0);
        CHECK(close(ch) == 0); /* ends the child's loop: it exits with 0 */
        int code = -1;
        CHECK(webby_latha()->wait_exit(pid, 5000, &code) == 0 && code == 0);
    }

    printf("local-sockets: ok (%s)\n", latha ? "latha:proc channels" : "in memory");
    return 0;
}
