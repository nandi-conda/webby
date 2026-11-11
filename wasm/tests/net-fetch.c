/* net-fetch HOST PORT [PATH]: an HTTP/1.0 GET over compat's sockets (wasi:sockets underneath), the way an event loop
 * does it: getaddrinfo, a non-blocking connect, poll for writable, SO_ERROR, send, then poll + recv until EOF.
 * Prints the status line and the body size. With -u HOST PORT it sends one datagram on a connected UDP socket and
 * prints the reply (tests/net.sh runs a local echo server for that). */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int open_connected(const char *host, const char *port, int type)
{
    struct addrinfo hints = { 0 }, *res;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = type;
    int e = getaddrinfo(host, port, &hints, &res);
    if (e) {
        fprintf(stderr, "getaddrinfo %s: %s\n", host, gai_strerror(e));
        exit(1);
    }
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        char name[64], serv[8];
        getnameinfo(ai->ai_addr, ai->ai_addrlen, name, sizeof name, serv, sizeof serv, NI_NUMERICHOST);
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            perror("socket");
            continue;
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) < 0 && errno != EINPROGRESS) {
            fprintf(stderr, "connect %s: %s\n", name, strerror(errno));
            close(fd);
            continue;
        }
        struct pollfd p = { fd, POLLOUT, 0 };
        int r = poll(&p, 1, 10000);
        int error = 0;
        socklen_t len = sizeof error;
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len);
        if (r != 1 || error) {
            fprintf(stderr, "connect %s: %s\n", name, r == 1 ? strerror(error) : "timed out");
            close(fd);
            continue;
        }
        fprintf(stderr, "connected to %s port %s\n", name, serv);
        freeaddrinfo(res);
        return fd;
    }
    freeaddrinfo(res);
    exit(1);
}

int main(int argc, char **argv)
{
    if (argc >= 4 && !strcmp(argv[1], "-u")) {
        int fd = open_connected(argv[2], argv[3], SOCK_DGRAM);
        const char message[] = "ping over wasi:sockets";
        if (send(fd, message, sizeof message - 1, 0) < 0) {
            perror("send");
            return 1;
        }
        struct pollfd p = { fd, POLLIN, 0 };
        if (poll(&p, 1, 5000) != 1) {
            fprintf(stderr, "no reply\n");
            return 1;
        }
        char buffer[256];
        ssize_t n = recv(fd, buffer, sizeof buffer, 0);
        printf("udp reply: %.*s\n", (int)(n > 0 ? n : 0), buffer);
        return close(fd) == 0 && n > 0 ? 0 : 1;
    }
    if (argc < 3) {
        fprintf(stderr, "usage: net-fetch HOST PORT [PATH] | net-fetch -u HOST PORT\n");
        return 2;
    }
    int fd = open_connected(argv[1], argv[2], SOCK_STREAM);
    char request[512];
    int len = snprintf(request, sizeof request, "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: net-fetch\r\n\r\n",
                       argc > 3 ? argv[3] : "/", argv[1]);
    for (int off = 0; off < len;) {
        ssize_t n = write(fd, request + off, (size_t)(len - off));
        if (n < 0 && errno == EAGAIN) {
            struct pollfd p = { fd, POLLOUT, 0 };
            poll(&p, 1, -1);
            continue;
        }
        if (n < 0) {
            perror("write");
            return 1;
        }
        off += (int)n;
    }
    size_t total = 0, cap = 1 << 16;
    char *body = malloc(cap);
    for (;;) {
        struct pollfd p = { fd, POLLIN, 0 };
        if (poll(&p, 1, 15000) != 1) {
            fprintf(stderr, "read timed out\n");
            return 1;
        }
        if (total + 4096 > cap)
            body = realloc(body, cap *= 2);
        ssize_t n = recv(fd, body + total, cap - total, 0);
        if (n < 0 && errno == EAGAIN)
            continue;
        if (n < 0) {
            perror("recv");
            return 1;
        }
        if (n == 0)
            break;
        total += (size_t)n;
    }
    close(fd);
    char *eol = memchr(body, '\r', total);
    printf("%.*s\n", eol ? (int)(eol - body) : 0, body);
    char *start = memmem(body, total, "\r\n\r\n", 4);
    printf("%zu bytes of body\n", start ? total - (size_t)(start + 4 - body) : 0);
    return 0;
}
