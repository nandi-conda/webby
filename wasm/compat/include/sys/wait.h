/* sys/wait.h for WASI: waitpid() waits for a latha:proc child (webby_wasi_local.c); without the backend it fails
 * with ECHILD. */
#pragma once
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
#define WNOHANG 1
#define WUNTRACED 2
#define WCONTINUED 8
#define WEXITSTATUS(s) (((s) & 0xff00) >> 8)
#define WTERMSIG(s) ((s) & 0x7f)
#define WSTOPSIG(s) WEXITSTATUS(s)
#define WIFEXITED(s) (!WTERMSIG(s))
#define WIFSTOPPED(s) ((short)((((s) & 0xffff) * 0x10001U) >> 8) > 0x7f00)
#define WIFSIGNALED(s) (((s) & 0xffff) - 1U < 0xffu)
#define WIFCONTINUED(s) ((s) == 0xffff)
#define WCOREDUMP(s) ((s) & 0x80)
pid_t wait(int*);
pid_t waitpid(pid_t, int*, int);
#ifdef __cplusplus
}
#endif
