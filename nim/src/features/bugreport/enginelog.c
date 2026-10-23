// Keeps what webby and the Ladybird helpers it starts (WebContent, RequestServer, ImageDecoder, ...) write to
// stderr, for bug reports: fd 2 becomes a pipe before the engine starts, so every helper inherits it, and a thread
// copies everything on to the real stderr and appends each line, stamped with the wall-clock ms it arrived, to a
// log file ("<ms> <line>\n"). The thread never waits on webby's main loop, so a busy UI can't block a helper's write.
// At `max_bytes` the file moves to <path>.1 and a new one starts.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static int read_fd = -1, out_fd = -1, log_fd = -1;
static char log_path[4096];
static long long log_bytes, max_bytes;

static void write_all(int fd, char const* data, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, data, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return;
        data += w;
        n -= (size_t)w;
    }
}

static void rotate(void) {
    char old[4200];
    snprintf(old, sizeof old, "%s.1", log_path);
    close(log_fd);
    rename(log_path, old);
    log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    log_bytes = 0;
}

static void log_line(char const* line, size_t n) {
    if (log_fd < 0) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    char stamp[32];
    int s = snprintf(stamp, sizeof stamp, "%lld ", (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000);
    write_all(log_fd, stamp, (size_t)s);
    write_all(log_fd, line, n);
    write_all(log_fd, "\n", 1);
    log_bytes += s + (long long)n + 1;
    if (log_bytes > max_bytes) rotate();
}

static void* pump(void* unused) {
    (void)unused;
    static char buffer[65536];
    static char line[8192];
    size_t have = 0;
    for (;;) {
        ssize_t n = read(read_fd, buffer, sizeof buffer);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        write_all(out_fd, buffer, (size_t)n);
        for (ssize_t i = 0; i < n; i++) {
            char c = buffer[i];
            if (c == '\n') {
                log_line(line, have);
                have = 0;
            } else if (have < sizeof line) {
                line[have++] = c;
            }
        }
    }
    if (have > 0) log_line(line, have);
    return NULL;
}

int webby_enginelog_start(char const* path, long long max_file_bytes) {
    if (read_fd >= 0) return 0;
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) != 0) return -1;
    out_fd = fcntl(2, F_DUPFD_CLOEXEC, 3);
    if (out_fd < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    snprintf(log_path, sizeof log_path, "%s", path);
    max_bytes = max_file_bytes;
    log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    read_fd = fds[0];
    pthread_t thread;
    if (pthread_create(&thread, NULL, pump, NULL) != 0) {
        close(fds[0]);
        close(fds[1]);
        close(out_fd);
        read_fd = out_fd = -1;
        return -1;
    }
    pthread_detach(thread);
    // dup2 leaves the new fd 2 inheritable, so helpers started from now on write into the pipe.
    fflush(stderr);
    dup2(fds[1], 2);
    close(fds[1]);
    return 0;
}
