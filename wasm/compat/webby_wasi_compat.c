/* The functions webby_wasi_compat.h and netdb.h declare, for wasm32-wasip1. */
#include "webby_wasi_compat.h"
#include <netdb.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

/* Sockets, getaddrinfo and friends are in webby_wasi_net.c (wasi:sockets). */

static char utc[] = "UTC";
char *tzname[2] = { utc, utc };
long timezone = 0;
int daylight = 0;
void tzset(void) { }

int pthread_setschedparam(pthread_t t, int p, const struct sched_param *s) { (void)t; (void)p; (void)s; return ENOTSUP; }
int pthread_getschedparam(pthread_t t, int *p, struct sched_param *s) { (void)t; (void)s; if (p) *p = 0; return 0; }

/* No users, groups, child processes or terminals on WASI. */
#include <grp.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <termios.h>

struct passwd* getpwuid(uid_t uid) { (void)uid; return NULL; }
struct passwd* getpwnam(char const* name) { (void)name; return NULL; }
struct passwd* getpwent(void) { return NULL; }
void setpwent(void) { }
void endpwent(void) { }
int getpwuid_r(uid_t uid, struct passwd* entry, char* buffer, size_t size, struct passwd** result)
{
    (void)uid; (void)entry; (void)buffer; (void)size;
    *result = NULL;
    return 0;
}
int getpwnam_r(char const* name, struct passwd* entry, char* buffer, size_t size, struct passwd** result)
{
    (void)name; (void)entry; (void)buffer; (void)size;
    *result = NULL;
    return 0;
}
struct group* getgrgid(gid_t gid) { (void)gid; return NULL; }
struct group* getgrnam(char const* name) { (void)name; return NULL; }
struct group* getgrent(void) { return NULL; }
void setgrent(void) { }
void endgrent(void) { }
int setgroups(size_t count, gid_t const* groups) { (void)count; (void)groups; errno = EPERM; return -1; }
int initgroups(char const* user, gid_t group) { (void)user; (void)group; errno = EPERM; return -1; }

pid_t wait(int* status) { (void)status; errno = ECHILD; return -1; }
pid_t waitpid(pid_t pid, int* status, int options) { (void)pid; (void)status; (void)options; errno = ECHILD; return -1; }

int posix_spawn(pid_t* pid, char const* path, posix_spawn_file_actions_t const* actions, posix_spawnattr_t const* attributes, char* const arguments[], char* const environment[])
{
    (void)pid; (void)path; (void)actions; (void)attributes; (void)arguments; (void)environment;
    return ENOSYS;
}
int posix_spawnp(pid_t* pid, char const* file, posix_spawn_file_actions_t const* actions, posix_spawnattr_t const* attributes, char* const arguments[], char* const environment[])
{
    return posix_spawn(pid, file, actions, attributes, arguments, environment);
}
int posix_spawn_file_actions_init(posix_spawn_file_actions_t* actions) { (void)actions; return 0; }
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t* actions) { (void)actions; return 0; }
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t* actions, int fd, char const* path, int flags, mode_t mode) { (void)actions; (void)fd; (void)path; (void)flags; (void)mode; return 0; }
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t* actions, int fd) { (void)actions; (void)fd; return 0; }
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t* actions, int fd, int new_fd) { (void)actions; (void)fd; (void)new_fd; return 0; }
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t* actions, char const* path) { (void)actions; (void)path; return 0; }
int posix_spawnattr_init(posix_spawnattr_t* attributes) { (void)attributes; return 0; }
int posix_spawnattr_destroy(posix_spawnattr_t* attributes) { (void)attributes; return 0; }
int posix_spawnattr_setflags(posix_spawnattr_t* attributes, short flags) { (void)attributes; (void)flags; return 0; }
int posix_spawnattr_setpgroup(posix_spawnattr_t* attributes, pid_t group) { (void)attributes; (void)group; return 0; }
int posix_spawnattr_setsigmask(posix_spawnattr_t* attributes, sigset_t const* mask) { (void)attributes; (void)mask; return 0; }
int posix_spawnattr_setsigdefault(posix_spawnattr_t* attributes, sigset_t const* mask) { (void)attributes; (void)mask; return 0; }

int tcgetattr(int fd, struct termios* termios) { (void)fd; (void)termios; errno = ENOTTY; return -1; }
int tcsetattr(int fd, int when, struct termios const* termios) { (void)fd; (void)when; (void)termios; errno = ENOTTY; return -1; }
pid_t tcgetpgrp(int fd) { (void)fd; errno = ENOTTY; return -1; }
int tcsetpgrp(int fd, pid_t group) { (void)fd; (void)group; errno = ENOTTY; return -1; }
speed_t cfgetospeed(struct termios const* termios) { (void)termios; return 0; }

#include <shadow.h>
struct spwd* getspnam(char const* name) { (void)name; return NULL; }
struct spwd* getspent(void) { return NULL; }
void setspent(void) { }
void endspent(void) { }
int putspent(struct spwd const* entry, void* file) { (void)entry; (void)file; errno = ENOSYS; return -1; }

/* sendmsg, recvmsg, socketpair, pipe and pipe2 are in webby_wasi_local.c (local sockets). */

/* ---- resource limits ---- */
static struct rlimit webby_rlimits[16] = {
    [RLIMIT_CPU] = { RLIM_INFINITY, RLIM_INFINITY },
    [RLIMIT_FSIZE] = { RLIM_INFINITY, RLIM_INFINITY },
    [RLIMIT_DATA] = { RLIM_INFINITY, RLIM_INFINITY },
    [RLIMIT_STACK] = { 8u << 20, 8u << 20 },
    [RLIMIT_CORE] = { 0, 0 },
    [RLIMIT_NOFILE] = { 1024, 65536 },
    [RLIMIT_AS] = { RLIM_INFINITY, RLIM_INFINITY },
};
int getrlimit(int resource, struct rlimit* limit)
{
    if (resource < 0 || resource >= 16) { errno = EINVAL; return -1; }
    *limit = webby_rlimits[resource];
    return 0;
}
int setrlimit(int resource, const struct rlimit* limit)
{
    if (resource < 0 || resource >= 16) { errno = EINVAL; return -1; }
    if (limit->rlim_max > webby_rlimits[resource].rlim_max || limit->rlim_cur > limit->rlim_max) { errno = EPERM; return -1; }
    webby_rlimits[resource] = *limit;
    return 0;
}

/* ---- signals: sigaction over signal(), masks kept but not enforced ---- */
#define WEBBY_NSIG 65
static struct sigaction webby_actions[WEBBY_NSIG];
static sigset_t webby_mask;
int sigaction(int number, const struct sigaction* action, struct sigaction* old_action)
{
    if (number <= 0 || number >= WEBBY_NSIG) { errno = EINVAL; return -1; }
    if (old_action)
        *old_action = webby_actions[number];
    if (action) {
        webby_actions[number] = *action;
        /* An SA_SIGINFO handler gets a null siginfo/context: nothing raises with details here. */
        if (signal(number, action->sa_handler) == SIG_ERR)
            return -1;
    }
    return 0;
}
/* wasi-libc's sigset_t is one unsigned char: only signals 1-8 fit, the rest are accepted and not stored. */
#define WEBBY_SIGBIT(n) ((n) - 1 < (int)(8 * sizeof(sigset_t)) ? (sigset_t)(1u << ((n) - 1)) : (sigset_t)0)
int sigemptyset(sigset_t* set) { *set = 0; return 0; }
int sigfillset(sigset_t* set) { *set = (sigset_t)~(sigset_t)0; return 0; }
int sigaddset(sigset_t* set, int n) { if (n <= 0 || n >= WEBBY_NSIG) { errno = EINVAL; return -1; } *set |= WEBBY_SIGBIT(n); return 0; }
int sigdelset(sigset_t* set, int n) { if (n <= 0 || n >= WEBBY_NSIG) { errno = EINVAL; return -1; } *set &= (sigset_t)~WEBBY_SIGBIT(n); return 0; }
int sigismember(const sigset_t* set, int n) { if (n <= 0 || n >= WEBBY_NSIG) { errno = EINVAL; return -1; } return (*set & WEBBY_SIGBIT(n)) != 0; }
int sigprocmask(int how, const sigset_t* set, sigset_t* old_set)
{
    sigset_t previous = webby_mask;
    if (set) {
        switch (how) {
        case SIG_BLOCK: webby_mask |= *set; break;
        case SIG_UNBLOCK: webby_mask &= (sigset_t)~*set; break;
        case SIG_SETMASK: webby_mask = *set; break;
        default: errno = EINVAL; return -1;
        }
    }
    if (old_set)
        *old_set = previous;
    return 0;
}
int pthread_sigmask(int how, const sigset_t* set, sigset_t* old_set) { return sigprocmask(how, set, old_set) == 0 ? 0 : errno; }
int kill(pid_t pid, int number)
{
    if (pid == getpid() || pid == 0 || pid == -1)
        return number == 0 ? 0 : raise(number);
    errno = ESRCH;
    return -1;
}
unsigned alarm(unsigned seconds) { (void)seconds; return 0; }

/* ---- processes and users: one instance, run as root (uid 0) ---- */
pid_t fork(void) { errno = ENOSYS; return -1; }
int execvp(const char* file, char* const argv[]) { (void)file; (void)argv; errno = ENOSYS; return -1; }
int execv(const char* path, char* const argv[]) { (void)path; (void)argv; errno = ENOSYS; return -1; }
int execve(const char* path, char* const argv[], char* const envp[]) { (void)path; (void)argv; (void)envp; errno = ENOSYS; return -1; }
pid_t setsid(void) { return getpid(); }
pid_t getppid(void) { return 0; }
pid_t getpgid(pid_t pid) { (void)pid; return getpid(); }
int setpgid(pid_t pid, pid_t group) { (void)pid; (void)group; return 0; }
pid_t getpgrp(void) { return getpid(); }
uid_t getuid(void) { return 0; }
uid_t geteuid(void) { return 0; }
gid_t getgid(void) { return 0; }
gid_t getegid(void) { return 0; }
int setuid(uid_t uid) { if (uid != 0) { errno = EPERM; return -1; } return 0; }
int setgid(gid_t gid) { if (gid != 0) { errno = EPERM; return -1; } return 0; }
int seteuid(uid_t uid) { return setuid(uid); }
int setegid(gid_t gid) { return setgid(gid); }
int getgroups(int size, gid_t list[]) { (void)size; (void)list; return 0; }
int chown(const char* path, uid_t owner, gid_t group) { (void)path; (void)owner; (void)group; return 0; }
int fchown(int fd, uid_t owner, gid_t group) { (void)fd; (void)owner; (void)group; return 0; }
int lchown(const char* path, uid_t owner, gid_t group) { (void)path; (void)owner; (void)group; return 0; }

/* ---- descriptors ---- */
int dup(int fd) { (void)fd; errno = ENOSYS; return -1; }
int dup3(int fd, int new_fd, int flags)
{
    (void)flags;
    if (fd == new_fd) { errno = EINVAL; return -1; }
    /* WASI can renumber a descriptor onto another, which closes the target: the old number is then gone. */
    errno = ENOSYS;
    return -1;
}
int dup2(int fd, int new_fd) { if (fd == new_fd) return fd; return dup3(fd, new_fd, 0); }
mode_t umask(mode_t mask) { static mode_t current = 022; mode_t old = current; current = mask & 0777; return old; }
int mknod(const char* path, mode_t mode, dev_t dev) { (void)path; (void)mode; (void)dev; errno = ENOSYS; return -1; }
int mkfifo(const char* path, mode_t mode) { (void)path; (void)mode; errno = ENOSYS; return -1; }
char* ttyname(int fd) { (void)fd; errno = ENOTTY; return NULL; }
int ttyname_r(int fd, char* buffer, size_t length) { (void)fd; (void)buffer; (void)length; return ENOTTY; }
int chroot(const char* path) { (void)path; errno = EPERM; return -1; }

static int webby_fill_template(char* template_)
{
    size_t length = strlen(template_);
    if (length < 6 || strcmp(template_ + length - 6, "XXXXXX") != 0) { errno = EINVAL; return -1; }
    static const char letters[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    unsigned char random[6];
    if (getentropy(random, sizeof(random)) != 0)
        return -1;
    for (int i = 0; i < 6; ++i)
        template_[length - 6 + i] = letters[random[i] % (sizeof(letters) - 1)];
    return 0;
}
int mkstemp(char* template_)
{
    for (int attempt = 0; attempt < 100; ++attempt) {
        if (webby_fill_template(template_) != 0)
            return -1;
        int fd = open(template_, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd >= 0 || errno != EEXIST)
            return fd;
        memcpy(template_ + strlen(template_) - 6, "XXXXXX", 6);
    }
    errno = EEXIST;
    return -1;
}
char* mkdtemp(char* template_)
{
    for (int attempt = 0; attempt < 100; ++attempt) {
        if (webby_fill_template(template_) != 0)
            return NULL;
        if (mkdir(template_, 0700) == 0)
            return template_;
        if (errno != EEXIST)
            return NULL;
        memcpy(template_ + strlen(template_) - 6, "XXXXXX", 6);
    }
    errno = EEXIST;
    return NULL;
}

/* ---- thread names: the one thread is "main" ---- */
static char webby_thread_name[16] = "main";
int pthread_getname_np(pthread_t thread, char* name, size_t length)
{
    (void)thread;
    if (length < strlen(webby_thread_name) + 1)
        return ERANGE;
    strcpy(name, webby_thread_name);
    return 0;
}
int pthread_setname_np(pthread_t thread, const char* name)
{
    (void)thread;
    if (strlen(name) >= sizeof(webby_thread_name))
        return ERANGE;
    strcpy(webby_thread_name, name);
    return 0;
}

/* ---- unnamed POSIX semaphores (Skia's SkSemaphore): a counter, since nothing else can post while the one thread
 * waits. Waiting on zero would block forever, so it fails with EDEADLK instead. ---- */
#include <semaphore.h>
int sem_init(sem_t* s, int shared, unsigned value) { (void)shared; s->__val[0] = (int)value; return 0; }
int sem_destroy(sem_t* s) { (void)s; return 0; }
int sem_post(sem_t* s) { s->__val[0]++; return 0; }
int sem_trywait(sem_t* s)
{
    if (s->__val[0] > 0) { s->__val[0]--; return 0; }
    errno = EAGAIN;
    return -1;
}
int sem_wait(sem_t* s)
{
    if (sem_trywait(s) == 0) return 0;
    errno = EDEADLK;
    return -1;
}
int sem_timedwait(sem_t* restrict s, const struct timespec* restrict t)
{
    (void)t;
    if (sem_trywait(s) == 0) return 0;
    errno = ETIMEDOUT;
    return -1;
}
int sem_getvalue(sem_t* restrict s, int* restrict value) { *value = s->__val[0]; return 0; }

char *secure_getenv(const char *name) { return getenv(name); }
