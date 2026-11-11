/* Local sockets (webby_wasi_local.h): socketpair(), pipe() and SCM_RIGHTS for one single-threaded WASI instance,
 * in memory or over latha:proc channels.
 *
 * An endpoint ("lobj") is shared by every descriptor that refers to it (dup, or passing it to this same instance)
 * and by the messages it is in flight in; it goes away with the last of them, and its peer then reads EOF.
 *
 * In memory, a write appends one message (bytes and descriptors) to the peer's queue and never blocks: the reader
 * is this same thread, so a full buffer could never drain. A read returns bytes from one message at most, and a
 * message's descriptors come with its first read. A read that would block (nothing queued, peer still there) fails
 * with EAGAIN even on a blocking descriptor, since nothing could ever arrive while this thread waits.
 *
 * Over latha:proc (when the program links the backend, webby_latha()), socketpair() makes a channel, a write is one channel message
 * and the descriptors passed with it must be channel endpoints too: their handles move to the receiver, and the
 * sender's descriptors for them stop working (close them, as TransportSocket does). Blocking reads wait for the
 * peer, which is another instance. poll() waits on channels with the backend's wait, in slices when other
 * descriptors are in the set too.
 *
 * Shared memory objects (webby_shm_*) are local descriptors too. In memory an object is one page-aligned buffer and
 * every mapping of it is that buffer. Over latha:proc it is a host memory object: a mapping is a page-aligned
 * allocation of ours that the host maps the object over, so other instances' mappings see the same bytes. Passed to
 * another instance, the receiver gets a handle to the same object (the sender keeps its own). A regular file passed
 * to another instance goes as a new object holding a copy of its bytes. */
#include "webby_wasi_compat.h"
#include "webby_wasi_local.h"
#include "webby_wasi_net.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

/* The backend's definition is strong; a program without it gets the weak undefined NULL. */
extern const struct webby_latha_ops *webby_latha_backend_ops(void) __attribute__((weak));

static const struct webby_latha_ops *webby_latha_ops;
static int webby_latha_looked;

const struct webby_latha_ops *webby_latha(void)
{
    if (!webby_latha_looked) {
        webby_latha_looked = 1;
        webby_latha_ops = webby_latha_backend_ops ? webby_latha_backend_ops() : NULL;
    }
    return webby_latha_ops;
}

enum { K_MEM, K_LATHA, K_SHM };
enum { E_LOCAL, E_FOREIGN, E_HANDLE };

typedef struct lobj lobj;

typedef struct {
    int kind;
    lobj *obj;       /* E_LOCAL: holds a reference */
    int fd;          /* E_FOREIGN: shared descriptor number */
    uint32_t handle; /* E_HANDLE: a latha:proc endpoint we own */
} lent;

typedef struct lmsg {
    struct lmsg *next;
    unsigned char *data;
    size_t len, off;
    lent *ents;
    size_t nents;
} lmsg;

struct lobj {
    int refs;
    int kind;
    int type;
    lobj *peer;    /* K_MEM */
    lmsg *head, *tail;
    int peer_gone; /* EOF once the queue is empty */
    int rd_shut, wr_shut;
    uint32_t handle; /* K_LATHA, K_SHM over latha:proc */
    int moved;       /* the handle went to another instance */
    /* K_SHM */
    int host;            /* a latha:proc memory object (else bytes in buf) */
    unsigned char *buf;  /* in memory: the object's bytes (page aligned, capacity cap) */
    size_t size, cap;
    size_t pos;          /* read/write offset */
    unsigned char *view; /* host: a mapping for read/write, view_len bytes */
    size_t view_len;
};

/* ---- shared memory: mappings ---- */

typedef struct {
    void *addr;
    size_t len;
    lobj *obj; /* in memory: the object, referenced (the mapping is its buffer); host: NULL */
} lmap;
static lmap *maps;
static size_t nmaps;

static void unref(lobj *o);

size_t webby_shm_page_size(void)
{
    const struct webby_latha_ops *l = webby_latha();
    return l && l->page_size ? l->page_size() : 4096;
}

static size_t round_page(size_t n)
{
    size_t p = webby_shm_page_size();
    return (n + p - 1) / p * p;
}

static int add_map(void *addr, size_t len, lobj *obj)
{
    void *grown = realloc(maps, (nmaps + 1) * sizeof *maps);
    if (!grown)
        return -1;
    maps = grown;
    maps[nmaps].addr = addr;
    maps[nmaps].len = len;
    maps[nmaps].obj = obj;
    nmaps++;
    return 0;
}

/* Map a host object of size bytes: a page-aligned allocation of ours that the host maps it over. Pages past the
 * object's end (a mapping may be longer, like a file's) stay ours. */
static void *host_map(uint32_t handle, size_t offset, size_t length, size_t size)
{
    size_t len = round_page(length ? length : 1);
    size_t shared = offset >= size ? 0 : round_page(size - offset < length ? size - offset : length);
    void *at = aligned_alloc(webby_shm_page_size(), len);
    if (!at) {
        errno = ENOMEM;
        return NULL;
    }
    memset(at, 0, len);
    int r = shared ? webby_latha_ops->mem_map(handle, offset, at, shared) : 0;
    if (r < 0) {
        free(at);
        errno = -r;
        return NULL;
    }
    return at;
}

static void host_unmap(void *at, size_t length)
{
    size_t len = round_page(length ? length : 1);
    /* Our own zeroed pages back again, then the allocation is malloc's once more. */
    if (webby_latha_ops->mem_unmap(at, len) < 0)
        abort();
    free(at);
}

#define NLOCAL (WEBBY_LOCAL_FD_END - WEBBY_LOCAL_FD_BASE)
static struct {
    lobj *obj;
    int nonblock;
    int cloexec;
} ftab[NLOCAL];

static int fail(int e)
{
    errno = e;
    return -1;
}

static lobj *get(int fd)
{
    if (!WEBBY_IS_LOCAL_FD(fd))
        return NULL;
    return ftab[fd - WEBBY_LOCAL_FD_BASE].obj;
}

static int alloc_fd(lobj *o, int min_fd)
{
    int start = min_fd > WEBBY_LOCAL_FD_BASE ? min_fd - WEBBY_LOCAL_FD_BASE : 0;
    for (int i = start; i < NLOCAL; i++) {
        if (!ftab[i].obj) {
            ftab[i].obj = o;
            ftab[i].nonblock = 0;
            ftab[i].cloexec = 0;
            return WEBBY_LOCAL_FD_BASE + i;
        }
    }
    return fail(EMFILE);
}

static lobj *new_obj(int kind, int type)
{
    lobj *o = calloc(1, sizeof *o);
    if (o) {
        o->kind = kind;
        o->type = type;
    }
    return o;
}

/* ---- descriptors that are not local sockets, shared within the instance ---- */

static struct {
    int fd;
    int extra;
} *shares;
static size_t nshares;

static void share_fd(int fd)
{
    for (size_t i = 0; i < nshares; i++) {
        if (shares[i].fd == fd) {
            shares[i].extra++;
            return;
        }
    }
    void *grown = realloc(shares, (nshares + 1) * sizeof *shares);
    if (!grown)
        abort();
    shares = grown;
    shares[nshares].fd = fd;
    shares[nshares].extra = 1;
    nshares++;
}

int webby_fd_release_share(int fd)
{
    for (size_t i = 0; i < nshares; i++) {
        if (shares[i].fd == fd) {
            if (--shares[i].extra == 0)
                shares[i] = shares[--nshares];
            return 1;
        }
    }
    return 0;
}

/* ---- endpoints ---- */

static void drop_entry(lent *e)
{
    switch (e->kind) {
    case E_LOCAL:
        unref(e->obj);
        break;
    case E_FOREIGN:
        close(e->fd);
        break;
    case E_HANDLE:
        if (webby_latha_ops)
            webby_latha_ops->close(e->handle);
        break;
    }
}

static void free_msg(lmsg *m, int drop_ents)
{
    if (drop_ents)
        for (size_t i = 0; i < m->nents; i++)
            drop_entry(&m->ents[i]);
    free(m->ents);
    free(m->data);
    free(m);
}

static void unref(lobj *o)
{
    if (--o->refs > 0)
        return;
    if (o->kind == K_MEM && o->peer) {
        o->peer->peer_gone = 1;
        o->peer->peer = NULL;
    }
    if (o->kind == K_LATHA && !o->moved && webby_latha_ops)
        webby_latha_ops->close(o->handle);
    if (o->kind == K_SHM) {
        if (o->host) {
            if (o->view)
                host_unmap(o->view, o->view_len);
            webby_latha_ops->close(o->handle);
        } else {
            free(o->buf);
        }
    }
    lmsg *m = o->head;
    o->head = o->tail = NULL;
    while (m) {
        lmsg *next = m->next;
        free_msg(m, 1);
        m = next;
    }
    free(o);
}

static void enqueue(lobj *o, lmsg *m)
{
    m->next = NULL;
    if (o->tail)
        o->tail->next = m;
    else
        o->head = m;
    o->tail = m;
}

static int make_pair(int type, int fds[2])
{
    lobj *a = new_obj(K_MEM, type), *b = new_obj(K_MEM, type);
    if (!a || !b) {
        free(a);
        free(b);
        return fail(ENOMEM);
    }
    if (webby_latha()) {
        uint32_t hs[2];
        int r = webby_latha_ops->pair(hs);
        if (r < 0) {
            free(a);
            free(b);
            return fail(-r);
        }
        a->kind = b->kind = K_LATHA;
        a->handle = hs[0];
        b->handle = hs[1];
    } else {
        a->peer = b;
        b->peer = a;
    }
    a->refs = b->refs = 1;
    fds[0] = alloc_fd(a, 0);
    fds[1] = fds[0] < 0 ? -1 : alloc_fd(b, 0);
    if (fds[1] < 0) {
        if (fds[0] >= 0)
            webby_local_close(fds[0]);
        else
            unref(a);
        unref(b);
        return -1;
    }
    return 0;
}

int socketpair(int domain, int type, int protocol, int fds[2])
{
    (void)protocol;
    int flags = type & (SOCK_NONBLOCK | SOCK_CLOEXEC);
    type &= ~(SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (domain != AF_UNIX)
        return fail(EAFNOSUPPORT);
    if (type != SOCK_STREAM && type != SOCK_SEQPACKET && type != SOCK_DGRAM)
        return fail(EPROTOTYPE);
    if (make_pair(type, fds) < 0)
        return -1;
    for (int i = 0; i < 2; i++) {
        ftab[fds[i] - WEBBY_LOCAL_FD_BASE].nonblock = (flags & SOCK_NONBLOCK) != 0;
        ftab[fds[i] - WEBBY_LOCAL_FD_BASE].cloexec = (flags & SOCK_CLOEXEC) != 0;
    }
    return 0;
}

int pipe2(int fds[2], int flags)
{
    if (make_pair(SOCK_STREAM, fds) < 0)
        return -1;
    for (int i = 0; i < 2; i++)
        ftab[fds[i] - WEBBY_LOCAL_FD_BASE].nonblock = (flags & O_NONBLOCK) != 0;
    ftab[fds[0] - WEBBY_LOCAL_FD_BASE].obj->wr_shut = 1;
    ftab[fds[1] - WEBBY_LOCAL_FD_BASE].obj->rd_shut = 1;
    return 0;
}

int pipe(int fds[2]) { return pipe2(fds, 0); }

int webby_local_from_latha(uint32_t handle)
{
    lobj *o = new_obj(K_LATHA, SOCK_STREAM);
    if (!o)
        return fail(ENOMEM);
    o->handle = handle;
    o->refs = 1;
    int fd = alloc_fd(o, 0);
    if (fd < 0)
        unref(o);
    return fd;
}

int webby_local_parent_fd(void)
{
    uint32_t h;
    if (!webby_latha() || webby_latha_ops->parent(&h) < 0)
        return -1;
    return webby_local_from_latha(h);
}

int webby_local_spawn(const char *path, char *const argv[], uint32_t *pid, int *fd)
{
    if (!webby_latha())
        return fail(ENOSYS);
    uint32_t h;
    int r = webby_latha_ops->spawn(path, argv, pid, &h);
    if (r < 0)
        return fail(-r);
    *fd = webby_local_from_latha(h);
    return *fd < 0 ? -1 : 0;
}

/* ---- shared memory objects ---- */

static lobj *new_shm(int host, uint32_t handle, size_t size)
{
    lobj *o = new_obj(K_SHM, 0);
    if (!o)
        return NULL;
    o->refs = 1;
    o->host = host;
    o->handle = handle;
    o->size = size;
    return o;
}

static int shm_fd(lobj *o)
{
    int fd = alloc_fd(o, 0);
    if (fd < 0)
        unref(o);
    return fd;
}

/* In memory: room for size bytes (the buffer may not move while it is mapped). */
static int mem_reserve(lobj *o, size_t size)
{
    if (size <= o->cap)
        return 0;
    for (size_t i = 0; i < nmaps; i++)
        if (maps[i].obj == o)
            return fail(EBUSY);
    size_t cap = round_page(size);
    unsigned char *b = aligned_alloc(webby_shm_page_size(), cap);
    if (!b)
        return fail(ENOMEM);
    memset(b, 0, cap);
    if (o->buf)
        memcpy(b, o->buf, o->size);
    free(o->buf);
    o->buf = b;
    o->cap = cap;
    return 0;
}

int webby_shm_create(size_t size)
{
    if (webby_latha() && webby_latha_ops->mem_create) {
        uint32_t h;
        int r = webby_latha_ops->mem_create(size, &h);
        if (r < 0)
            return fail(-r);
        lobj *o = new_shm(1, h, size);
        if (!o) {
            webby_latha_ops->close(h);
            return fail(ENOMEM);
        }
        return shm_fd(o);
    }
    lobj *o = new_shm(0, 0, 0);
    if (!o)
        return fail(ENOMEM);
    if (mem_reserve(o, size) < 0) {
        unref(o);
        return -1;
    }
    o->size = size;
    return shm_fd(o);
}

int webby_is_shm_fd(int fd)
{
    lobj *o = get(fd);
    return o && o->kind == K_SHM;
}

static lobj *get_shm(int fd)
{
    lobj *o = get(fd);
    if (!o || o->kind != K_SHM) {
        errno = EBADF;
        return NULL;
    }
    return o;
}

ssize_t webby_shm_size(int fd)
{
    lobj *o = get_shm(fd);
    return o ? (ssize_t)o->size : -1;
}

int webby_shm_resize(int fd, size_t size)
{
    lobj *o = get_shm(fd);
    if (!o)
        return -1;
    if (o->host) {
        int r = webby_latha_ops->mem_resize(o->handle, size);
        if (r < 0)
            return fail(-r);
        if (o->view && o->view_len < size) {
            host_unmap(o->view, o->view_len);
            o->view = NULL;
        }
    } else {
        if (mem_reserve(o, size) < 0)
            return -1;
        if (size < o->size)
            memset(o->buf + size, 0, o->size - size);
    }
    o->size = size;
    return 0;
}

void *webby_shm_map(int fd, size_t offset, size_t length)
{
    lobj *o = get_shm(fd);
    if (!o)
        return NULL;
    if (offset % webby_shm_page_size()) {
        errno = EINVAL;
        return NULL;
    }
    if (o->host) {
        void *at = host_map(o->handle, offset, length, o->size);
        if (at && add_map(at, length, NULL) < 0) {
            host_unmap(at, length);
            errno = ENOMEM;
            return NULL;
        }
        return at;
    }
    /* Like a file mapping: bytes past the object's end are there (zero) up to the page end. */
    if (mem_reserve(o, offset + length) < 0)
        return NULL;
    void *at = o->buf + offset;
    if (add_map(at, length, o) < 0) {
        errno = ENOMEM;
        return NULL;
    }
    o->refs++;
    return at;
}

int webby_shm_unmap(void *addr, size_t length)
{
    (void)length;
    for (size_t i = 0; i < nmaps; i++) {
        if (maps[i].addr != addr)
            continue;
        lmap m = maps[i];
        maps[i] = maps[--nmaps];
        if (m.obj)
            unref(m.obj);
        else
            host_unmap(m.addr, m.len);
        return 0;
    }
    return fail(EINVAL);
}

/* The object's bytes for read/write: in memory its buffer, on the host a mapping of all of it kept for this. */
static unsigned char *shm_bytes(lobj *o)
{
    if (!o->host)
        return o->buf;
    if (!o->view || o->view_len < o->size) {
        if (o->view)
            host_unmap(o->view, o->view_len);
        o->view = host_map(o->handle, 0, o->size, o->size);
        o->view_len = o->view ? o->size : 0;
    }
    return o->view;
}

static ssize_t shm_read(lobj *o, void *buffer, size_t length)
{
    if (o->pos >= o->size)
        return 0;
    size_t n = o->size - o->pos < length ? o->size - o->pos : length;
    unsigned char *b = shm_bytes(o);
    if (!b)
        return -1;
    memcpy(buffer, b + o->pos, n);
    o->pos += n;
    return (ssize_t)n;
}

static ssize_t shm_write(lobj *o, const void *buffer, size_t length)
{
    if (o->pos + length > o->size) {
        if (o->host ? webby_latha_ops->mem_resize(o->handle, o->pos + length) < 0 : mem_reserve(o, o->pos + length) < 0)
            return fail(ENOSPC);
        o->size = o->pos + length;
    }
    unsigned char *b = shm_bytes(o);
    if (!b)
        return -1;
    memcpy(b + o->pos, buffer, length);
    o->pos += length;
    return (ssize_t)length;
}

off_t webby_shm_lseek(int fd, off_t offset, int whence)
{
    lobj *o = get_shm(fd);
    if (!o)
        return -1;
    off_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (off_t)o->pos : (off_t)o->size;
    if (base + offset < 0)
        return fail(EINVAL);
    o->pos = (size_t)(base + offset);
    return (off_t)o->pos;
}

/* A regular file going to another instance: a new host object with a copy of its bytes. 0 and *h, or -1. */
/* libc's fstat. Weak: a program linked without -Wl,--wrap=fstat (the deps' tools, which only pull this file in through
 * kill or posix_spawn) has no __real_fstat, and there plain fstat is libc's. */
int __real_fstat(int fd, struct stat *st) __attribute__((weak));
static int real_fstat(int fd, struct stat *st) { return __real_fstat ? __real_fstat(fd, st) : fstat(fd, st); }
static int snapshot_file(int fd, uint32_t *h)
{
    struct stat st;
    if (real_fstat(fd, &st) < 0 || !S_ISREG(st.st_mode))
        return fail(EOPNOTSUPP);
    size_t size = (size_t)st.st_size;
    int r = webby_latha_ops->mem_create(size, h);
    if (r < 0)
        return fail(-r);
    if (size) {
        void *at = host_map(*h, 0, size, size);
        if (!at) {
            webby_latha_ops->close(*h);
            return -1;
        }
        size_t done = 0;
        while (done < size) {
            ssize_t n = pread(fd, (char *)at + done, size - done, (off_t)done);
            if (n <= 0)
                break;
            done += (size_t)n;
        }
        host_unmap(at, size);
    }
    return 0;
}

int webby_local_peer_in_memory(int fd)
{
    lobj *o = get(fd);
    return o && o->kind == K_MEM && o->peer;
}

int webby_local_close(int fd)
{
    lobj *o = get(fd);
    if (!o)
        return fail(EBADF);
    ftab[fd - WEBBY_LOCAL_FD_BASE].obj = NULL;
    unref(o);
    return 0;
}

/* ---- writing ---- */

ssize_t webby_local_sendmsg(int fd, const struct msghdr *message, int flags)
{
    (void)flags;
    lobj *o = get(fd);
    if (!o)
        return fail(EBADF);
    if (o->kind == K_SHM)
        return fail(ENOTSOCK);
    if (o->kind == K_LATHA && o->moved)
        return fail(EBADF);
    if (o->wr_shut)
        return fail(EPIPE);
    if (o->kind == K_MEM && !o->peer)
        return fail(EPIPE);

    size_t total = 0;
    for (int i = 0; i < (int)message->msg_iovlen; i++)
        total += message->msg_iov[i].iov_len;

    const int *passed = NULL;
    size_t npassed = 0;
    if (message->msg_control && message->msg_controllen >= sizeof(struct cmsghdr)) {
        const struct cmsghdr *c = (const struct cmsghdr *)message->msg_control;
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && c->cmsg_len >= CMSG_LEN(0)) {
            passed = (const int *)CMSG_DATA(c);
            npassed = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
        }
    }

    lmsg *m = calloc(1, sizeof *m);
    if (!m)
        return fail(ENOMEM);
    m->data = malloc(total ? total : 1);
    m->ents = npassed ? calloc(npassed, sizeof *m->ents) : NULL;
    if (!m->data || (npassed && !m->ents)) {
        free_msg(m, 0);
        return fail(ENOMEM);
    }
    for (int i = 0; i < (int)message->msg_iovlen; i++) {
        memcpy(m->data + m->len, message->msg_iov[i].iov_base, message->msg_iov[i].iov_len);
        m->len += message->msg_iov[i].iov_len;
    }

    if (o->kind == K_LATHA) {
        uint32_t hs[256];
        uint8_t copy[256]; /* hs[i] is a new handle of ours (a dup or a file's copy) to give up if sending fails */
        if (npassed > 256) {
            free_msg(m, 0);
            return fail(EINVAL);
        }
        size_t made = 0;
        int err = 0;
        for (size_t i = 0; i < npassed && !err; i++) {
            lobj *p = get(passed[i]);
            copy[i] = 1;
            /* Channel endpoints move; memory objects go as a new handle to the same object; files as a copy. */
            if (p && p->kind == K_SHM && p->host) {
                int r = webby_latha_ops->mem_dup(p->handle, &hs[i]);
                if (r < 0)
                    err = -r;
            } else if (!p && !WEBBY_IS_LOCAL_FD(passed[i]) && webby_latha_ops->mem_create) {
                if (snapshot_file(passed[i], &hs[i]) < 0)
                    err = errno;
            } else if (p && p->kind == K_LATHA && !p->moved && p != o) {
                hs[i] = p->handle;
                copy[i] = 0;
            } else {
                err = EOPNOTSUPP;
            }
            if (!err)
                made = i + 1;
        }
        int r = err ? -err : webby_latha_ops->send(o->handle, m->data, m->len, hs, npassed);
        free_msg(m, 0);
        if (r < 0) {
            for (size_t i = 0; i < made; i++)
                if (copy[i])
                    webby_latha_ops->close(hs[i]);
            return fail(-r == EBADF ? EPIPE : -r);
        }
        for (size_t i = 0; i < npassed; i++)
            if (!copy[i])
                get(passed[i])->moved = 1;
        return (ssize_t)total;
    }

    for (size_t i = 0; i < npassed; i++) {
        lobj *p = get(passed[i]);
        if (p) {
            p->refs++;
            m->ents[i].kind = E_LOCAL;
            m->ents[i].obj = p;
        } else {
            share_fd(passed[i]);
            m->ents[i].kind = E_FOREIGN;
            m->ents[i].fd = passed[i];
        }
    }
    m->nents = npassed;
    enqueue(o->peer, m);
    return (ssize_t)total;
}

ssize_t webby_local_write(int fd, const void *buffer, size_t length, int flags)
{
    lobj *so = get(fd);
    if (so && so->kind == K_SHM)
        return shm_write(so, buffer, length);
    struct iovec iov = { (void *)buffer, length };
    struct msghdr message = { 0 };
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    return webby_local_sendmsg(fd, &message, flags);
}

/* ---- reading ---- */

/* Bring a channel's next message into the queue. 0, or a negative errno (-EAGAIN: nothing yet). */
static int latha_fetch(lobj *o, int timeout_ms)
{
    void *data = NULL;
    uint32_t *hs = NULL;
    size_t len = 0, nh = 0;
    int r = webby_latha_ops->recv(o->handle, timeout_ms, &data, &len, &hs, &nh);
    if (r == -EPIPE) {
        o->peer_gone = 1;
        return 0;
    }
    if (r < 0)
        return r;
    lmsg *m = calloc(1, sizeof *m);
    if (!m || (nh && !(m->ents = calloc(nh, sizeof *m->ents)))) {
        for (size_t i = 0; i < nh; i++)
            webby_latha_ops->close(hs[i]);
        free(m);
        free(data);
        free(hs);
        return -ENOMEM;
    }
    m->data = data;
    m->len = len;
    for (size_t i = 0; i < nh; i++) {
        m->ents[i].kind = E_HANDLE;
        m->ents[i].handle = hs[i];
    }
    m->nents = nh;
    free(hs);
    enqueue(o, m);
    return 0;
}

/* The descriptor for a passed entry, taking it over. */
static int receive_entry(lent *e)
{
    switch (e->kind) {
    case E_LOCAL: {
        int fd = alloc_fd(e->obj, 0);
        if (fd < 0)
            unref(e->obj);
        return fd;
    }
    case E_FOREIGN:
        return e->fd;
    default:
        if (webby_latha_ops->is_memory && webby_latha_ops->is_memory(e->handle)) {
            uint64_t size = 0;
            webby_latha_ops->mem_size(e->handle, &size);
            lobj *o = new_shm(1, e->handle, (size_t)size);
            if (!o) {
                webby_latha_ops->close(e->handle);
                return fail(ENOMEM);
            }
            return shm_fd(o);
        }
        return webby_local_from_latha(e->handle);
    }
}

ssize_t webby_local_recvmsg(int fd, struct msghdr *message, int flags)
{
    lobj *o = get(fd);
    if (!o)
        return fail(EBADF);
    if (o->kind == K_SHM)
        return fail(ENOTSOCK);
    if (o->kind == K_LATHA && o->moved)
        return fail(EBADF);
    int nonblock = ftab[fd - WEBBY_LOCAL_FD_BASE].nonblock || (flags & MSG_DONTWAIT);
    message->msg_flags = 0;
    if (o->rd_shut)
        return 0;

    while (!o->head) {
        if (o->peer_gone)
            break;
        if (o->kind == K_MEM)
            return fail(EAGAIN);
        int r = latha_fetch(o, nonblock ? 0 : -1);
        if (r == -EAGAIN)
            return fail(EAGAIN);
        if (r < 0)
            return fail(-r);
    }
    lmsg *m = o->head;
    if (!m) {
        if (message->msg_controllen)
            message->msg_controllen = 0;
        return 0; /* EOF */
    }

    size_t copied = 0;
    for (int i = 0; i < (int)message->msg_iovlen && m->off + copied < m->len; i++) {
        size_t n = m->len - m->off - copied;
        if (n > message->msg_iov[i].iov_len)
            n = message->msg_iov[i].iov_len;
        memcpy(message->msg_iov[i].iov_base, m->data + m->off + copied, n);
        copied += n;
    }
    if (flags & MSG_PEEK) {
        message->msg_controllen = 0;
        return (ssize_t)copied;
    }

    size_t room = 0;
    struct cmsghdr *c = NULL;
    if (message->msg_control && message->msg_controllen >= CMSG_LEN(sizeof(int))) {
        c = (struct cmsghdr *)message->msg_control;
        room = (message->msg_controllen - CMSG_LEN(0)) / sizeof(int);
    }
    size_t given = 0;
    if (m->nents) {
        int *out = c ? (int *)CMSG_DATA(c) : NULL;
        for (size_t i = 0; i < m->nents; i++) {
            if (given < room) {
                int nfd = receive_entry(&m->ents[i]);
                if (nfd >= 0)
                    out[given++] = nfd;
            } else {
                drop_entry(&m->ents[i]);
                message->msg_flags |= MSG_CTRUNC;
            }
        }
        m->nents = 0;
    }
    if (c && given) {
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(given * sizeof(int));
        message->msg_controllen = CMSG_SPACE(given * sizeof(int));
    } else {
        message->msg_controllen = 0;
    }

    m->off += copied;
    /* A datagram or record is read whole: what did not fit is dropped. */
    if (o->type != SOCK_STREAM && m->off < m->len) {
        message->msg_flags |= MSG_TRUNC;
        m->off = m->len;
    }
    if (m->off >= m->len) {
        o->head = m->next;
        if (!o->head)
            o->tail = NULL;
        free_msg(m, 0);
    }
    return (ssize_t)copied;
}

ssize_t webby_local_read(int fd, void *buffer, size_t length, int flags)
{
    lobj *so = get(fd);
    if (so && so->kind == K_SHM)
        return shm_read(so, buffer, length);
    struct iovec iov = { buffer, length };
    struct msghdr message = { 0 };
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    return webby_local_recvmsg(fd, &message, flags);
}

/* ---- the rest of a socket's calls ---- */

int webby_local_shutdown(int fd, int how)
{
    lobj *o = get(fd);
    if (!o)
        return fail(EBADF);
    if (how == SHUT_RD || how == SHUT_RDWR)
        o->rd_shut = 1;
    if (how == SHUT_WR || how == SHUT_RDWR) {
        o->wr_shut = 1;
        if (o->kind == K_MEM && o->peer)
            o->peer->peer_gone = 1; /* the peer reads what is queued, then EOF */
    }
    return 0;
}

static int put_int(void *value, socklen_t *len, int v)
{
    if (!value || !len || *len < sizeof(int))
        return fail(EINVAL);
    memcpy(value, &v, sizeof v);
    *len = sizeof v;
    return 0;
}

int webby_local_getsockopt(int fd, int level, int name, void *value, socklen_t *len)
{
    lobj *o = get(fd);
    if (!o)
        return fail(EBADF);
    if (level == SOL_SOCKET && name == SO_TYPE)
        return put_int(value, len, o->type);
    if (level == SOL_SOCKET && name == SO_PEERCRED)
        return fail(ENOPROTOOPT);
    if (level == SOL_SOCKET && (name == SO_SNDBUF || name == SO_RCVBUF))
        return put_int(value, len, 128 * 1024);
    return put_int(value, len, 0);
}

int webby_local_fcntl(int fd, int cmd, int arg)
{
    lobj *o = get(fd);
    if (!o)
        return fail(EBADF);
    int i = fd - WEBBY_LOCAL_FD_BASE;
    switch (cmd) {
    case F_GETFL:
        return O_RDWR | (ftab[i].nonblock ? O_NONBLOCK : 0);
    case F_SETFL:
        ftab[i].nonblock = (arg & O_NONBLOCK) != 0;
        return 0;
    case F_GETFD:
        return ftab[i].cloexec ? FD_CLOEXEC : 0;
    case F_SETFD:
        ftab[i].cloexec = (arg & FD_CLOEXEC) != 0;
        return 0;
    case F_DUPFD:
    case F_DUPFD_CLOEXEC: {
        int nfd = alloc_fd(o, arg);
        if (nfd < 0)
            return -1;
        o->refs++;
        ftab[nfd - WEBBY_LOCAL_FD_BASE].nonblock = ftab[i].nonblock;
        ftab[nfd - WEBBY_LOCAL_FD_BASE].cloexec = cmd == F_DUPFD_CLOEXEC;
        return nfd;
    }
    default:
        return fail(EINVAL);
    }
}

int webby_local_ioctl(int fd, int request, void *arg)
{
    lobj *o = get(fd);
    if (!o)
        return fail(EBADF);
    if (request == FIONBIO) {
        ftab[fd - WEBBY_LOCAL_FD_BASE].nonblock = arg && *(int *)arg;
        return 0;
    }
    if (request == FIONREAD) {
        if (o->kind == K_LATHA && !o->head && !o->peer_gone && !o->moved)
            (void)latha_fetch(o, 0);
        int n = 0;
        for (lmsg *m = o->head; m; m = m->next)
            n += (int)(m->len - m->off);
        *(int *)arg = n;
        return 0;
    }
    return fail(ENOTTY);
}

int webby_local_name(int fd, struct sockaddr *addr, socklen_t *len)
{
    if (!get(fd))
        return fail(EBADF);
    if (addr && len && *len >= sizeof(sa_family_t)) {
        memset(addr, 0, *len);
        addr->sa_family = AF_UNIX;
        *len = sizeof(sa_family_t);
    }
    return 0;
}

int fstat(int fd, struct stat *st);
int __wrap_fstat(int fd, struct stat *st)
{
    lobj *o = get(fd);
    if (o && o->kind == K_SHM) {
        memset(st, 0, sizeof *st);
        st->st_mode = S_IFREG | 0600;
        st->st_nlink = 1;
        st->st_ino = (ino_t)fd;
        st->st_size = (off_t)o->size;
        st->st_blksize = (blksize_t)webby_shm_page_size();
        return 0;
    }
    if (o || (webby_net_ops && fd >= WEBBY_NET_FD_BASE && fd < WEBBY_NET_FD_END)) {
        memset(st, 0, sizeof *st);
        st->st_mode = S_IFSOCK | 0600;
        st->st_nlink = 1;
        st->st_ino = (ino_t)fd;
        return 0;
    }
    return real_fstat(fd, st);
}

ssize_t sendmsg(int fd, const struct msghdr *message, int flags)
{
    if (!WEBBY_IS_LOCAL_FD(fd))
        return fail(ENOTSUP); /* no descriptor passing over wasi:sockets */
    return webby_local_sendmsg(fd, message, flags);
}

ssize_t recvmsg(int fd, struct msghdr *message, int flags)
{
    if (!WEBBY_IS_LOCAL_FD(fd))
        return fail(ENOTSUP);
    return webby_local_recvmsg(fd, message, flags);
}

/* ---- poll ---- */

static int readable_now(lobj *o)
{
    return o->head || o->peer_gone || o->rd_shut || (o->kind == K_LATHA && o->moved);
}

static short local_revents(lobj *o, short events)
{
    short r = 0;
    if (o->kind == K_SHM)
        return events & (POLLIN | POLLOUT);
    if ((events & POLLIN) && readable_now(o))
        r |= POLLIN;
    int peer_alive = o->kind == K_MEM ? o->peer != NULL : !o->peer_gone;
    if ((events & POLLOUT) && peer_alive && !o->wr_shut)
        r |= POLLOUT;
    if (!peer_alive && !o->head)
        r |= POLLHUP;
    if (o->kind == K_LATHA && o->moved)
        r |= POLLNVAL;
    return r;
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* How long the channel slices of a mixed wait are, in ms. */
#define MIXED_SLICE_MS 2

int webby_local_poll(struct pollfd *fds, nfds_t n, int timeout, int (*rest_poll)(struct pollfd *, nfds_t, int))
{
    struct pollfd rest_small[16], *rest = rest_small;
    nfds_t rest_idx_small[16], *rest_idx = rest_idx_small;
    uint32_t hs_small[16], *hs = hs_small;
    nfds_t hidx_small[16], *hidx = hidx_small;
    uint8_t ready_small[16], *ready = ready_small;
    if (n > 16) {
        rest = malloc(n * sizeof *rest);
        rest_idx = malloc(n * sizeof *rest_idx);
        hs = malloc(n * sizeof *hs);
        hidx = malloc(n * sizeof *hidx);
        ready = malloc(n);
        if (!rest || !rest_idx || !hs || !hidx || !ready)
            abort();
    }

    nfds_t nrest = 0, nh = 0;
    int count = 0;
    for (nfds_t i = 0; i < n; i++) {
        fds[i].revents = 0;
        if (fds[i].fd < 0)
            continue;
        lobj *o = get(fds[i].fd);
        if (!o) {
            if (WEBBY_IS_LOCAL_FD(fds[i].fd)) {
                fds[i].revents = POLLNVAL;
                count++;
                continue;
            }
            rest[nrest] = fds[i];
            rest_idx[nrest++] = i;
            continue;
        }
        fds[i].revents = local_revents(o, fds[i].events);
        if (fds[i].revents)
            count++;
        else if (o->kind == K_LATHA && (fds[i].events & POLLIN)) {
            hs[nh] = o->handle;
            hidx[nh++] = i;
        }
    }

    int64_t deadline = timeout > 0 ? now_ms() + timeout : 0;
    for (;;) {
        int wait = count ? 0 : timeout;
        int got = 0;
        if (nh) {
            int slice = wait;
            if (nrest && (slice < 0 || slice > MIXED_SLICE_MS))
                slice = MIXED_SLICE_MS;
            int r = webby_latha_ops->wait(hs, nh, ready, slice);
            for (nfds_t k = 0; r > 0 && k < nh; k++) {
                if (ready[k]) {
                    fds[hidx[k]].revents |= POLLIN;
                    got++;
                }
            }
        }
        if (nrest) {
            int rest_wait = (nh || count || got) ? 0 : wait;
            int r = rest_poll(rest, nrest, rest_wait);
            if (r < 0) {
                count = -1;
                break;
            }
            for (nfds_t k = 0; k < nrest; k++) {
                fds[rest_idx[k]].revents = rest[k].revents;
                if (rest[k].revents)
                    got++;
            }
        } else if (!nh && !count && wait != 0) {
            /* Only in-memory sockets, none ready: nothing in this instance can change them while it waits. */
            struct timespec ts = { wait < 0 ? 3600 : wait / 1000, wait < 0 ? 0 : (wait % 1000) * 1000000L };
            nanosleep(&ts, NULL);
            if (wait < 0)
                continue;
        }
        count += got;
        if (count || timeout == 0)
            break;
        if (timeout > 0 && now_ms() >= deadline)
            break;
        if (timeout > 0 && !nh && !nrest)
            break;
        if (timeout > 0 && nh && !nrest)
            break; /* the channel wait already took the whole timeout */
        if (timeout > 0) {
            int left = (int)(deadline - now_ms());
            if (left <= 0)
                break;
            timeout = left;
        }
    }

    if (n > 16) {
        free(rest);
        free(rest_idx);
        free(hs);
        free(hidx);
        free(ready);
    }
    return count;
}

/* ---- processes ---- */

#include <spawn.h>
#include <sys/wait.h>

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *a)
{
    a->count = 0;
    a->actions = NULL;
    return 0;
}

int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *a)
{
    free(a->actions);
    a->actions = NULL;
    a->count = 0;
    return 0;
}

enum { A_DUP2, A_OTHER };

static int add_action(posix_spawn_file_actions_t *a, int kind, int fd, int src)
{
    void *grown = realloc(a->actions, (size_t)(a->count + 1) * sizeof *a->actions);
    if (!grown)
        return ENOMEM;
    a->actions = grown;
    a->actions[a->count].kind = kind;
    a->actions[a->count].fd = fd;
    a->actions[a->count].src = src;
    a->count++;
    return 0;
}

int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *a, int fd, int new_fd) { return add_action(a, A_DUP2, new_fd, fd); }
/* A child instance starts with the host's stdio and the descriptors we give it, so these change nothing. */
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *a, int fd, char const *path, int flags, mode_t mode)
{
    (void)path; (void)flags; (void)mode;
    return add_action(a, A_OTHER, fd, -1);
}
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *a, int fd) { return add_action(a, A_OTHER, fd, -1); }
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *a, char const *path) { (void)path; return add_action(a, A_OTHER, -1, -1); }

/* "NAME=" entries of envp, minus our bootstrap variable, plus extra. A NUL-separated list in *out. */
#define SPAWN_FDS_VAR "WEBBY_SPAWN_FDS"

static int spawn_common(pid_t *pid, char const *path, posix_spawn_file_actions_t const *actions, char *const argv[],
    char *const envp[])
{
    const struct webby_latha_ops *l = webby_latha();
    if (!l || !l->spawn_env)
        return ENOSYS;

    /* The program: X means X.wasm. */
    size_t plen = strlen(path);
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    char *prog = malloc(plen + 6);
    if (!prog)
        return ENOMEM;
    memcpy(prog, path, plen + 1);
    if (!strchr(base, '.'))
        memcpy(prog + plen, ".wasm", 6);

    /* The descriptors the child gets: handles we give up (or new ones: dups of memory objects, files' copies). */
    int n = actions ? actions->count : 0;
    uint32_t *hs = calloc((size_t)(n ? n : 1), sizeof *hs);
    int32_t *targets = calloc((size_t)(n ? n : 1), sizeof *targets);
    uint8_t *copy = calloc((size_t)(n ? n : 1), 1);
    int *moved_fd = calloc((size_t)(n ? n : 1), sizeof *moved_fd);
    int count = 0, err = 0;
    if (!hs || !targets || !copy || !moved_fd)
        err = ENOMEM;
    for (int i = 0; i < n && !err; i++) {
        webby_spawn_action const *a = &actions->actions[i];
        if (a->kind != A_DUP2)
            continue;
        if (a->fd >= 0 && a->fd <= 2) {
            /* The child's stdio is the host's. */
            continue;
        }
        lobj *p = get(a->src);
        copy[count] = 1;
        moved_fd[count] = -1;
        if (p && p->kind == K_LATHA && !p->moved) {
            hs[count] = p->handle;
            copy[count] = 0;
            moved_fd[count] = a->src;
        } else if (p && p->kind == K_SHM && p->host) {
            int r = l->mem_dup(p->handle, &hs[count]);
            if (r < 0)
                err = -r;
        } else if (!p && !WEBBY_IS_LOCAL_FD(a->src)) {
            if (snapshot_file(a->src, &hs[count]) < 0)
                err = errno;
        } else {
            err = EOPNOTSUPP; /* an in-memory socket: it cannot leave this instance */
        }
        if (!err)
            targets[count++] = a->fd;
    }

    /* The environment: envp, and which descriptors the first message brings. */
    size_t esize = 1;
    for (char *const *e = envp; e && *e; e++)
        esize += strlen(*e) + 1;
    esize += strlen(SPAWN_FDS_VAR) + 2 + (size_t)count * 12;
    size_t asize = 1;
    for (char *const *a = argv; a && *a; a++)
        asize += strlen(*a) + 1;
    char *env = malloc(esize), *args = malloc(asize);
    if (!env || !args)
        err = err ? err : ENOMEM;
    uint32_t child_pid = 0, channel = 0;
    if (!err) {
        size_t off = 0;
        for (char *const *e = envp; e && *e; e++) {
            if (!strncmp(*e, SPAWN_FDS_VAR "=", sizeof SPAWN_FDS_VAR))
                continue;
            size_t len = strlen(*e) + 1;
            memcpy(env + off, *e, len);
            off += len;
        }
        off += (size_t)sprintf(env + off, SPAWN_FDS_VAR "=%d", count) + 1;
        size_t aoff = 0;
        for (char *const *a = argv; a && *a; a++) {
            size_t len = strlen(*a) + 1;
            memcpy(args + aoff, *a, len);
            aoff += len;
        }
        int r = l->spawn_env(prog, args, aoff, env, off, &child_pid, &channel);
        if (r < 0)
            err = -r;
    }
    if (!err) {
        /* The first message on the child's parent channel: where each descriptor goes. */
        int r = l->send(channel, targets, (size_t)count * sizeof *targets, hs, (size_t)count);
        l->close(channel);
        if (r < 0)
            err = EPIPE;
        else
            for (int i = 0; i < count; i++)
                if (moved_fd[i] >= 0)
                    get(moved_fd[i])->moved = 1;
    }
    if (err)
        for (int i = 0; i < count; i++)
            if (copy[i])
                l->close(hs[i]);
    if (!err && pid)
        *pid = (pid_t)child_pid;
    free(prog);
    free(hs);
    free(targets);
    free(copy);
    free(moved_fd);
    free(env);
    free(args);
    return err;
}

int posix_spawn(pid_t *pid, char const *path, posix_spawn_file_actions_t const *actions,
    posix_spawnattr_t const *attributes, char *const argv[], char *const envp[])
{
    (void)attributes;
    return spawn_common(pid, path, actions, argv, envp);
}

int posix_spawnp(pid_t *pid, char const *file, posix_spawn_file_actions_t const *actions,
    posix_spawnattr_t const *attributes, char *const argv[], char *const envp[])
{
    (void)attributes;
    return spawn_common(pid, file, actions, argv, envp);
}

void webby_spawn_bootstrap(void)
{
    const char *v = getenv(SPAWN_FDS_VAR);
    if (!v || !webby_latha())
        return;
    unsetenv(SPAWN_FDS_VAR);
    uint32_t h;
    if (webby_latha_ops->parent(&h) < 0)
        return;
    void *data = NULL;
    uint32_t *hs = NULL;
    size_t len = 0, nh = 0;
    int r = webby_latha_ops->recv(h, -1, &data, &len, &hs, &nh);
    webby_latha_ops->close(h);
    if (r < 0)
        return;
    int32_t *targets = data;
    for (size_t i = 0; i < nh; i++) {
        int fd = i < len / sizeof *targets ? targets[i] : -1;
        lobj *o;
        if (webby_latha_ops->is_memory && webby_latha_ops->is_memory(hs[i])) {
            uint64_t size = 0;
            webby_latha_ops->mem_size(hs[i], &size);
            o = new_shm(1, hs[i], (size_t)size);
        } else {
            o = new_obj(K_LATHA, SOCK_STREAM);
            if (o) {
                o->handle = hs[i];
                o->refs = 1;
            }
        }
        if (!o || !WEBBY_IS_LOCAL_FD(fd) || ftab[fd - WEBBY_LOCAL_FD_BASE].obj) {
            fprintf(stderr, "webby: spawned with a descriptor %d that cannot be put in place\n", fd);
            if (o)
                unref(o);
            else
                webby_latha_ops->close(hs[i]);
            continue;
        }
        ftab[fd - WEBBY_LOCAL_FD_BASE].obj = o;
        ftab[fd - WEBBY_LOCAL_FD_BASE].nonblock = 0;
        ftab[fd - WEBBY_LOCAL_FD_BASE].cloexec = 0;
    }
    free(data);
    free(hs);
}

pid_t waitpid(pid_t pid, int *status, int options)
{
    if (!webby_latha() || pid <= 0)
        return fail(ECHILD);
    int code = 0;
    int r = webby_latha_ops->wait_exit((uint32_t)pid, (options & WNOHANG) ? 0 : -1, &code);
    if (r == -EAGAIN)
        return (options & WNOHANG) ? 0 : fail(ECHILD);
    if (r < 0)
        return fail(ECHILD);
    if (status)
        *status = code >= 128 ? (code - 128) & 0x7f : (code & 0xff) << 8;
    return pid;
}

pid_t wait(int *status)
{
    (void)status;
    return fail(ECHILD);
}

int webby_local_kill(pid_t pid, int signal)
{
    if (!webby_latha() || pid <= 0)
        return fail(ESRCH);
    if (signal != 0)
        webby_latha_ops->kill((uint32_t)pid);
    return 0;
}
