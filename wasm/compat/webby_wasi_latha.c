/* The latha:proc backend for local sockets (webby_wasi_local.h): channels and processes from latha-gui/latha-run
 * (qt2wasm's proc/wit/proc.wit, latha:proc@0.1.0), through the component model, so a program that also has
 * wasi:sockets is one component with both. Bindings: latha-proc/ (wit-bindgen 0.46.0 c, world proc).
 *
 * In libwebby_wasi_latha.a, not the compat library: a program that links it imports latha:proc and only runs in a
 * latha host. Link it with `-lwebby_wasi_latha -Wl,--undefined=webby_latha_backend_ops`
 * (WEBBY_WASI_LATHA_LINK_OPTIONS in cmake/wasi.cmake); with it, every socketpair() is a channel. */
#include "webby_wasi_local.h"
#include "latha-proc/proc.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static int err_of(latha_proc_channels_error_t e)
{
    switch (e) {
    case LATHA_PROC_CHANNELS_ERROR_CLOSED:
        return -EPIPE;
    case LATHA_PROC_CHANNELS_ERROR_TIMEOUT:
        return -EAGAIN;
    case LATHA_PROC_CHANNELS_ERROR_BAD_HANDLE:
        return -EBADF;
    default:
        return -EMSGSIZE;
    }
}

static int b_pair(uint32_t out[2])
{
    proc_tuple2_handle_handle_t t;
    latha_proc_channels_pair(&t);
    out[0] = t.f0;
    out[1] = t.f1;
    return 0;
}

static int b_send(uint32_t h, const void *data, size_t len, const uint32_t *handles, size_t nhandles)
{
    proc_list_u8_t d = { (uint8_t *)data, len };
    proc_list_handle_t hs = { (uint32_t *)handles, nhandles };
    latha_proc_channels_error_t e;
    return latha_proc_channels_send(h, &d, &hs, &e) ? 0 : err_of(e);
}

static int b_recv(uint32_t h, int timeout_ms, void **data, size_t *len, uint32_t **handles, size_t *nhandles)
{
    latha_proc_channels_message_t m;
    latha_proc_channels_error_t e;
    if (!latha_proc_channels_recv(h, timeout_ms, &m, &e))
        return err_of(e);
    /* The canonical ABI allocates with cabi_realloc, which is malloc here. */
    *data = m.data.ptr;
    *len = m.data.len;
    *handles = m.handles.ptr;
    *nhandles = m.handles.len;
    return 0;
}

static int b_wait(const uint32_t *hs, size_t n, uint8_t *ready, int timeout_ms)
{
    proc_list_handle_t l = { (uint32_t *)hs, n };
    proc_list_u32_t r;
    latha_proc_channels_wait(&l, timeout_ms, &r);
    memset(ready, 0, n);
    for (size_t i = 0; i < r.len; i++)
        if (r.ptr[i] < n)
            ready[r.ptr[i]] = 1;
    int count = (int)r.len;
    proc_list_u32_free(&r);
    return count;
}

static void b_close(uint32_t h) { latha_proc_channels_close(h); }

static int b_parent(uint32_t *h) { return latha_proc_channels_parent(h) ? 0 : -EBADF; }

static int b_spawn(const char *path, char *const argv[], uint32_t *pid, uint32_t *channel)
{
    size_t argc = 0;
    while (argv && argv[argc])
        argc++;
    proc_string_t p = { (uint8_t *)path, strlen(path) };
    proc_string_t *as = calloc(argc ? argc : 1, sizeof *as);
    if (!as)
        return -ENOMEM;
    for (size_t i = 0; i < argc; i++) {
        as[i].ptr = (uint8_t *)argv[i];
        as[i].len = strlen(argv[i]);
    }
    proc_list_string_t args = { as, argc };
    proc_tuple2_u32_handle_t ok;
    proc_string_t err;
    int r = 0;
    if (latha_proc_process_spawn(&p, &args, &ok, &err)) {
        *pid = ok.f0;
        *channel = ok.f1;
    } else {
        proc_string_free(&err);
        r = -ENOENT;
    }
    free(as);
    return r;
}

static int b_wait_exit(uint32_t pid, int timeout_ms, int *code)
{
    int32_t c;
    if (!latha_proc_process_wait_exit(pid, timeout_ms, &c))
        return -EAGAIN;
    *code = c;
    return 0;
}

static void b_kill(uint32_t pid) { latha_proc_process_kill(pid); }

static const struct webby_latha_ops ops = {
    .pair = b_pair,
    .send = b_send,
    .recv = b_recv,
    .wait = b_wait,
    .close = b_close,
    .parent = b_parent,
    .spawn = b_spawn,
    .wait_exit = b_wait_exit,
    .kill = b_kill,
};

/* webby_wasi_local.c's weak reference finds this once --undefined has linked the archive member in. */
const struct webby_latha_ops *webby_latha_backend_ops(void) { return &ops; }
