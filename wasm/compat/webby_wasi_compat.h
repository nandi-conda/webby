/* Included before every source of webby's wasm build (cmake/wasi.cmake): POSIX pieces wasm32-wasip1 lacks that
 * Ladybird and its dependencies name. TCP and UDP sockets and name lookup go through wasi:sockets (webby_wasi_net.c);
 * socketpair(), pipe() and SCM_RIGHTS are local sockets inside the instance, or latha:proc channels between instances
 * (webby_wasi_local.c); listen() fails with ENOTSUP; there is one time zone (UTC); threads are wasi-libc's stubs. */
#pragma once
#ifdef __wasi__
#include <stddef.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <pthread.h>
#include <signal.h>
#include <fcntl.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef MSG_DONTWAIT
#    define MSG_DONTWAIT 0x0040
#endif
#ifndef MSG_PEEK
#    define MSG_PEEK 0x0002
#endif
#ifndef MSG_WAITALL
#    define MSG_WAITALL 0x0100
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
/* Local sockets (webby_wasi_local.c) also do records. */
#ifndef SOCK_SEQPACKET
#    define SOCK_SEQPACKET 8
#endif
#ifndef MSG_CTRUNC
#    define MSG_CTRUNC 0x0008
#endif
#ifndef F_DUPFD
#    define F_DUPFD 0
#endif
#ifndef SOL_IP
#    define SOL_IP 0
#endif
/* wasi-libc's poll.h has only the normal-data bits; sockets (webby_wasi_net.c) have no priority data. (poll.h is
 * not included here: CMake's check_function_exists declares poll itself.) */
#ifndef POLLPRI
#    define POLLPRI 0x0004
#endif
#ifndef POLLRDBAND
#    define POLLRDBAND 0x0008
#    define POLLWRBAND 0x0010
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



/* wasi-libc's emulated signal.h has signals and raise() but no siginfo_t, which handler prototypes name. */
#ifndef SA_SIGINFO
typedef struct {
    int si_signo;
    int si_errno;
    int si_code;
    void* si_addr;
} siginfo_t;
#endif

/* Socket pieces wasip1 hides behind wasip2 guards (webby_wasi_net.c handles the ones sockets use). */
#ifndef SO_REUSEADDR
#    define SO_REUSEADDR 2
#    define SO_ERROR 4
#    define SO_SNDBUF 7
#    define SO_RCVBUF 8
#    define SO_KEEPALIVE 9
#    define SO_RCVTIMEO 66
#    define SO_SNDTIMEO 67
#endif
#ifndef SO_REUSEPORT
#    define SO_REUSEPORT 15
#endif
#ifndef SO_PEERCRED
#    define SO_PEERCRED 17
#endif
#ifndef SCM_RIGHTS
#    define SCM_RIGHTS 1
#endif
struct cmsghdr {
    socklen_t cmsg_len;
    int cmsg_level;
    int cmsg_type;
};
#define CMSG_ALIGN(len) (((len) + sizeof(size_t) - 1) & (size_t) ~(sizeof(size_t) - 1))
#define CMSG_DATA(cmsg) ((unsigned char*)(((struct cmsghdr*)(cmsg)) + 1))
#define CMSG_SPACE(len) (CMSG_ALIGN(len) + CMSG_ALIGN(sizeof(struct cmsghdr)))
#define CMSG_LEN(len) (CMSG_ALIGN(sizeof(struct cmsghdr)) + (len))
#define CMSG_FIRSTHDR(mhdr) ((size_t)(mhdr)->msg_controllen >= sizeof(struct cmsghdr) ? (struct cmsghdr*)(mhdr)->msg_control : (struct cmsghdr*)0)
#define CMSG_NXTHDR(mhdr, cmsg) ((struct cmsghdr*)0)
ssize_t sendmsg(int fd, const struct msghdr *message, int flags);
ssize_t recvmsg(int fd, struct msghdr *message, int flags);
ssize_t sendto(int fd, const void *buffer, size_t length, int flags, const struct sockaddr *address, socklen_t address_length);
ssize_t recvfrom(int fd, void *buffer, size_t length, int flags, struct sockaddr *address, socklen_t *address_length);

/* Resource limits: one fixed table, setrlimit accepts anything at or under it. */
typedef unsigned long long rlim_t;
struct rlimit {
    rlim_t rlim_cur;
    rlim_t rlim_max;
};
#define RLIM_INFINITY (~0ULL)
#define RLIMIT_CPU 0
#define RLIMIT_FSIZE 1
#define RLIMIT_DATA 2
#define RLIMIT_STACK 3
#define RLIMIT_CORE 4
#define RLIMIT_NOFILE 7
#define RLIMIT_AS 9
int getrlimit(int resource, struct rlimit *limit);
int setrlimit(int resource, const struct rlimit *limit);

/* Signals: wasi-libc's emulated signal.h has signal() and raise() only. sigaction maps onto signal(); masks are
 * stored and otherwise ignored (there is one thread and no asynchronous delivery). */
#ifndef SA_SIGINFO
#    define SA_NOCLDSTOP 1
#    define SA_NOCLDWAIT 2
#    define SA_SIGINFO 4
#    define SA_ONSTACK 0x08000000
#    define SA_RESTART 0x10000000
#    define SA_NODEFER 0x40000000
#    define SA_RESETHAND 0x80000000
#    define SIG_BLOCK 0
#    define SIG_UNBLOCK 1
#    define SIG_SETMASK 2
struct sigaction {
    union {
        void (*sa_handler)(int);
        void (*sa_sigaction)(int, siginfo_t*, void*);
    };
    sigset_t sa_mask;
    int sa_flags;
};
#endif
int sigaction(int signal, const struct sigaction *action, struct sigaction *old_action);
int sigemptyset(sigset_t *set);
int sigfillset(sigset_t *set);
int sigaddset(sigset_t *set, int signal);
int sigdelset(sigset_t *set, int signal);
int sigismember(const sigset_t *set, int signal);
int sigprocmask(int how, const sigset_t *set, sigset_t *old_set);
int pthread_sigmask(int how, const sigset_t *set, sigset_t *old_set);
int kill(pid_t pid, int signal);
unsigned alarm(unsigned seconds);

/* Processes, users and descriptors that a single WASI instance does not have. */
pid_t fork(void);
int execvp(const char *file, char *const argv[]);
int execv(const char *path, char *const argv[]);
int execve(const char *path, char *const argv[], char *const envp[]);
pid_t setsid(void);
pid_t getppid(void);
pid_t getpgid(pid_t pid);
int setpgid(pid_t pid, pid_t pgid);
pid_t getpgrp(void);
uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
gid_t getegid(void);
int setuid(uid_t uid);
int setgid(gid_t gid);
int seteuid(uid_t uid);
int setegid(gid_t gid);
int getgroups(int size, gid_t list[]);
int setgroups(size_t size, const gid_t *list);
int chown(const char *path, uid_t owner, gid_t group);
int fchown(int fd, uid_t owner, gid_t group);
int lchown(const char *path, uid_t owner, gid_t group);
int pipe(int fds[2]);
int pipe2(int fds[2], int flags);
int dup(int fd);
int dup2(int fd, int new_fd);
int dup3(int fd, int new_fd, int flags);
mode_t umask(mode_t mask);
int mknod(const char *path, mode_t mode, dev_t dev);
int mkfifo(const char *path, mode_t mode);
char *ttyname(int fd);
int ttyname_r(int fd, char *buffer, size_t length);
int chroot(const char *path);
int mkstemp(char *template_);
char *mkdtemp(char *template_);
#ifndef F_DUPFD_CLOEXEC
#    define F_DUPFD_CLOEXEC 1030
#endif

// A WASI module has no setuid state to guard against: secure_getenv is getenv.
char *secure_getenv(const char *name);

int pthread_getname_np(pthread_t thread, char *name, size_t length);
int pthread_setname_np(pthread_t thread, const char *name);

struct sched_param;
int pthread_setschedparam(pthread_t thread, int policy, const struct sched_param *param);
int pthread_getschedparam(pthread_t thread, int *policy, struct sched_param *param);

#ifdef __cplusplus
}
#endif
#endif
