/* grp.h for WASI, which has no group database: every lookup finds nothing. See webby_wasi_compat.c. */
#pragma once
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
struct group {
    char* gr_name;
    char* gr_passwd;
    gid_t gr_gid;
    char** gr_mem;
};
struct group* getgrgid(gid_t);
struct group* getgrnam(char const*);
struct group* getgrent(void);
void setgrent(void);
void endgrent(void);
int setgroups(size_t, gid_t const*);
int initgroups(char const*, gid_t);
#ifdef __cplusplus
}
#endif
