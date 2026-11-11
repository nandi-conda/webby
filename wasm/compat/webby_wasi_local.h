/* Local sockets for a single-threaded WASI program (webby_wasi_local.c): socketpair() (AF_UNIX, SOCK_STREAM or
 * SOCK_SEQPACKET), pipe(), and descriptor passing with sendmsg()/recvmsg() SCM_RIGHTS, as LibIPC's TransportSocket
 * uses them. An endpoint is either in this instance's memory, or, when a program links the latha:proc backend
 * (libwebby_wasi_latha.a, webby_wasi_latha.c), a latha:proc channel endpoint, which can be handed to another wasm
 * instance (a child process) in a message or at spawn. */
#pragma once
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Local socket descriptors start here, above the wasi:sockets ones (WEBBY_NET_FD_BASE). */
#define WEBBY_LOCAL_FD_BASE 0x200000
#define WEBBY_LOCAL_FD_END (WEBBY_LOCAL_FD_BASE + 4096)
#define WEBBY_IS_LOCAL_FD(fd) ((fd) >= WEBBY_LOCAL_FD_BASE && (fd) < WEBBY_LOCAL_FD_END)

/* What the latha:proc backend provides. Errors are negative errno values: recv gives -EAGAIN when nothing came in
 * time, -EPIPE when the peer is gone and nothing is queued. recv hands back malloc()ed buffers. */
struct webby_latha_ops {
    int (*pair)(uint32_t out[2]);
    int (*send)(uint32_t h, const void *data, size_t len, const uint32_t *handles, size_t nhandles);
    int (*recv)(uint32_t h, int timeout_ms, void **data, size_t *len, uint32_t **handles, size_t *nhandles);
    /* ready[i] = 1 for the endpoints with a message or a closed peer; returns how many. */
    int (*wait)(const uint32_t *hs, size_t n, uint8_t *ready, int timeout_ms);
    void (*close)(uint32_t h);
    /* The endpoint this instance was started with, once; -EBADF if none. */
    int (*parent)(uint32_t *h);
    /* Start a wasm program; argv[0] is its name. *channel is our end of the child's parent() channel. */
    int (*spawn)(const char *path, char *const argv[], uint32_t *pid, uint32_t *channel);
    /* spawn with args (alen bytes of NUL-terminated strings) and env ("NAME=value", the same way) (latha-gui 0.4.0+). */
    int (*spawn_env)(const char *path, const char *args, size_t alen, const char *env, size_t elen, uint32_t *pid,
        uint32_t *channel);
    /* The child's exit code into *code once it ended; -EAGAIN until then. */
    int (*wait_exit)(uint32_t pid, int timeout_ms, int *code);
    void (*kill)(uint32_t pid);
    /* Shared memory (latha:proc memory, latha-gui 0.4.0+). Handles close with close(). */
    int (*mem_create)(uint64_t size, uint32_t *h);
    int (*mem_dup)(uint32_t h, uint32_t *out);
    int (*mem_size)(uint32_t h, uint64_t *size);
    int (*mem_resize)(uint32_t h, uint64_t size);
    /* [addr, addr + len) of our memory becomes the object's bytes from offset; all page aligned. */
    int (*mem_map)(uint32_t h, uint64_t offset, void *addr, size_t len);
    int (*mem_unmap)(void *addr, size_t len);
    size_t (*page_size)(void);
    int (*is_memory)(uint32_t h);
};

/* The latha:proc backend, or NULL when the program does not link it (endpoints are then in memory only). */
const struct webby_latha_ops *webby_latha(void);
/* Defined by the backend (libwebby_wasi_latha.a); weak here. */
const struct webby_latha_ops *webby_latha_backend_ops(void);

/* A local socket descriptor for a latha:proc endpoint (the descriptor owns it). */
int webby_local_from_latha(uint32_t handle);
/* The channel this instance was started with as a local socket descriptor, once; -1 if there is none. */
int webby_local_parent_fd(void);
/* Spawn a wasm program with latha:proc; *fd is a local socket connected to the child's webby_local_parent_fd().
 * 0, or -1 with errno (ENOSYS without the backend). */
int webby_local_spawn(const char *path, char *const argv[], uint32_t *pid, int *fd);

/* Shared memory objects (what memfd/shm objects are on Unix; Core::AnonymousBuffer's backing). A descriptor from
 * the local range. With the latha:proc backend it is a host memory object that several instances map, and passing
 * it over a channel (SCM_RIGHTS) passes a handle to the same object; in memory, every mapping of one object is the
 * same bytes. read/write/fstat (S_IFREG, st_size) work on it too. A regular file passed to another instance arrives
 * as one of these, holding a copy of the file's bytes. */
int webby_shm_create(size_t size);
int webby_is_shm_fd(int fd);
/* The object's size, or -1 with errno. */
ssize_t webby_shm_size(int fd);
int webby_shm_resize(int fd, size_t size);
/* Map [offset, offset + length) of the object (offset a multiple of webby_shm_page_size()). NULL with errno on failure. */
void *webby_shm_map(int fd, size_t offset, size_t length);
/* Undo webby_shm_map; -1 with EINVAL if addr is not the start of such a mapping. */
int webby_shm_unmap(void *addr, size_t length);
size_t webby_shm_page_size(void);
off_t webby_shm_lseek(int fd, off_t offset, int whence);

/* Processes (with the latha:proc backend): posix_spawn() starts a wasm program as a child instance. The path gets
 * ".wasm" if it has no extension; a relative one is relative to our own module's directory. The child gets the
 * descriptors the file actions dup2() into place (channel endpoints move, memory objects are shared, regular files
 * go as copies) under the same numbers, and the environment we pass. waitpid() and kill() reach it by its pid.
 * webby_spawn_bootstrap() puts a spawned child's descriptors in place; LibMain calls it before main. */
void webby_spawn_bootstrap(void);
int webby_local_kill(pid_t pid, int signal);

/* 1 if fd is a local socket whose peer is in this instance's memory (so only this thread can make it readable). */
int webby_local_peer_in_memory(int fd);

/* The libc entry points, for webby_wasi_net_wrap.c and webby_wasi_net.c. */
int webby_local_close(int fd);
ssize_t webby_local_read(int fd, void *buffer, size_t length, int flags);
ssize_t webby_local_write(int fd, const void *buffer, size_t length, int flags);
ssize_t webby_local_sendmsg(int fd, const struct msghdr *message, int flags);
ssize_t webby_local_recvmsg(int fd, struct msghdr *message, int flags);
int webby_local_shutdown(int fd, int how);
int webby_local_getsockopt(int fd, int level, int name, void *value, socklen_t *len);
int webby_local_fcntl(int fd, int cmd, int arg);
int webby_local_ioctl(int fd, int request, void *arg);
int webby_local_name(int fd, struct sockaddr *addr, socklen_t *len);
/* poll() over a set that has local descriptors; rest_poll polls the others. */
int webby_local_poll(struct pollfd *fds, nfds_t n, int timeout, int (*rest_poll)(struct pollfd *, nfds_t, int));

/* A descriptor that is not a local socket (a file, a wasi:sockets socket) passed to this same instance keeps its
 * number: the receiver's copy and the sender's are one descriptor, and close() only closes it with the last one. */
int webby_fd_release_share(int fd); /* 1: another holder remains, so close() must not close it */

#ifdef __cplusplus
}
#endif
