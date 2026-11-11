/* shadow.h for WASI, which has no shadow password database: every lookup finds nothing. */
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
struct spwd {
    char* sp_namp;
    char* sp_pwdp;
    long sp_lstchg;
    long sp_min;
    long sp_max;
    long sp_warn;
    long sp_inact;
    long sp_expire;
    unsigned long sp_flag;
};
struct spwd* getspnam(char const*);
struct spwd* getspent(void);
void setspent(void);
void endspent(void);
int putspent(struct spwd const*, void*);
#ifdef __cplusplus
}
#endif
