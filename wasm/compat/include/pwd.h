/* pwd.h for WASI, which has no user database: every lookup finds nothing. See webby_wasi_compat.c. */
#pragma once
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
struct passwd {
    char* pw_name;
    char* pw_passwd;
    uid_t pw_uid;
    gid_t pw_gid;
    char* pw_gecos;
    char* pw_dir;
    char* pw_shell;
};
struct passwd* getpwuid(uid_t);
struct passwd* getpwnam(char const*);
struct passwd* getpwent(void);
void setpwent(void);
void endpwent(void);
int getpwuid_r(uid_t, struct passwd*, char*, size_t, struct passwd**);
int getpwnam_r(char const*, struct passwd*, char*, size_t, struct passwd**);
#ifdef __cplusplus
}
#endif
