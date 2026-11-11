/* spawn.h for WASI. posix_spawn() starts a wasm program as a latha:proc process when the program links the
 * latha:proc backend (webby_wasi_local.c), else fails with ENOSYS. */
#pragma once
#include <signal.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
#define POSIX_SPAWN_RESETIDS 1
#define POSIX_SPAWN_SETPGROUP 2
#define POSIX_SPAWN_SETSIGDEF 4
#define POSIX_SPAWN_SETSIGMASK 8
#define POSIX_SPAWN_SETSCHEDPARAM 16
#define POSIX_SPAWN_SETSCHEDULER 32
#define POSIX_SPAWN_SETSID 128
typedef struct { int unused; } posix_spawnattr_t;
/* The actions the child's descriptors come from: dup2(src, fd) and (ignored) open/close/chdir. */
typedef struct { int kind, fd, src; } webby_spawn_action;
typedef struct { int count; webby_spawn_action *actions; } posix_spawn_file_actions_t;
int posix_spawn(pid_t*, char const*, posix_spawn_file_actions_t const*, posix_spawnattr_t const*, char* const[], char* const[]);
int posix_spawnp(pid_t*, char const*, posix_spawn_file_actions_t const*, posix_spawnattr_t const*, char* const[], char* const[]);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t*);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t*);
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t*, int, char const*, int, mode_t);
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t*, int);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t*, int, int);
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t*, char const*);
int posix_spawnattr_init(posix_spawnattr_t*);
int posix_spawnattr_destroy(posix_spawnattr_t*);
int posix_spawnattr_setflags(posix_spawnattr_t*, short);
int posix_spawnattr_setpgroup(posix_spawnattr_t*, pid_t);
int posix_spawnattr_setsigmask(posix_spawnattr_t*, sigset_t const*);
int posix_spawnattr_setsigdefault(posix_spawnattr_t*, sigset_t const*);
#ifdef __cplusplus
}
#endif
