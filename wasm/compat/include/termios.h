/* termios.h for WASI, which has no terminals: tcgetattr() fails with ENOTTY. See webby_wasi_compat.c. */
#pragma once
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef unsigned char cc_t;
typedef unsigned int speed_t;
typedef unsigned int tcflag_t;
#define NCCS 32
struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;
    cc_t c_line;
    cc_t c_cc[NCCS];
    speed_t c_ispeed;
    speed_t c_ospeed;
};
struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};
#define VINTR 0
#define VQUIT 1
#define VERASE 2
#define VKILL 3
#define VEOF 4
#define VTIME 5
#define VMIN 6
#define VSTART 8
#define VSTOP 9
#define VSUSP 10
#define VEOL 11
#define VWERASE 14
#define ISIG 0000001
#define ICANON 0000002
#define ECHO 0000010
#define ECHOE 0000020
#define ECHOK 0000040
#define ECHONL 0000100
#define NOFLSH 0000200
#define TOSTOP 0000400
#define ECHOCTL 0001000
#define IEXTEN 0100000
#define BRKINT 0000002
#define ICRNL 0000400
#define INPCK 0000020
#define ISTRIP 0000040
#define IXON 0002000
#define OPOST 0000001
#define CS8 0000060
#define TCSANOW 0
#define TCSADRAIN 1
#define TCSAFLUSH 2
#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414
#define TIOCSCTTY 0x540E
#define TIOCNOTTY 0x5422
int tcgetattr(int, struct termios*);
int tcsetattr(int, int, struct termios const*);
pid_t tcgetpgrp(int);
int tcsetpgrp(int, pid_t);
speed_t cfgetospeed(struct termios const*);
#ifdef __cplusplus
}
#endif
