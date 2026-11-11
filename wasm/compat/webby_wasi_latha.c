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
#include <stdio.h>
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

/* A list of NUL-terminated strings, len bytes, as a list of strings (pointing into it). */
static proc_string_t *split_nul(const char *b, size_t len, size_t *count)
{
    size_t n = 0;
    for (size_t i = 0; i < len; i++)
        n += b[i] == 0;
    proc_string_t *out = calloc(n ? n : 1, sizeof *out);
    if (!out)
        return NULL;
    size_t k = 0, start = 0;
    for (size_t i = 0; i < len; i++) {
        if (b[i] == 0) {
            out[k].ptr = (uint8_t *)b + start;
            out[k].len = i - start;
            k++;
            start = i + 1;
        }
    }
    *count = n;
    return out;
}

static int b_spawn_env(const char *path, const char *args, size_t alen, const char *env, size_t elen, uint32_t *pid,
    uint32_t *channel)
{
    size_t na = 0, ne = 0;
    proc_string_t *as = split_nul(args, alen, &na), *es = split_nul(env, elen, &ne);
    int r = 0;
    if (!as || !es) {
        r = -ENOMEM;
    } else {
        proc_string_t p = { (uint8_t *)path, strlen(path) };
        proc_list_string_t al = { as, na }, el = { es, ne };
        proc_tuple2_u32_handle_t ok;
        proc_string_t err;
        if (latha_proc_process_spawn_with_env(&p, &al, &el, &ok, &err)) {
            *pid = ok.f0;
            *channel = ok.f1;
        } else {
            fprintf(stderr, "webby: spawning %s: %.*s\n", path, (int)err.len, (const char *)err.ptr);
            proc_string_free(&err);
            r = -ENOENT;
        }
    }
    free(as);
    free(es);
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

static int mem_err(latha_proc_memory_error_t e)
{
    switch (e) {
    case LATHA_PROC_MEMORY_ERROR_BAD_HANDLE:
        return -EBADF;
    case LATHA_PROC_MEMORY_ERROR_UNALIGNED:
        return -EINVAL;
    case LATHA_PROC_MEMORY_ERROR_FAULT:
        return -EFAULT;
    default:
        return -ENOMEM;
    }
}

static int b_mem_create(uint64_t size, uint32_t *h)
{
    latha_proc_memory_error_t e;
    return latha_proc_memory_create(size, h, &e) ? 0 : mem_err(e);
}

static int b_mem_dup(uint32_t h, uint32_t *out)
{
    latha_proc_memory_error_t e;
    return latha_proc_memory_dup(h, out, &e) ? 0 : mem_err(e);
}

static int b_mem_size(uint32_t h, uint64_t *size)
{
    latha_proc_memory_error_t e;
    return latha_proc_memory_size(h, size, &e) ? 0 : mem_err(e);
}

static int b_mem_resize(uint32_t h, uint64_t size)
{
    latha_proc_memory_error_t e;
    return latha_proc_memory_resize(h, size, &e) ? 0 : mem_err(e);
}

static int b_mem_map(uint32_t h, uint64_t offset, void *addr, size_t len)
{
    latha_proc_memory_error_t e;
    return latha_proc_memory_map_at(h, offset, (uint32_t)(uintptr_t)addr, (uint32_t)len, &e) ? 0 : mem_err(e);
}

static int b_mem_unmap(void *addr, size_t len)
{
    latha_proc_memory_error_t e;
    return latha_proc_memory_unmap_at((uint32_t)(uintptr_t)addr, (uint32_t)len, &e) ? 0 : mem_err(e);
}

static size_t b_page_size(void) { return latha_proc_memory_page_size(); }

static int b_is_memory(uint32_t h) { return latha_proc_memory_is_memory(h); }

static const struct webby_latha_ops ops = {
    .pair = b_pair,
    .send = b_send,
    .recv = b_recv,
    .wait = b_wait,
    .close = b_close,
    .parent = b_parent,
    .spawn = b_spawn,
    .spawn_env = b_spawn_env,
    .wait_exit = b_wait_exit,
    .kill = b_kill,
    .mem_create = b_mem_create,
    .mem_dup = b_mem_dup,
    .mem_size = b_mem_size,
    .mem_resize = b_mem_resize,
    .mem_map = b_mem_map,
    .mem_unmap = b_mem_unmap,
    .page_size = b_page_size,
    .is_memory = b_is_memory,
};

/* webby_wasi_local.c's weak reference finds this once --undefined has linked the archive member in. */
const struct webby_latha_ops *webby_latha_backend_ops(void) { return &ops; }
