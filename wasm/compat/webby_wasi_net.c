/* BSD sockets for wasm32-wasip1 on top of wasi:sockets 0.2 (TCP, UDP, name lookup).
 *
 * The module is still a wasip1 program; these calls go through the WASI 0.2 bindings that wasi-sdk ships for wasip2
 * (wasi/wasip2.h, linked from its wasip2 libc as wasip2.o + wasip2_component_type.o), so a module that opens a socket
 * imports wasi:sockets and wasi:io interfaces and runs as a component made with the preview1 adapter
 * (`wasm-tools component new --adapt`, which tools/wasi-run.py does on the fly). The host needs nothing beyond
 * wasmtime-wasi with network access turned on.
 *
 * A socket is a descriptor at WEBBY_NET_FD_BASE and up, far above anything wasip1 hands out. The libc calls that take
 * any descriptor (read, write, close, poll, fcntl, ioctl, send, recv, shutdown, getsockopt) are wrapped with
 * `wasm-ld --wrap` (cmake/wasi.cmake); the wrappers live in webby_wasi_net_wrap.c and only reach this file through
 * webby_net_ops, which socket() sets, so a program that never opens a socket does not pull in wasi:sockets.
 *
 * Every wasi:sockets socket is non-blocking underneath. A blocking socket (the default) waits on the operation's
 * pollable. poll() over a mix of sockets and wasip1 descriptors (stdin, files) checks the wasip1 ones every 10 ms. */
#include "webby_wasi_compat.h"
#include "webby_wasi_net.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <wasi/wasip2.h>

#define NET_MAX 1024

typedef enum { NET_NEW, NET_CONNECTING, NET_CONNECTED, NET_FAILED } net_state;

typedef struct {
    int used;
    int type;   /* SOCK_STREAM or SOCK_DGRAM */
    int family; /* AF_INET or AF_INET6 */
    int nonblock;
    net_state state;
    int so_error;
    int bound;
    tcp_own_tcp_socket_t tcp;
    udp_own_udp_socket_t udp;
    streams_own_input_stream_t in;
    streams_own_output_stream_t out;
    udp_own_incoming_datagram_stream_t din;
    udp_own_outgoing_datagram_stream_t dout;
    int has_streams;
    /* Pollables, subscribed once and kept until close. */
    poll_own_pollable_t sock_p, in_p, out_p;
    int has_sock_p, has_in_p, has_out_p;
    int in_eof;
    /* Bytes read ahead by MSG_PEEK (TCP). */
    uint8_t *ahead;
    size_t ahead_len, ahead_off;
} net_sock;

static net_sock socks[NET_MAX];
static network_own_network_t g_network;
static int g_have_network;

static network_borrow_network_t net_network(void)
{
    if (!g_have_network) {
        g_network = instance_network_instance_network();
        g_have_network = 1;
    }
    return network_borrow_network(g_network);
}

static net_sock *net_get(int fd)
{
    if (fd < WEBBY_NET_FD_BASE || fd >= WEBBY_NET_FD_BASE + NET_MAX)
        return NULL;
    net_sock *s = &socks[fd - WEBBY_NET_FD_BASE];
    return s->used ? s : NULL;
}

static int net_errno(network_error_code_t code)
{
    switch (code) {
    case NETWORK_ERROR_CODE_ACCESS_DENIED: return EACCES;
    case NETWORK_ERROR_CODE_NOT_SUPPORTED: return EOPNOTSUPP;
    case NETWORK_ERROR_CODE_INVALID_ARGUMENT: return EINVAL;
    case NETWORK_ERROR_CODE_OUT_OF_MEMORY: return ENOMEM;
    case NETWORK_ERROR_CODE_TIMEOUT: return ETIMEDOUT;
    case NETWORK_ERROR_CODE_CONCURRENCY_CONFLICT: return EALREADY;
    case NETWORK_ERROR_CODE_NOT_IN_PROGRESS: return EALREADY;
    case NETWORK_ERROR_CODE_WOULD_BLOCK: return EWOULDBLOCK;
    case NETWORK_ERROR_CODE_INVALID_STATE: return EINVAL;
    case NETWORK_ERROR_CODE_NEW_SOCKET_LIMIT: return EMFILE;
    case NETWORK_ERROR_CODE_ADDRESS_NOT_BINDABLE: return EADDRNOTAVAIL;
    case NETWORK_ERROR_CODE_ADDRESS_IN_USE: return EADDRINUSE;
    case NETWORK_ERROR_CODE_REMOTE_UNREACHABLE: return EHOSTUNREACH;
    case NETWORK_ERROR_CODE_CONNECTION_REFUSED: return ECONNREFUSED;
    case NETWORK_ERROR_CODE_CONNECTION_RESET: return ECONNRESET;
    case NETWORK_ERROR_CODE_CONNECTION_ABORTED: return ECONNABORTED;
    case NETWORK_ERROR_CODE_DATAGRAM_TOO_LARGE: return EMSGSIZE;
    default: return EIO;
    }
}

static int fail(int e)
{
    errno = e;
    return -1;
}

/* ---- addresses ---- */

static int to_wasi_addr(const struct sockaddr *a, socklen_t len, network_ip_socket_address_t *out)
{
    if (!a)
        return EINVAL;
    if (a->sa_family == AF_INET && len >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)a;
        const uint8_t *b = (const uint8_t *)&in->sin_addr;
        out->tag = NETWORK_IP_SOCKET_ADDRESS_IPV4;
        out->val.ipv4.port = ntohs(in->sin_port);
        out->val.ipv4.address = (network_ipv4_address_t) { b[0], b[1], b[2], b[3] };
        return 0;
    }
    if (a->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)a;
        const uint8_t *b = in6->sin6_addr.s6_addr;
        uint16_t w[8];
        for (int i = 0; i < 8; i++)
            w[i] = (uint16_t)(b[2 * i] << 8 | b[2 * i + 1]);
        out->tag = NETWORK_IP_SOCKET_ADDRESS_IPV6;
        out->val.ipv6.port = ntohs(in6->sin6_port);
        out->val.ipv6.flow_info = ntohl(in6->sin6_flowinfo);
        out->val.ipv6.address = (network_ipv6_address_t) { w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7] };
        out->val.ipv6.scope_id = in6->sin6_scope_id;
        return 0;
    }
    return a->sa_family == AF_INET || a->sa_family == AF_INET6 ? EINVAL : EAFNOSUPPORT;
}

static socklen_t from_wasi_ip(const network_ip_address_t *ip, uint16_t port, struct sockaddr_storage *out)
{
    memset(out, 0, sizeof *out);
    if (ip->tag == NETWORK_IP_ADDRESS_IPV4) {
        struct sockaddr_in *in = (struct sockaddr_in *)out;
        uint8_t *b = (uint8_t *)&in->sin_addr;
        in->sin_family = AF_INET;
        in->sin_port = htons(port);
        b[0] = ip->val.ipv4.f0, b[1] = ip->val.ipv4.f1, b[2] = ip->val.ipv4.f2, b[3] = ip->val.ipv4.f3;
        return sizeof(struct sockaddr_in);
    }
    struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)out;
    const uint16_t *w = &ip->val.ipv6.f0;
    in6->sin6_family = AF_INET6;
    in6->sin6_port = htons(port);
    for (int i = 0; i < 8; i++) {
        in6->sin6_addr.s6_addr[2 * i] = (uint8_t)(w[i] >> 8);
        in6->sin6_addr.s6_addr[2 * i + 1] = (uint8_t)w[i];
    }
    return sizeof(struct sockaddr_in6);
}

static socklen_t from_wasi_addr(const network_ip_socket_address_t *a, struct sockaddr_storage *out)
{
    network_ip_address_t ip;
    if (a->tag == NETWORK_IP_SOCKET_ADDRESS_IPV4) {
        ip.tag = NETWORK_IP_ADDRESS_IPV4;
        ip.val.ipv4 = a->val.ipv4.address;
        return from_wasi_ip(&ip, a->val.ipv4.port, out);
    }
    ip.tag = NETWORK_IP_ADDRESS_IPV6;
    ip.val.ipv6 = a->val.ipv6.address;
    socklen_t len = from_wasi_ip(&ip, a->val.ipv6.port, out);
    ((struct sockaddr_in6 *)out)->sin6_flowinfo = htonl(a->val.ipv6.flow_info);
    ((struct sockaddr_in6 *)out)->sin6_scope_id = a->val.ipv6.scope_id;
    return len;
}

static void copy_out_addr(const struct sockaddr_storage *ss, socklen_t len, struct sockaddr *addr, socklen_t *addr_len)
{
    if (!addr || !addr_len)
        return;
    memcpy(addr, ss, len < *addr_len ? len : *addr_len);
    *addr_len = len;
}

/* ---- pollables ---- */

static poll_borrow_pollable_t sock_pollable(net_sock *s)
{
    if (!s->has_sock_p) {
        s->sock_p = s->type == SOCK_STREAM ? tcp_method_tcp_socket_subscribe(tcp_borrow_tcp_socket(s->tcp))
                                           : udp_method_udp_socket_subscribe(udp_borrow_udp_socket(s->udp));
        s->has_sock_p = 1;
    }
    return poll_borrow_pollable(s->sock_p);
}

static poll_borrow_pollable_t in_pollable(net_sock *s)
{
    if (!s->has_in_p) {
        s->in_p = s->type == SOCK_STREAM
            ? streams_method_input_stream_subscribe(streams_borrow_input_stream(s->in))
            : udp_method_incoming_datagram_stream_subscribe(udp_borrow_incoming_datagram_stream(s->din));
        s->has_in_p = 1;
    }
    return poll_borrow_pollable(s->in_p);
}

static poll_borrow_pollable_t out_pollable(net_sock *s)
{
    if (!s->has_out_p) {
        s->out_p = s->type == SOCK_STREAM
            ? streams_method_output_stream_subscribe(streams_borrow_output_stream(s->out))
            : udp_method_outgoing_datagram_stream_subscribe(udp_borrow_outgoing_datagram_stream(s->dout));
        s->has_out_p = 1;
    }
    return poll_borrow_pollable(s->out_p);
}

static void drop_pollable(poll_own_pollable_t *p, int *has)
{
    if (*has)
        poll_pollable_drop_own(*p);
    *has = 0;
}

static void drop_streams(net_sock *s)
{
    drop_pollable(&s->in_p, &s->has_in_p);
    drop_pollable(&s->out_p, &s->has_out_p);
    if (!s->has_streams)
        return;
    if (s->type == SOCK_STREAM) {
        streams_input_stream_drop_own(s->in);
        streams_output_stream_drop_own(s->out);
    } else {
        udp_incoming_datagram_stream_drop_own(s->din);
        udp_outgoing_datagram_stream_drop_own(s->dout);
    }
    s->has_streams = 0;
}

/* ---- socket, connect, bind ---- */

static int net_close(int fd);

static int net_socket(int domain, int type, int protocol);
int socket(int domain, int type, int protocol)
{
    int fd = net_socket(domain, type, protocol);
    webby_net_trace("net: socket(%d, %d) = %d%s%s", domain, type, fd, fd < 0 ? " " : "", fd < 0 ? strerror(errno) : "");
    return fd;
}

static int net_socket(int domain, int type, int protocol)
{
    (void)protocol;
    if (domain != AF_INET && domain != AF_INET6)
        return fail(domain == AF_UNIX ? ENOTSUP : EAFNOSUPPORT);
    int base = type & ~(SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (base != SOCK_STREAM && base != SOCK_DGRAM)
        return fail(EPROTONOSUPPORT);
    int i = 0;
    while (i < NET_MAX && socks[i].used)
        i++;
    if (i == NET_MAX)
        return fail(EMFILE);
    net_sock *s = &socks[i];
    memset(s, 0, sizeof *s);
    network_ip_address_family_t family = domain == AF_INET ? NETWORK_IP_ADDRESS_FAMILY_IPV4 : NETWORK_IP_ADDRESS_FAMILY_IPV6;
    network_error_code_t err;
    if (base == SOCK_STREAM ? !tcp_create_socket_create_tcp_socket(family, &s->tcp, &err)
                            : !udp_create_socket_create_udp_socket(family, &s->udp, &err))
        return fail(net_errno(err));
    s->used = 1;
    s->type = base;
    s->family = domain;
    s->nonblock = (type & SOCK_NONBLOCK) != 0;
    webby_net_ops = &webby_net_ops_impl;
    return WEBBY_NET_FD_BASE + i;
}

/* The TCP connection finished (or failed) in the background: collect it. Returns 1 when it is no longer pending. */
static int tcp_try_finish(net_sock *s)
{
    if (s->state != NET_CONNECTING)
        return 1;
    tcp_tuple2_own_input_stream_own_output_stream_t streams;
    network_error_code_t err;
    if (tcp_method_tcp_socket_finish_connect(tcp_borrow_tcp_socket(s->tcp), &streams, &err)) {
        s->in = streams.f0;
        s->out = streams.f1;
        s->has_streams = 1;
        s->state = NET_CONNECTED;
        return 1;
    }
    if (err == NETWORK_ERROR_CODE_WOULD_BLOCK)
        return 0;
    s->state = NET_FAILED;
    s->so_error = net_errno(err);
    return 1;
}

static int udp_bind_any(net_sock *s)
{
    if (s->bound)
        return 0;
    network_ip_socket_address_t any;
    memset(&any, 0, sizeof any);
    any.tag = s->family == AF_INET ? NETWORK_IP_SOCKET_ADDRESS_IPV4 : NETWORK_IP_SOCKET_ADDRESS_IPV6;
    network_error_code_t err;
    if (!udp_method_udp_socket_start_bind(udp_borrow_udp_socket(s->udp), net_network(), &any, &err))
        return net_errno(err);
    while (!udp_method_udp_socket_finish_bind(udp_borrow_udp_socket(s->udp), &err)) {
        if (err != NETWORK_ERROR_CODE_WOULD_BLOCK)
            return net_errno(err);
        poll_method_pollable_block(sock_pollable(s));
    }
    s->bound = 1;
    return 0;
}

static int udp_set_remote(net_sock *s, network_ip_socket_address_t *remote)
{
    int e = udp_bind_any(s);
    if (e)
        return e;
    drop_streams(s);
    udp_tuple2_own_incoming_datagram_stream_own_outgoing_datagram_stream_t streams;
    network_error_code_t err;
    if (!udp_method_udp_socket_stream(udp_borrow_udp_socket(s->udp), remote, &streams, &err))
        return net_errno(err);
    s->din = streams.f0;
    s->dout = streams.f1;
    s->has_streams = 1;
    return 0;
}

static int net_connect(int fd, const struct sockaddr *addr, socklen_t len);
int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    int r = net_connect(fd, addr, len);
    webby_net_trace("net: connect(%d) = %d%s%s", fd, r, r < 0 ? " " : "", r < 0 ? strerror(errno) : "");
    return r;
}

static int net_connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(fd >= 0 ? ENOTSOCK : EBADF);
    network_ip_socket_address_t remote;
    int e = to_wasi_addr(addr, len, &remote);
    if (e)
        return fail(e);
    if (s->type == SOCK_DGRAM) {
        e = udp_set_remote(s, &remote);
        if (e)
            return fail(e);
        s->state = NET_CONNECTED;
        return 0;
    }
    if (s->state == NET_CONNECTING)
        return fail(EALREADY);
    if (s->state != NET_NEW)
        return fail(EISCONN);
    network_error_code_t err;
    if (!tcp_method_tcp_socket_start_connect(tcp_borrow_tcp_socket(s->tcp), net_network(), &remote, &err))
        return fail(net_errno(err));
    s->state = NET_CONNECTING;
    if (s->nonblock)
        return fail(EINPROGRESS);
    while (!tcp_try_finish(s))
        poll_method_pollable_block(sock_pollable(s));
    if (s->state == NET_FAILED) {
        int error = s->so_error;
        s->so_error = 0;
        return fail(error);
    }
    return 0;
}

int bind(int fd, const struct sockaddr *addr, socklen_t len)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(ENOTSUP);
    network_ip_socket_address_t local;
    int e = to_wasi_addr(addr, len, &local);
    if (e)
        return fail(e);
    network_error_code_t err;
    if (s->type == SOCK_DGRAM) {
        if (!udp_method_udp_socket_start_bind(udp_borrow_udp_socket(s->udp), net_network(), &local, &err))
            return fail(net_errno(err));
        while (!udp_method_udp_socket_finish_bind(udp_borrow_udp_socket(s->udp), &err)) {
            if (err != NETWORK_ERROR_CODE_WOULD_BLOCK)
                return fail(net_errno(err));
            poll_method_pollable_block(sock_pollable(s));
        }
    } else {
        if (!tcp_method_tcp_socket_start_bind(tcp_borrow_tcp_socket(s->tcp), net_network(), &local, &err))
            return fail(net_errno(err));
        while (!tcp_method_tcp_socket_finish_bind(tcp_borrow_tcp_socket(s->tcp), &err)) {
            if (err != NETWORK_ERROR_CODE_WOULD_BLOCK)
                return fail(net_errno(err));
            poll_method_pollable_block(sock_pollable(s));
        }
    }
    s->bound = 1;
    return 0;
}

/* Listening sockets need accept(), which the wasip1 libc owns; webby has no use for servers in the module yet. */
int listen(int fd, int backlog)
{
    (void)fd;
    (void)backlog;
    return fail(ENOTSUP);
}

int socketpair(int domain, int type, int protocol, int fds[2])
{
    (void)domain;
    (void)type;
    (void)protocol;
    (void)fds;
    return fail(ENOTSUP);
}

/* ---- reading and writing ---- */

static int would_block(net_sock *s, int flags)
{
    return s->nonblock || (flags & MSG_DONTWAIT);
}

static ssize_t tcp_recv(net_sock *s, void *buffer, size_t length, int flags)
{
    if (s->state == NET_CONNECTING) {
        while (!tcp_try_finish(s)) {
            if (would_block(s, flags))
                return fail(EAGAIN);
            poll_method_pollable_block(sock_pollable(s));
        }
    }
    if (s->state != NET_CONNECTED)
        return fail(ENOTCONN);
    if (length == 0)
        return 0;
    if (s->ahead_len > s->ahead_off) {
        size_t n = s->ahead_len - s->ahead_off;
        if (n > length)
            n = length;
        memcpy(buffer, s->ahead + s->ahead_off, n);
        if (!(flags & MSG_PEEK)) {
            s->ahead_off += n;
            if (s->ahead_off == s->ahead_len) {
                free(s->ahead);
                s->ahead = NULL;
                s->ahead_len = s->ahead_off = 0;
            }
        }
        return (ssize_t)n;
    }
    if (s->in_eof)
        return 0;
    for (;;) {
        wasip2_list_u8_t data;
        streams_stream_error_t err;
        if (!streams_method_input_stream_read(streams_borrow_input_stream(s->in), length, &data, &err)) {
            if (err.tag == STREAMS_STREAM_ERROR_CLOSED) {
                s->in_eof = 1;
                return 0;
            }
            io_error_error_drop_own(err.val.last_operation_failed);
            return fail(ECONNRESET);
        }
        if (data.len) {
            memcpy(buffer, data.ptr, data.len);
            if (flags & MSG_PEEK) {
                s->ahead = data.ptr;
                s->ahead_len = data.len;
                s->ahead_off = 0;
            } else {
                wasip2_list_u8_free(&data);
            }
            return (ssize_t)data.len;
        }
        wasip2_list_u8_free(&data);
        if (would_block(s, flags))
            return fail(EAGAIN);
        poll_method_pollable_block(in_pollable(s));
    }
}

static ssize_t tcp_send(net_sock *s, const void *buffer, size_t length, int flags)
{
    if (s->state == NET_CONNECTING) {
        while (!tcp_try_finish(s)) {
            if (would_block(s, flags))
                return fail(EAGAIN);
            poll_method_pollable_block(sock_pollable(s));
        }
    }
    if (s->state != NET_CONNECTED)
        return fail(ENOTCONN);
    for (;;) {
        uint64_t permit;
        streams_stream_error_t err;
        if (!streams_method_output_stream_check_write(streams_borrow_output_stream(s->out), &permit, &err)) {
            if (err.tag == STREAMS_STREAM_ERROR_LAST_OPERATION_FAILED)
                io_error_error_drop_own(err.val.last_operation_failed);
            return fail(EPIPE);
        }
        if (permit) {
            size_t n = length < permit ? length : (size_t)permit;
            wasip2_list_u8_t data = { (uint8_t *)buffer, n };
            if (!streams_method_output_stream_write(streams_borrow_output_stream(s->out), &data, &err)) {
                if (err.tag == STREAMS_STREAM_ERROR_LAST_OPERATION_FAILED)
                    io_error_error_drop_own(err.val.last_operation_failed);
                return fail(EPIPE);
            }
            return (ssize_t)n;
        }
        if (would_block(s, flags))
            return fail(EAGAIN);
        poll_method_pollable_block(out_pollable(s));
    }
}

static ssize_t udp_recv(net_sock *s, void *buffer, size_t length, int flags, struct sockaddr *addr, socklen_t *addr_len)
{
    if (!s->has_streams)
        return fail(s->bound ? EAGAIN : ENOTCONN);
    for (;;) {
        udp_list_incoming_datagram_t list;
        network_error_code_t err;
        if (!udp_method_incoming_datagram_stream_receive(udp_borrow_incoming_datagram_stream(s->din), 1, &list, &err))
            return fail(net_errno(err));
        if (list.len) {
            udp_incoming_datagram_t *d = &list.ptr[0];
            size_t n = d->data.len < length ? d->data.len : length;
            memcpy(buffer, d->data.ptr, n);
            struct sockaddr_storage ss;
            copy_out_addr(&ss, from_wasi_addr(&d->remote_address, &ss), addr, addr_len);
            udp_list_incoming_datagram_free(&list);
            return (ssize_t)n;
        }
        udp_list_incoming_datagram_free(&list);
        if (would_block(s, flags))
            return fail(EAGAIN);
        poll_method_pollable_block(in_pollable(s));
    }
}

static ssize_t udp_send(net_sock *s, const void *buffer, size_t length, int flags, const struct sockaddr *addr,
                        socklen_t addr_len)
{
    udp_outgoing_datagram_t d;
    d.data = (wasip2_list_u8_t) { (uint8_t *)buffer, length };
    d.remote_address.is_some = addr != NULL;
    if (addr) {
        int e = to_wasi_addr(addr, addr_len, &d.remote_address.val);
        if (e)
            return fail(e);
    }
    if (!s->has_streams) {
        if (!addr)
            return fail(EDESTADDRREQ);
        int e = udp_set_remote(s, NULL);
        if (e)
            return fail(e);
    }
    for (;;) {
        uint64_t permit;
        network_error_code_t err;
        if (!udp_method_outgoing_datagram_stream_check_send(udp_borrow_outgoing_datagram_stream(s->dout), &permit, &err))
            return fail(net_errno(err));
        if (permit) {
            udp_list_outgoing_datagram_t list = { &d, 1 };
            uint64_t sent;
            if (!udp_method_outgoing_datagram_stream_send(udp_borrow_outgoing_datagram_stream(s->dout), &list, &sent, &err))
                return fail(net_errno(err));
            return (ssize_t)length;
        }
        if (would_block(s, flags))
            return fail(EAGAIN);
        poll_method_pollable_block(out_pollable(s));
    }
}

static ssize_t net_recvfrom(int fd, void *buffer, size_t length, int flags, struct sockaddr *addr, socklen_t *addr_len)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(EBADF);
    if (s->type == SOCK_DGRAM)
        return udp_recv(s, buffer, length, flags, addr, addr_len);
    if (addr_len)
        *addr_len = 0;
    return tcp_recv(s, buffer, length, flags);
}

static ssize_t net_sendto(int fd, const void *buffer, size_t length, int flags, const struct sockaddr *addr,
                          socklen_t addr_len)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(EBADF);
    if (s->type == SOCK_DGRAM)
        return udp_send(s, buffer, length, flags, addr, addr_len);
    return tcp_send(s, buffer, length, flags);
}

ssize_t sendto(int fd, const void *buffer, size_t length, int flags, const struct sockaddr *addr, socklen_t addr_len)
{
    if (!net_get(fd))
        return fail(ENOTSOCK);
    return net_sendto(fd, buffer, length, flags, addr, addr_len);
}

ssize_t recvfrom(int fd, void *buffer, size_t length, int flags, struct sockaddr *addr, socklen_t *addr_len)
{
    if (!net_get(fd))
        return fail(ENOTSOCK);
    return net_recvfrom(fd, buffer, length, flags, addr, addr_len);
}

/* ---- close, shutdown, names, options ---- */

static int net_close(int fd)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(EBADF);
    /* Children before parents: pollables, then streams, then the socket. */
    drop_streams(s);
    drop_pollable(&s->sock_p, &s->has_sock_p);
    if (s->type == SOCK_STREAM)
        tcp_tcp_socket_drop_own(s->tcp);
    else
        udp_udp_socket_drop_own(s->udp);
    free(s->ahead);
    memset(s, 0, sizeof *s);
    return 0;
}

static int net_shutdown(int fd, int how)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(EBADF);
    if (s->type != SOCK_STREAM)
        return 0;
    if (s->state != NET_CONNECTED)
        return fail(ENOTCONN);
    tcp_shutdown_type_t type = how == SHUT_RD ? TCP_SHUTDOWN_TYPE_RECEIVE : how == SHUT_WR ? TCP_SHUTDOWN_TYPE_SEND : TCP_SHUTDOWN_TYPE_BOTH;
    network_error_code_t err;
    if (!tcp_method_tcp_socket_shutdown(tcp_borrow_tcp_socket(s->tcp), type, &err))
        return fail(net_errno(err));
    return 0;
}

static int sock_name(int fd, struct sockaddr *addr, socklen_t *addr_len, int peer)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(ENOTSOCK);
    network_ip_socket_address_t a;
    network_error_code_t err;
    if (s->type == SOCK_STREAM)
        tcp_try_finish(s);
    if (!peer && (s->state == NET_NEW || s->state == NET_CONNECTING) && !s->bound) {
        /* wasi:sockets binds when the connection is made; until then report the unspecified address, port 0, as an
         * unbound socket does on Linux (curl asks right after a non-blocking connect). */
        memset(&a, 0, sizeof a);
        a.tag = s->family == AF_INET ? NETWORK_IP_SOCKET_ADDRESS_IPV4 : NETWORK_IP_SOCKET_ADDRESS_IPV6;
        struct sockaddr_storage ss;
        copy_out_addr(&ss, from_wasi_addr(&a, &ss), addr, addr_len);
        return 0;
    }
    int ok = s->type == SOCK_STREAM
        ? (peer ? tcp_method_tcp_socket_remote_address(tcp_borrow_tcp_socket(s->tcp), &a, &err)
                : tcp_method_tcp_socket_local_address(tcp_borrow_tcp_socket(s->tcp), &a, &err))
        : (peer ? udp_method_udp_socket_remote_address(udp_borrow_udp_socket(s->udp), &a, &err)
                : udp_method_udp_socket_local_address(udp_borrow_udp_socket(s->udp), &a, &err));
    if (!ok)
        return fail(peer ? ENOTCONN : net_errno(err));
    struct sockaddr_storage ss;
    copy_out_addr(&ss, from_wasi_addr(&a, &ss), addr, addr_len);
    return 0;
}

int getsockname(int fd, struct sockaddr *addr, socklen_t *addr_len)
{
    int r = sock_name(fd, addr, addr_len, 0);
    webby_net_trace("net: getsockname(%d) = %d%s%s", fd, r, r < 0 ? " " : "", r < 0 ? strerror(errno) : "");
    return r;
}

int getpeername(int fd, struct sockaddr *addr, socklen_t *addr_len)
{
    int r = sock_name(fd, addr, addr_len, 1);
    webby_net_trace("net: getpeername(%d) = %d%s%s", fd, r, r < 0 ? " " : "", r < 0 ? strerror(errno) : "");
    return r;
}

static int put_int(void *value, socklen_t *len, int v)
{
    if (!value || !len || *len < sizeof(int))
        return fail(EINVAL);
    memcpy(value, &v, sizeof v);
    *len = sizeof v;
    return 0;
}

static int net_getsockopt(int fd, int level, int name, void *value, socklen_t *len)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(EBADF);
    if (level == SOL_SOCKET && name == SO_ERROR) {
        if (s->type == SOCK_STREAM)
            tcp_try_finish(s);
        int e = s->so_error;
        s->so_error = 0;
        return put_int(value, len, e);
    }
    if (level == SOL_SOCKET && name == SO_TYPE)
        return put_int(value, len, s->type);
    /* Buffer sizes, keep-alive and the like: report 0 rather than fail, as callers only log these. */
    return put_int(value, len, 0);
}

int setsockopt(int fd, int level, int name, const void *value, socklen_t len)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(ENOTSUP);
    int v = 0;
    if (value && len >= sizeof(int))
        memcpy(&v, value, sizeof v);
    network_error_code_t err;
    if (s->type == SOCK_STREAM && level == SOL_SOCKET && name == SO_KEEPALIVE) {
        if (!tcp_method_tcp_socket_set_keep_alive_enabled(tcp_borrow_tcp_socket(s->tcp), v != 0, &err))
            return fail(net_errno(err));
        return 0;
    }
    /* TCP_NODELAY, buffer sizes, SO_REUSEADDR, ...: wasi:sockets has no equivalent (or picks well itself). */
    return 0;
}

static int net_fcntl(int fd, int cmd, int arg)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(EBADF);
    switch (cmd) {
    case F_GETFL: return O_RDWR | (s->nonblock ? O_NONBLOCK : 0);
    case F_SETFL: s->nonblock = (arg & O_NONBLOCK) != 0; return 0;
    case F_GETFD: return FD_CLOEXEC;
    case F_SETFD: return 0;
    default: return fail(EINVAL);
    }
}

static int net_ioctl(int fd, int request, void *arg)
{
    net_sock *s = net_get(fd);
    if (!s)
        return fail(EBADF);
    if (request == FIONBIO) {
        s->nonblock = arg && *(int *)arg;
        return 0;
    }
    if (request == FIONREAD) {
        if (arg)
            *(int *)arg = (int)(s->ahead_len - s->ahead_off);
        return 0;
    }
    return fail(ENOTTY);
}

/* ---- poll ---- */

/* What is ready on a socket right now; when nothing is, the pollables to wait on go into waits. */
static short net_revents(net_sock *s, short events, poll_borrow_pollable_t *waits, size_t *n_waits)
{
    short revents = 0;
    if (s->type == SOCK_STREAM && s->state == NET_CONNECTING && !tcp_try_finish(s)) {
        waits[(*n_waits)++] = sock_pollable(s);
        return 0;
    }
    if (s->state == NET_FAILED)
        return POLLERR | POLLHUP | (events & (POLLIN | POLLOUT));
    if (!s->has_streams)
        return s->type == SOCK_STREAM ? POLLHUP : 0;
    if (events & POLLIN) {
        if (s->ahead_len > s->ahead_off || s->in_eof || poll_method_pollable_ready(in_pollable(s)))
            revents |= POLLIN;
        else
            waits[(*n_waits)++] = in_pollable(s);
    }
    if (events & POLLOUT) {
        if (poll_method_pollable_ready(out_pollable(s)))
            revents |= POLLOUT;
        else
            waits[(*n_waits)++] = out_pollable(s);
    }
    return revents;
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int net_poll(struct pollfd *fds, nfds_t n, int timeout, int (*real_poll)(struct pollfd *, nfds_t, int))
{
    size_t n_other = 0;
    for (nfds_t i = 0; i < n; i++)
        if (fds[i].fd >= 0 && !net_get(fds[i].fd))
            n_other++;
    struct pollfd *other = n_other ? malloc(n_other * sizeof *other) : NULL;
    poll_borrow_pollable_t *waits = malloc((2 * n + 1) * sizeof *waits);
    if ((n_other && !other) || !waits) {
        free(other);
        free(waits);
        return fail(ENOMEM);
    }
    int64_t deadline = timeout >= 0 ? now_ms() + timeout : 0;
    int result;
    for (;;) {
        size_t n_waits = 0, k = 0;
        int ready = 0;
        for (nfds_t i = 0; i < n; i++) {
            fds[i].revents = 0;
            if (fds[i].fd < 0)
                continue;
            net_sock *s = net_get(fds[i].fd);
            if (s) {
                fds[i].revents = net_revents(s, fds[i].events, waits, &n_waits);
                ready += fds[i].revents != 0;
            } else {
                other[k++] = (struct pollfd) { fds[i].fd, fds[i].events, 0 };
            }
        }
        if (n_other) {
            int r = real_poll(other, n_other, 0);
            if (r < 0) {
                result = -1;
                break;
            }
            k = 0;
            for (nfds_t i = 0; i < n; i++)
                if (fds[i].fd >= 0 && !net_get(fds[i].fd)) {
                    fds[i].revents = other[k++].revents;
                    ready += fds[i].revents != 0;
                }
        }
        int64_t left = timeout >= 0 ? deadline - now_ms() : -1;
        if (ready || timeout == 0 || (timeout > 0 && left <= 0)) {
            result = ready;
            break;
        }
        /* Wait for a socket, the timeout, or (with wasip1 descriptors in the set) the next 10 ms check of those. */
        int64_t slice = left;
        if (n_other && (slice < 0 || slice > 10))
            slice = 10;
        poll_own_pollable_t timer;
        int has_timer = slice >= 0;
        if (has_timer) {
            timer = monotonic_clock_subscribe_duration((uint64_t)slice * 1000000);
            waits[n_waits++] = poll_borrow_pollable(timer);
        }
        if (n_waits) {
            poll_list_borrow_pollable_t list = { waits, n_waits };
            wasip2_list_u32_t woken;
            poll_poll(&list, &woken);
            wasip2_list_u32_free(&woken);
        }
        if (has_timer)
            poll_pollable_drop_own(timer);
        if (!n_waits) {
            /* Only unconnected sockets and an infinite timeout: nothing can ever become ready. */
            result = 0;
            break;
        }
    }
    free(other);
    free(waits);
    return result;
}

const struct webby_net_ops webby_net_ops_impl = {
    .close = net_close,
    .recvfrom = net_recvfrom,
    .sendto = net_sendto,
    .shutdown = net_shutdown,
    .getsockopt = net_getsockopt,
    .fcntl = net_fcntl,
    .ioctl = net_ioctl,
    .poll = net_poll,
};

/* ---- name lookup ---- */

typedef struct {
    struct addrinfo ai;
    struct sockaddr_storage ss;
} ai_block;

static int service_port(const char *service, int flags, int *port)
{
    *port = 0;
    if (!service || !*service)
        return 0;
    char *end;
    long v = strtol(service, &end, 10);
    if (!*end && v >= 0 && v <= 65535) {
        *port = (int)v;
        return 0;
    }
    if (flags & AI_NUMERICSERV)
        return EAI_NONAME;
    static const struct { const char *name; int port; } known[] = {
        { "http", 80 }, { "https", 443 }, { "domain", 53 }, { "ftp", 21 }, { "ws", 80 }, { "wss", 443 },
    };
    for (size_t i = 0; i < sizeof known / sizeof known[0]; i++)
        if (!strcmp(service, known[i].name)) {
            *port = known[i].port;
            return 0;
        }
    return EAI_SERVICE;
}

static int add_result(struct addrinfo ***tail, const struct sockaddr_storage *ss, socklen_t len, int socktype,
                      int protocol)
{
    ai_block *b = calloc(1, sizeof *b);
    if (!b)
        return EAI_MEMORY;
    memcpy(&b->ss, ss, len);
    b->ai.ai_family = ss->ss_family;
    b->ai.ai_socktype = socktype;
    b->ai.ai_protocol = protocol ? protocol : socktype == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP;
    b->ai.ai_addrlen = len;
    b->ai.ai_addr = (struct sockaddr *)&b->ss;
    **tail = &b->ai;
    *tail = &b->ai.ai_next;
    return 0;
}

static int net_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res)
{
    int r = net_getaddrinfo(node, service, hints, res);
    webby_net_trace("net: getaddrinfo(%s, %s) = %d", node ? node : "NULL", service ? service : "NULL", r);
    return r;
}

static int net_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res)
{
    *res = NULL;
    int flags = hints ? hints->ai_flags : 0;
    int family = hints ? hints->ai_family : AF_UNSPEC;
    int socktype = hints ? hints->ai_socktype : 0;
    int protocol = hints ? hints->ai_protocol : 0;
    if (family != AF_UNSPEC && family != AF_INET && family != AF_INET6)
        return EAI_FAMILY;
    if (socktype != 0 && socktype != SOCK_STREAM && socktype != SOCK_DGRAM)
        return EAI_SOCKTYPE;
    if (!node && !service)
        return EAI_NONAME;
    int port, e = service_port(service, flags, &port);
    if (e)
        return e;

    network_ip_address_t addrs[64];
    size_t n = 0;
    uint8_t raw[16];
    if (!node) {
        int passive = flags & AI_PASSIVE;
        if (family != AF_INET6) {
            addrs[n].tag = NETWORK_IP_ADDRESS_IPV4;
            addrs[n++].val.ipv4 = passive ? (network_ipv4_address_t) { 0, 0, 0, 0 } : (network_ipv4_address_t) { 127, 0, 0, 1 };
        }
        if (family != AF_INET) {
            addrs[n].tag = NETWORK_IP_ADDRESS_IPV6;
            addrs[n++].val.ipv6 = (network_ipv6_address_t) { 0, 0, 0, 0, 0, 0, 0, passive ? 0 : 1 };
        }
    } else if (inet_pton(AF_INET, node, raw) == 1) {
        if (family == AF_INET6)
            return EAI_NONAME;
        addrs[n].tag = NETWORK_IP_ADDRESS_IPV4;
        addrs[n++].val.ipv4 = (network_ipv4_address_t) { raw[0], raw[1], raw[2], raw[3] };
    } else if (inet_pton(AF_INET6, node, raw) == 1) {
        if (family == AF_INET)
            return EAI_NONAME;
        addrs[n].tag = NETWORK_IP_ADDRESS_IPV6;
        uint16_t *w = &addrs[n++].val.ipv6.f0;
        for (int i = 0; i < 8; i++)
            w[i] = (uint16_t)(raw[2 * i] << 8 | raw[2 * i + 1]);
    } else if (flags & AI_NUMERICHOST) {
        return EAI_NONAME;
    } else {
        wasip2_string_t name = { (uint8_t *)node, strlen(node) };
        ip_name_lookup_own_resolve_address_stream_t stream;
        network_error_code_t err;
        if (!ip_name_lookup_resolve_addresses(net_network(), &name, &stream, &err))
            return err == NETWORK_ERROR_CODE_INVALID_ARGUMENT ? EAI_NONAME : EAI_FAIL;
        ip_name_lookup_borrow_resolve_address_stream_t bs = ip_name_lookup_borrow_resolve_address_stream(stream);
        poll_own_pollable_t p;
        int has_p = 0;
        int result = 0;
        for (;;) {
            ip_name_lookup_option_ip_address_t next;
            if (!ip_name_lookup_method_resolve_address_stream_resolve_next_address(bs, &next, &err)) {
                if (err == NETWORK_ERROR_CODE_WOULD_BLOCK) {
                    if (!has_p) {
                        p = ip_name_lookup_method_resolve_address_stream_subscribe(bs);
                        has_p = 1;
                    }
                    poll_method_pollable_block(poll_borrow_pollable(p));
                    continue;
                }
                result = err == NETWORK_ERROR_CODE_NAME_UNRESOLVABLE ? EAI_NONAME
                    : err == NETWORK_ERROR_CODE_TEMPORARY_RESOLVER_FAILURE ? EAI_AGAIN
                    : EAI_FAIL;
                break;
            }
            if (!next.is_some)
                break;
            int f = next.val.tag == NETWORK_IP_ADDRESS_IPV4 ? AF_INET : AF_INET6;
            if ((family == AF_UNSPEC || family == f) && n < sizeof addrs / sizeof addrs[0])
                addrs[n++] = next.val;
        }
        if (has_p)
            poll_pollable_drop_own(p);
        ip_name_lookup_resolve_address_stream_drop_own(stream);
        if (result)
            return result;
        if (!n)
            return EAI_NONAME;
    }

    struct addrinfo *head = NULL, **tail = &head;
    for (size_t i = 0; i < n; i++) {
        struct sockaddr_storage ss;
        socklen_t len = from_wasi_ip(&addrs[i], (uint16_t)port, &ss);
        for (int t = 0; t < 2; t++) {
            int type = t ? SOCK_DGRAM : SOCK_STREAM;
            if (socktype && socktype != type)
                continue;
            if ((e = add_result(&tail, &ss, len, type, protocol))) {
                freeaddrinfo(head);
                return e;
            }
        }
    }
    if (head && (flags & AI_CANONNAME) && node)
        head->ai_canonname = strdup(node);
    *res = head;
    return 0;
}

void freeaddrinfo(struct addrinfo *res)
{
    while (res) {
        struct addrinfo *next = res->ai_next;
        free(res->ai_canonname);
        free(res); /* the ai_block it starts */
        res = next;
    }
}

const char *gai_strerror(int code)
{
    switch (code) {
    case EAI_NONAME: return "Name does not resolve";
    case EAI_AGAIN: return "Temporary failure in name resolution";
    case EAI_FAIL: return "Name lookup failed (is the host's network turned on?)";
    case EAI_FAMILY: return "Address family not supported";
    case EAI_SOCKTYPE: return "Socket type not supported";
    case EAI_SERVICE: return "Unknown service";
    case EAI_MEMORY: return "Out of memory";
    default: return "Name lookup failed";
    }
}

/* Numeric only: wasi:sockets has no reverse lookup. */
int getnameinfo(const struct sockaddr *sa, socklen_t salen, char *host, socklen_t hostlen, char *serv,
                socklen_t servlen, int flags)
{
    (void)flags;
    const void *addr;
    int port;
    if (sa->sa_family == AF_INET && salen >= sizeof(struct sockaddr_in)) {
        addr = &((const struct sockaddr_in *)sa)->sin_addr;
        port = ntohs(((const struct sockaddr_in *)sa)->sin_port);
    } else if (sa->sa_family == AF_INET6 && salen >= sizeof(struct sockaddr_in6)) {
        addr = &((const struct sockaddr_in6 *)sa)->sin6_addr;
        port = ntohs(((const struct sockaddr_in6 *)sa)->sin6_port);
    } else {
        return EAI_FAMILY;
    }
    if (host && hostlen && !inet_ntop(sa->sa_family, addr, host, hostlen))
        return EAI_OVERFLOW;
    if (serv && servlen) {
        char buffer[8];
        int len = snprintf(buffer, sizeof buffer, "%d", port);
        if ((socklen_t)len >= servlen)
            return EAI_OVERFLOW;
        memcpy(serv, buffer, (size_t)len + 1);
    }
    return 0;
}
