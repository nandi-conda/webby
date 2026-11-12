# webby in WebAssembly (work in progress)

Goal: all of webby, the Ladybird engine and a Qt UI, as WebAssembly built with
[qt2wasm](https://fileapi.fastapicloud.dev/forge/nandi.uk/qt2wasm) (Qt 6 for WASI, wasm32-wasip1) and run by a
latha:gui host. Not usable yet.

| Path | What |
| --- | --- |
| `pixi.toml` | the toolchain: qt2wasm (wasi-sdk 27, Qt for WASI), CMake, Ninja, Rust |
| `cmake/wasi.cmake` | CMake toolchain for wasm32-wasip1 with wasi-libc's emulation libraries and `compat/` |
| `compat/` | `netdb.h` and the POSIX pieces wasi-libc lacks (one time zone), TCP/UDP sockets over wasi:sockets (`webby_wasi_net.c`), and local sockets with descriptor passing, in memory or over latha:proc channels (`webby_wasi_local.c`, `webby_wasi_latha.c`) |
| `deps/` | scripts that build Ladybird's dependencies for WASI into a sysroot (`WEBBY_WASI_SYSROOT`) |
| `patches/` | Ladybird changes for a WASI build, on top of `../LADYBIRD_COMMIT` and `../patches/` |
| `tests/` | small wasm programs that check a dependency works (`tests/skia-rect.sh`, `tests/net.sh`, `tests/local-sockets.sh`, `tests/ipc.sh`) |
| `tools/wasi-run.py` | runs a wasm32-wasip1 program with PyPI wasmtime (`LIBJS_TARGET_RUNNER` for the layout generator); programs with sockets as components in the wasmtime CLI |
| `ci/` | the forge jobs `wasm-deps` and `wasm-engine` (see [Forge CI](#forge-ci)) |
| `build-engine.sh` | configures and builds Ladybird for wasm32-wasip1 (target `js` for now) |

## Status (2026-11-11)

Dependencies build for WASI: ICU 78.3 (data compiled in), OpenSSL 3.6.5, mimalloc 2.2.7, simdutf 9.1.1,
fast_float 8.3.1, zmij 1.2 (`deps/zmij-array-bounds.patch`), libtommath 1.3.0, libpsl 0.21.5. Ladybird configures in
WASI mode (`patches/0001-wasi-build-mode.patch`: only the libraries `js` needs, `AK_OS_WASI`, a software `f16`).

`patches/0002-wasm32-runtime.patch` makes the engine's memory model work in a 32-bit address space:

- LibGC: on WASI the heap region is the low 2 GiB of linear memory at base 0, a compressed cell pointer is the
  address itself (shift 0), and 2 MiB chunks come from `aligned_alloc` because linear memory cannot be reserved.
  The decommit worker thread is not started. The conservative scan has no registers to capture; the wasm build
  will run binaryen's `--spill-pointers` so pointers in wasm locals also sit on the shadow stack it scans.
- PrimitiveStorage (ArrayBuffer bytes): the cage is the same low 2 GiB, offsets are addresses, ranges come from
  the allocator. LibCore's commit/decommit just zero memory on WASI.
- C++ `GC::Cell` keeps an 8-byte first word on wasm32 (vtable pointer + padding) so its mark/state/kind bytes sit
  where the Rust runtime's cell header has them.
- The Rust runtime (`libjs_rust`) builds for wasm32-wasip1. Its layouts (the interpreter's `layout.conf` and the
  C++ embedding header `Layout.h`) are computed on the target: the build script compiles
  `generate/layout_main.rs` for wasm32 and runs it under `LIBJS_TARGET_RUNNER`. No wasmtime CLI is on
  conda-forge, so `tools/wasi-run.py` (PyPI `wasmtime`) stands in:
  `LIBJS_TARGET_RUNNER="python tools/wasi-run.py"`. 64-bit builds produce exactly the layout they did before.
- Earlier AK/LibCore fixes: getentropy in 256-byte chunks, no coarse clocks, no stack unwinder, WASI stack bounds,
  32-bit libtommath digits.

The interpreter: `patches/0003-flap-c-backend.patch` gives Flap a C backend (`Flap/src/target/c.rs`). It prints
LibJS's `interpreter.flap` from target-independent LowIR as C, one function per handler with the interpreter state as
parameters, chained with clang's `musttail`, which wasi-sdk turns into wasm `return_call`s with `-mtail-call`. build.rs
uses it for wasm32 (or anywhere with `LIBJS_INTERPRETER_BACKEND=c`, JIT off) and compiles it with `cc`. Layout fields
the wasm32 layout marks `<OFFSET>_WIDTH = 4` load and store as 32 bits. `flapc --emit-c` prints the C by hand.

`patches/0004-wasm32-run.patch` (with `compat/` and `cmake/wasi.cmake`) gets `js` linked and running:

- `compat/` now covers the rest of what LibCore names: rlimits (a fixed table), `sigaction` over `signal()` with
  stored masks, `kill()` of the module itself (`raise`), uid/gid 0, `mkstemp`/`mkdtemp`, `cmsghdr`/`sendmsg` and
  friends (ENOTSUP), and ENOSYS stubs for fork/exec/pipe/dup. LibThreading builds (wasi-libc's pthread stubs).
- LibCore's Unix event loop has no wake pipe on WASI: `wake()` and signals set a flag and the next wait does not block.
- Link: no ELF-only flags (`-z defs`, `--no-undefined`), no PIE, no `--build-id` (it makes wasm-ld drop the name section),
  and `--undefined=__main_argc_argv`, since crt1 reaches main by a weak reference that does not pull LibMain out of
  its archive (without it the call to main becomes `unreachable`). ICU's data symbol is `icudt78_dat` (`deps/icu.sh`).
- Runtime: the weak pointer offset, LibGC's 64-bit allocation counter, `ByteLength`'s size and the heap region check
  (`__heap_base` and up on wasm32) are pointer-width aware. Every 4-byte field gets `<OFFSET>_WIDTH = 4` in the wasm32
  layout, so the interpreter reads e.g. the VM's interpreter stack bounds as 32 bits.

Running: `python tools/wasi-run.py build/ladybird/bin/js script.js`. The LibJS runtime suite
(`test-js-runtime Tests/LibJS/Runtime Tests/LibJS/Runtime/test-common.js`, built with `BUILD_TESTING=ON`) passes
7666 of 7673 tests, the same in wasmtime (`tools/wasi-run.py`) and in latha-gui's `latha-run`. With `-g` (collect
after every allocation) every file passes when run on its own; the whole suite in one process under `-g` takes hours. 3 are expected failures on every target. The 4 that fail are buffers
wasm32 cannot hold (see [32-bit limits](#32-bit-limits)).

### 32-bit limits

`patches/0011-wasm32-index-limits.patch` and `patches/0012-wasm32-full-memory-buffers.patch` (applied last) fix the
LibJS runtime suite's failures that were bugs rather than limits:

- Property keys are one 64-bit word on every target (Rust `PropertyKey`, C++ `JS::PropertyKey`, `JSPropertyKey` in
  the embedding ABI). The word had been pointer-sized, and a number is kept shifted left by two, so on wasm32 only
  indices below 2^30 - 1 were numbers and the rest were string keys that indexed storage never saw:
  `arr[2 ** 32 - 2] = x` left `arr.length` at 0 and integer keys from 2^30 sorted among the strings. A string's raw
  word or a symbol's address sits zero-extended in the low half (wasm32 is little-endian).
- `ToIndex` results become a usize with `Value::to_index_usize`, which saturates at usize::MAX on 32-bit targets
  instead of wrapping (`as usize` made an offset of 2^32 into 0 and `new Uint8Array(2 ** 32 + 1)` into a 1-element
  array). Bounds checks after it throw as on 64-bit. Array-like lengths that size typed arrays do the same.
- The GC heap region and the ArrayBuffer cage are all 4 GiB of linear memory (it had been the low 2 GiB), and
  `cmake/wasi.cmake` links with `--max-memory=4294967296`. Their size no longer fits in a size_t, so on WASI the
  offset masks are 0xFFFFFFFF and the sizes are kept as u64 or as the last address. wasi-libc's malloc grows memory
  with `sbrk`, whose increment is signed, so it never returns 2 GiB or more: PrimitiveStorage takes ranges of
  64 MiB and up straight from `memory.grow`, in whole wasm pages, and keeps released ones for reuse (merged with their
  neighbours, extended in place when they end at the top of memory). A range is only grown while 256 MiB stay free
  above it for malloc (`patches/0016-wasm32-malloc-headroom.patch`), since malloc can never use that memory again. Buffers
  of up to about 3 GiB now work.

`patches/0015-wasm32-intrinsic-accessor-sret.patch`: C++ returns a `JS::Value` (a class around a union) through a
hidden result pointer on wasm32, so the Rust runtime calls LibWeb's intrinsic accessors (the lazily created
constructors on `window`, such as `"AbortController" in window`) the way it does on Windows, with the result pointer
first. Calling them as returning a `u64` trapped with "indirect call type mismatch".

What still fails, and why it cannot be fixed on wasm32:

- `ArrayBuffer-max-byte-length.js` (3 tests): a buffer of 2^32 bytes. That is the whole 32-bit address space, which
  also holds the program, its stack and its heap, and a usize cannot count it. Only memory64 (wasm64) would hold it,
  and there is no wasm64 WASI target: no `wasm64-wasip1` Rust standard library and no wasm64 wasi-libc in wasi-sdk,
  and the Flap C interpreter, the GC's compressed pointers and the embedding layouts all assume 32-bit addresses on
  WASI. The largest buffer is 2^32 - 64 KiB; larger lengths throw "Invalid array buffer length".
- `Uint8Array.prototype.toBase64.js` "result too long for a string": it needs a 3 GiB buffer, three quarters of the
  address space. It passes on its own and with the rest of `builtins/TypedArray/`, but in the full suite the tests
  before it have grown memory past 1 GiB (linear memory never shrinks), so the 3 GiB range does not fit.

`patches/0005-libwasm-engine-wasm32.patch` makes LibWasm's engine (`libwasm_engine`, which LibWeb's Rust bindings
depend on) build for wasm32-wasip1. The JIT is never enabled there (`jit::enabled()` is false), but the JIT crate
builds its x86-64 backend on wasm32 so the engine's glue type-checks. There is no LibWasm interpreter on wasm32 yet
(Engine/build.rs only runs flapc for x86_64/aarch64), so calling into a wasm module traps, and memories not backed by
the GC heap's primitive storage fail to allocate (WASI has no address-space reservations). Three LibWeb Rust
size asserts only hold on 64-bit targets. Running LibWasm's `interpreter.flap` through the Flap C backend needs the
WebAssembly profile, SIMD and atomics in `target/c.rs`.

`patches/0013-libwasm-interpreter-wasm32.patch` (on top of 0012) gives wasm32 a LibWasm interpreter, so a page's
WebAssembly runs inside wasm webby:

- The Flap C backend prints LibWasm's `interpreter.flap` (the WebAssembly profile) as C: its registers (`ip`, `stp`,
  `vsp`, `mb`, `sp`, `fp`) are handler parameters, the 0xFF/0xFC/0xFD/0xFB/0xFE prefixes dispatch through secondary
  tables, v128 values are two u64 halves, and the vector operations emulate the SSE instructions the x86-64 lowering
  picks exactly (lane order, saturation, `cvtt*` giving 0x80000000, NaN results). Atomics are `__atomic_*`, runtime
  helpers take the context pointer. `wasm_interpreter()` puts the interpreter's frames in an `alloca`'d region of
  the C stack (the GC scans it), and narrows the context's stack limit to that region while it runs. Rounding a
  signaling NaN quiets it, as the instructions do (libm returned it as is).
- Engine/build.rs uses it for wasm32, or natively with `LIBWASM_INTERPRETER_BACKEND=c` (then the JIT is off and
  there is no fault handler: a C handler cannot resume in another one).
- No guard pages: Module/build.rs sets `libwasm_checked_memory` for the C interpreter, and the validator quickens
  every memory access into its bounds-checked form, which reads the memory's current base and size. On 32-bit hosts
  a memory reserves only what it has grown to (at most 2 GiB) and moves when it grows past that, doubling.
- 4-byte pointers: the layout is computed on the target (like LibJS's, under `LIBJS_TARGET_RUNNER`), with
  `POINTER_SIZE` and `<NAME>_WIDTH = 4` for 4-byte fields. flapc turns `load64`/`store64` of such a field into
  `load32`/`store32`, and the interpreter reads the instance's function, table, memory, global, tag and RTT arrays
  as `Sequence<ptr<u8>>`.
- WASI stack bounds come from wasm-ld's `__stack_low`.

`tests/libwasm.sh LADYBIRD_SRC OUT` runs LibWasm's Engine tests in wasm (execution, fixtures, side tables,
validation: all pass) and the WebAssembly spec test suite (github.com/WebAssembly/testsuite, 258 scripts) with
`tools/libwasm-wast`, a .wast runner on LibWasm's Rust API, three ways: natively with the assembly interpreter,
natively with the C interpreter, and as a wasm32-wasip1 module under wasmtime (tail calls on, 64 MiB shadow stack).
All three give 63,306 passed assertions and the same 18 failures (`instance.wast`'s module definitions, which the
runner does not model); 2 scripts use text syntax the `wast` crate cannot parse.

`patches/0006-libweb-wasi.patch` builds LibWeb and the libraries it needs (LibGfx, LibMedia, LibCompositing, LibIPC,
LibTLS, LibHTTP, ...) for WASI when configured with `-DENABLE_GUI_TARGETS=ON`. There are no Services or UI; LibJS is
folded into LibWeb. It also adds `webby-render`, a one-process HTML-to-PNG renderer
(`Utilities/webby-render.cpp`). It parses a file: URL into a Page in the same process, lays it out, records the
display list, and rasterizes it on the CPU with the Compositor's Skia player sources linked in. Its deps come from
`deps/libweb-deps.sh`, `header-deps.sh`, `media-deps.sh` and `skia.sh`. Configure also needs the HSTS preload JSON in
`Build/caches/HSTSPreload/`. Fonts come from `$XDG_DATA_DIRS/fonts`, so preopen a host font dir with
`WASI_RUN_DIRS=/usr/share/fonts` (a comma list of `host[=guest]` dirs that tools/wasi-run.py preopens).

`patches/0009-webby-render-runs.patch` (on top of 0008) gets webby-render to run end to end. It renders a page with
gradients, a transform, dashed borders, web fonts from the host and a script, matching a native render:

- `AnonymousBuffer` (the palette and other shared buffers) is private anonymous memory with no fd on WASI.
- LibJS's GC pads the class pointer that shared runtime-class allocators keep after a cell to 8 bytes on 32-bit,
  which keeps cells 8-byte aligned.
- LibWeb's style/layout and paint stage threads run inline on WASI. Handing a job to a stage runs the queued jobs
  on the calling thread, in order, and `is_current()` is true while it does.
- webby-render gives its page and document cross-process ids, marks the document ready to run scripts, and leaves
  with `_exit` (the engine's global destructors trap).
- compat's `realpath` resolves lexically. wasi-libc's readlink-per-component walk fails above a nested preopen.

Run it from the Ladybird checkout like this (about a minute, mostly wasmtime compiling the 188 MB module):

    XDG_DATA_DIRS=/usr/share WASI_RUN_DIRS=/usr/share/fonts,$PWD/Base/res=/res,/path/to/page \
      python tools/wasi-run.py build/bin/webby-render --theme /res/themes/Default.ini -o /path/to/page/out.png \
      /path/to/page/index.html

What it took beyond the patches:

- GC roots in wasm locals. After every link, `cmake/wasi.cmake` runs binaryen's `wasm-opt --spill-pointers
  --stack-check` (keeping names) when `$WEBBY_WASI_SYSROOT/bin/webby-wasm-opt` exists. `deps/binaryen.sh` builds that
  from binaryen 121 with `deps/binaryen-webby.patch`: SpillPointers also spills i64 locals (NaN-boxed JS values, whose
  low 32 bits are an address), the spill area is given back before tail calls (the interpreter dispatches by
  `return_call`; without this every handler leaked stack), and `--pass-arg=stack-check-size@N` starts StackCheck's
  limits at the initial stack pointer, so an overflow of the 8 MiB shadow stack traps instead of silently overwriting
  the static data below it (it had been corrupting ICU's resource bundles).
- The wasm32 VM keeps 96 KiB of native stack in reserve, like ASan builds, since registers and spills live there.
- `tools/wasi-run.py` gives wasmtime a 256 MiB wasm stack (`max_wasm_stack`, and the async stack size, which must be
  at least as big) and runs the module on a thread with that much native stack, so Ladybird's own recursion check
  fires before the engine's.
- 32-bit AK: a short String holds 3 bytes there, so `String::from_code_point` makes a heap string for 4-byte UTF-8.
- clang runs `wasm-opt` itself after linking whenever one is on PATH (pixi has one) and that drops the name section;
  `--no-wasm-opt` stops it.

LibWeb's dependencies build for WASI too: `deps/libweb-deps.sh` (zlib, libpng, libjpeg-turbo without SIMD, brotli,
libwebp, woff2's libraries, FreeType, HarfBuzz with `HB_NO_MMAP`, libxml2, SQLite through `deps/sqlite.sh`:
single-threaded, no WAL or mmap) and `deps/media-deps.sh` (dav1d through meson with `tools/meson-wasi-cc`, libavif,
and FFmpeg 9.0.2 with only the decoders LibMedia uses, no threads, no asm). setjmp/longjmp is wasm exception handling
everywhere (`-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false`, `-lsetjmp`).

Skia (`deps/skia.sh`, the pin's e7c90ecca9, "skia 148", for the Compositor) builds for WASI as a CPU raster
library: no Ganesh/Graphite/GL/Vulkan, no PDF, FreeType with the empty font manager (no fontconfig) and Skia's
bundled FreeType, libpng and zlib, all inside one 7 MB `libskia.a`. GN runs with `target_os="linux"` and an unknown
`target_cpu="wasm32"` (GN's own "wasm" means Emscripten) plus `-DSK_BUILD_FOR_UNIX`, since clang for WASI defines
neither `__unix__` nor `__linux__`. The raster pipeline needs `-mtail-call`; SkVx uses `-msimd128`. The one source
patch is Ladybird's `010-always-build-pathops` (`deps/skia-0001-always-build-pathops.patch`). libpng and FreeType
use setjmp/longjmp, so Skia is compiled with `-mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false` and
programs linking it add `-lsetjmp` (skia.pc and the unofficial-skia CMake config say so) and need an engine with
wasm exceptions (`tools/wasi-run.py` turns them on). `compat/` has single-threaded POSIX semaphores for SkSemaphore.
`tests/skia-rect.sh` draws a rect, a path-op shape and FreeType text into an SkBitmap and writes a PNG under wasmtime.

## Networking

The module does its own networking: curl, OpenSSL and RequestServer run inside it, and the host only gives it
sockets, through the standard **wasi:sockets 0.2** interfaces (TCP, UDP, `ip-name-lookup`) with `wasi:io` streams and
pollables. There is no webby-specific host import. `compat/webby_wasi_net.c` turns them into BSD sockets for the
wasip1 libc:

- `socket`, `connect` (blocking, or non-blocking with `EINPROGRESS` and `SO_ERROR`), `bind`, `send`/`recv`
  (`MSG_PEEK`, `MSG_DONTWAIT`), `sendto`/`recvfrom` (UDP), `shutdown`, `getsockname`/`getpeername`,
  `getsockopt`/`setsockopt` (`SO_ERROR`, `SO_TYPE`, `SO_KEEPALIVE`; the rest are accepted and ignored),
  `fcntl`/`ioctl` (`O_NONBLOCK`, `FIONBIO`, `FIONREAD`), and `getaddrinfo` (numeric addresses, `localhost`, and
  names through the host's resolver), `getnameinfo` (numeric only). No `listen`/`accept` and no `AF_UNIX`.
- A socket is a descriptor from `WEBBY_NET_FD_BASE` (0x100000) up, so it works with `read`, `write`, `close` and,
  the part an event loop needs, `poll` (and `select`, which wasi-libc builds on `poll`). Those libc functions are
  wrapped with `wasm-ld --wrap` (`cmake/wasi.cmake`; `$WEBBY_WASI_SYSROOT/lib/webby_wasi_compat.ldflags` has the
  flags for other builds). `compat/webby_wasi_net_wrap.c` routes socket descriptors and passes everything else to
  libc. `poll` over sockets alone waits on their pollables with one `wasi:io/poll.poll`; mixed with wasip1
  descriptors (stdin, files) it checks those every 10 ms.
- The bindings are the ones wasi-sdk ships for wasip2 (`wasi/wasip2.h`; `wasip2.o` and `wasip2_component_type.o`
  are copied out of its wasip2 libc into `libwebby_wasi_compat.a`). The wrappers only reach the sockets code after a
  `socket()`, so a program that never makes one keeps no wasi:sockets imports and stays a plain wasip1 module.
- `WEBBY_NET_TRACE=1` prints every socket call and its result on stderr.

A program that uses sockets imports `wasi:sockets/*@0.2.0` next to `wasi_snapshot_preview1`, so it runs as a component:
`wasm-tools component new prog.wasm --adapt wasi_snapshot_preview1=wasi_snapshot_preview1.command.wasm` (wit-component
merges our 0.2.0 imports with the adapter's 0.2.6). `tools/wasi-run.py` does that on the fly (cached in
`~/.cache/webby-wasm`) and runs the component in the wasmtime CLI with
`-S inherit-network=y,allow-ip-name-lookup=y,tcp=y,udp=y`. wasmtime-py cannot: wasmtime-wasi leaves TCP and UDP off
unless the embedder calls `allow_tcp`/`allow_udp`, which its C API does not expose. The CLI is the `wasmtime`
package on nandi-testing (36.0.0, like the adapter) or `WASMTIME`; `WASM_TOOLS` and `WEBBY_WASI_ADAPTER` point at the
other two tools (the adapter is downloaded from wasmtime's release otherwise; the nandi-testing
`wasi-preview1-adapter` package is the reactor adapter, which has no `wasi:cli/run`).

latha-gui 0.3.1 (qt2wasm f287504) and its `latha-run` turn all of that on in their `WasiCtxBuilder`
(`.inherit_network().allow_ip_name_lookup(true).allow_tcp(true).allow_udp(true)`; `LATHA_GUI_NETWORK=0` turns it
off). They take the component, not the wasip1 module.

curl (`deps/curl.sh`, 8.23.0 as Ladybird pins it) builds with what Ladybird's vcpkg.json asks of it: OpenSSL, HTTP/2
(nghttp2 1.70.0), HTTP/3 (ngtcp2 1.16.0 + nghttp3 1.11.0, with ngtcp2's `ngtcp2_crypto_ossl` on OpenSSL's QUIC TLS
API), brotli, zstd, zlib and WebSockets; `deps/net-deps.sh` builds zstd and the nghttp/ngtcp libraries first (zlib and
brotli come from `deps/libweb-deps.sh`). It uses the synchronous resolver and no socketpair (so no
`curl_multi_wakeup`). `tests/net.sh OUT` checks `tests/net-fetch.c` against a local HTTP server (300 KB body), a local
UDP echo, a refused port and an unresolvable name, and with `CURL=curl.wasm` fetches https://example.com/ with
certificate checks (`--dir /etc/ssl`) over HTTP/1.1 and HTTP/2 (200, verify result 0), and https://localhost from a
local HTTP/3 server (`tests/h3-server.py`, PyPI aioquic): QUIC over UDP, 72000 bytes. A 623 KB Wikipedia page comes in
at about 2.8 MB/s under wasmtime.

RequestServer (`patches/0007-requestserver-wasi.patch`, on top of 0006, with `ENABLE_GUI_TARGETS=ON`) builds for WASI:
`Services/RequestServer` plus LibSandbox (`SandboxUnimplemented.cpp`) and LibWebSocket, curl found as a CMake package.
LibThreading's ThreadPool has no threads on WASI: `submit()` runs the job as a task on the submitting thread's event
loop, which is how LibDNS's system resolver (`getaddrinfo`) works in one thread. `RequestServer.wasm` links and starts,
then waits for the IPC socket its parent hands it, which [IPC](#ipc) below provides.

What runs is RequestServer's network path without IPC: `requestserver-fetch URL...` (`Utilities/requestserver-fetch.cpp`)
resolves through RequestServer's `Resolver` (LibDNS), pins the addresses with `CURLOPT_RESOLVE`, and drives one curl
multi handle from the LibCore event loop with a `Core::Notifier` per socket and a `Core::Timer`, as
`ConnectionFromClient` does. Several URLs go at once. `tests/net.sh` with `RS_FETCH=build/bin/requestserver-fetch`
checks a local 300 KB body byte for byte, an unresolvable name, and https://example.com/ with https://www.google.com/
at the same time over HTTP/2 with certificate checks (`-C /etc/ssl/certs/ca-certificates.crt`).

## IPC

Ladybird's processes talk over LibIPC, whose `TransportSocket` is a Unix socket with descriptors passed along
(`SCM_RIGHTS`) and an IO thread. In wasm both pieces are replaced, and the processes are wasm instances:

- **Local sockets** (`compat/webby_wasi_local.c`): `socketpair()` (stream, seqpacket, datagram), `pipe()`, and
  `sendmsg`/`recvmsg` with `SCM_RIGHTS`, as descriptors from `WEBBY_LOCAL_FD_BASE` (0x200000) that `read`, `write`,
  `poll`, `fcntl`, `ioctl(FIONREAD)` and `fstat` (`S_IFSOCK`) know. An endpoint is shared by every descriptor and
  in-flight message that refers to it, and its peer reads EOF once the last goes. In memory, a write never blocks
  (the reader is this same thread) and a read that would block fails with `EAGAIN`; a file or wasi:sockets
  descriptor passed within the instance keeps its number, and `close()` only closes it with its last holder.
- **latha:proc channels** (`compat/webby_wasi_latha.c`, in `libwebby_wasi_latha.a`): a program linked with
  `${WEBBY_WASI_LATHA_LINK_OPTIONS}` (`cmake/wasi.cmake`) makes every `socketpair()` a latha:proc channel
  (latha-gui/latha-run 0.3.1, qt2wasm's `proc/wit/proc.wit`, through wit-bindgen's C bindings in
  `compat/latha-proc/`, so one component has both latha:proc and wasi:sockets). A write is one channel message and
  the descriptors passed with it must be channel endpoints: they move to the receiver, which may be another instance.
  `poll()` waits on channels with latha's `wait`, in 2 ms slices when wasi:sockets or wasip1 descriptors are in the set
  too. `webby_local_spawn()` starts a wasm program as a child with a socket to it, and the child's LibCore takes that
  socket over as its `ipc` socket (`webby_local_parent_fd()`, `SystemServerTakeover.cpp`), where a native Ladybird
  process has `SOCKET_TAKEOVER`. Such a program needs a latha host and runs as a component.
- **The thread-less transport** (`patches/0008-ipc-wasi.patch`): on WASI `TransportSocket` has no IO thread. A
  `Core::Notifier` reads the socket on the event loop and calls the connection's hook; a posted message is written
  right away (and the rest when the socket is writable again); `flush()` and the synchronous-request wait poll the
  socket. When the peer is in this instance's memory, the wait runs the event loop for a round instead, so the peer
  can answer; messages that come in meanwhile wait for the caller, not the connection's hook (which would drop the
  response). Payloads up to 64 MiB go through the socket, since there is no shared memory to put big ones in.
  `AK::ThreadID` is 1 on WASI, so the connections' owner-thread checks hold.

`Utilities/requestserver-ipc.cpp` fetches URLs through `Requests::RequestClient`, the way WebContent does: a control
connection (`RequestControlClient` to RequestServer's `ControlConnectionFromClient`), the synchronous
`connect_new_client()` that hands back a new transport, and response bodies through the descriptor RequestServer
passes along. `requestserver-ipc` runs RequestServer's side in the same module over an in-memory socketpair (run it
with `tools/wasi-run.py`); `requestserver-ipc-latha --spawn RequestServer.wasm` starts `RequestServer.wasm` as a child
instance under latha-run and talks to it over a channel. `tests/ipc.sh BUILD OUT` checks a 300 KB body byte for byte
both ways (`HTTPS=1` adds https://example.com/), and `tests/local-sockets.sh OUT` checks the sockets themselves, in
memory under wasmtime and over channels with a child instance under latha-run.

Not yet: shared memory (`Core::AnonymousBuffer`, which bitmaps between WebContent and the UI use; latha:proc has none
either), files passed to another instance (only channel endpoints can move), and spawning Ladybird's helpers from
LibWebView (`Core::Process` on WASI).

## Pages over the network

`patches/0010-webby-render-network.patch` connects LibWeb to RequestServer in webby-render, so it renders an http(s)
URL as well as a file. It is wired the way WebContent is: a `RequestControlClient`, `connect_new_client()`, and the
`Requests::RequestClient` that comes back is the client of `Web::ResourceLoader` for every site. The document itself,
its style sheets, scripts, images, fonts and the page's own `fetch()`es all go through it; file: and data: URLs still
load inside LibWeb. RequestServer runs in the same module over an in-memory socketpair (`webby-render`), or as
`RequestServer.wasm` in a latha:proc child instance (`webby-render-latha --spawn RequestServer.wasm`).

- The document is fetched straight from RequestServer, redirects followed in webby-render, and parsed into a document
  made directly as before (no navigation), with the final URL's origin, and the encoding from Content-Type, a BOM or
  `<meta charset>`. `-C` names the CA bundle, `--timeout` (60 s) paints what there is when a page never finishes.
- Images are decoded in the module with LibGfx's decoders (an in-process `ImageCodecPlugin`; every frame up front).
- webby-render uses sockets now, so it runs as a component (`wasm-tools component new --adapt` with the preview1
  command adapter). Run it with latha-run or tools/wasi-run.py with `WASMTIME` set to a wasmtime 40 CLI; nandi-testing's
  wasmtime 36 rejects the exception instructions, and wasmtime-py alone gives components no TCP (fine for files).

`tests/webby-render-net.sh BUILD LADYBIRD OUT` serves a page from a local HTTP server whose background is in a style
sheet, whose red square is a PNG and whose green bar only appears once a `fetch()` has read a text file, and checks those
pixels both ways under latha-run; `HTTPS=1` also renders https://example.com/ both ways. The wasm-engine job runs it.

    wasm-tools component new build/bin/webby-render --adapt wasi_snapshot_preview1=wasi_snapshot_preview1.command.wasm \
      -o webby-render.wasm
    latha-run --dir /usr/share/fonts --dir $PWD/Base/res::/res --dir /etc/ssl webby-render.wasm \
      --theme /res/themes/Default.ini -C /etc/ssl/certs/ca-certificates.crt -o out.png https://example.com/

## The Qt UI

`ui/` is webby's browser window for latha-gui: QtGui chrome (tab strip, back/forward/reload, address field, link
status bubble, all drawn with QPainter on a `QRasterWindow`) and Ladybird's LibWeb in one latha:gui component,
`bin/webby.wasm`. There is no WebContent or Compositor: `ui/WebView.cpp` owns a `Web::Page` per tab, parses each
document straight into it (top-level navigations come back through `PageClient::request_navigation_start`), paints
its display list with the Compositor's Skia CPU player and hands the pixels to Qt. Mouse, wheel and keys go to
`Page::handle_*`. file: pages and the built-in start page load; http(s) is not wired into the UI yet (patch 0010 has
it for webby-render). Ctrl+T/W/L/R, F5, Alt+Left/Right and Ctrl+Tab work.

It builds inside Ladybird's WASI build (`patches/0014-webby-ui.patch` adds the directory when `WEBBY_UI_DIR` names it),
with Qt for WASI, qt2wasm, wit-bindgen, wasm-tools and the preview1 reactor adapter from this pixi env:

    ENABLE_GUI_TARGETS=ON pixi run ./build-engine.sh <ladybird> build/ladybird webby-ui
    latha-gui --dir <ladybird>/Base/res::/res build/ladybird/bin/webby.wasm [file or URL ...]

Tested headless with latha-gui's `--screenshot`/`--type` plus the UI's own test input, `--click=X,Y@MS` and
`--wheel=DY@MS` (window pixels, milliseconds after start): typing a path in the address bar loads it and runs its
scripts, links navigate, back/forward, the + button and tab clicks work, and the wheel scrolls the page (on the main
thread, since Ladybird scrolls in its Compositor process, and painted with the document's scroll-state snapshot).
Not yet: http(s) in the UI, scroll and `requestAnimationFrame` callbacks (nothing drives LibWeb's rendering steps
without a Compositor), wheel scrolling of inner scroll containers.

    QT_QPA_PLATFORM=offscreen latha-gui --dir <ladybird>/Base/res::/res --size 1100x760 --screenshot out.png \
      --quit-after 12000 build/ladybird/bin/webby.wasm page.html --click=95,315@5000

`latha-gui webby.wasm` needs nothing else: Ladybird's default theme and the Liberation fonts are built in
(`ui/Resources.c`, `#embed`; `patches/0017-builtin-fonts-and-theme.patch` adds `PathFontProvider::add_typeface` and
`ConfigFile::open_from_text`, and skips font directories the sandbox refuses). A `/res` (or `WEBBY_RESOURCES`) with
Ladybird's Base/res takes over the theme, and system font directories add their fonts.

## Building what exists

```sh
pixi install
export WASI_SDK_PREFIX=$PWD/.pixi/envs/default/opt/wasi-sdk WEBBY_WASI_SYSROOT=$PWD/build/sysroot
pixi run compat/build.sh
pixi run deps/icu.sh <icu>/icu4c/source build/icu "$WEBBY_WASI_SYSROOT"
pixi run deps/openssl.sh <openssl> build/openssl "$WEBBY_WASI_SYSROOT"
pixi run deps/libpsl.sh <libpsl> build/psl "$WEBBY_WASI_SYSROOT"
pixi run deps/cmake-dep.sh <src> build/<name> [cmake args]   # fast_float, zmij, simdutf, libtommath, mimalloc
pixi run deps/libweb-deps.sh <src dir> build   # checkouts of zlib, libpng, ... sqlite in <src dir>
pixi run deps/media-deps.sh <src dir> build    # dav1d, libavif, ffmpeg; needs meson
pixi run deps/net-deps.sh <src dir> build/net  # zstd, nghttp2, nghttp3, ngtcp2 (after OpenSSL)
pixi run deps/curl.sh <curl> build/curl        # after those and libweb-deps (zlib, brotli)
deps/binaryen.sh build/binaryen "$WEBBY_WASI_SYSROOT"   # host wasm-opt, before configuring Ladybird
git clone https://skia.googlesource.com/skia <skia> && git -C <skia> checkout e7c90ecca9444fe09598f1630ab7cee2c0ee027a
pixi run deps/skia.sh <skia> build/skia "$WEBBY_WASI_SYSROOT"   # fetches gn + FreeType/libpng/zlib by git
pixi run tests/skia-rect.sh build/skia-test /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
rustup target add wasm32-wasip1 --toolchain "$(sed -n 's/channel = "\(.*\)"/\1/p' <ladybird>/rust-toolchain.toml)"
pip install wasmtime   # for tools/wasi-run.py
export LIBJS_TARGET_RUNNER="python $PWD/tools/wasi-run.py"
pixi run ./build-engine.sh <ladybird with ../patches and patches/ applied> build/ladybird js
python tools/wasi-run.py build/ladybird/bin/js -c 'print(6 * 7)'
CURL=build/curl/src/curl pixi run tests/net.sh build/net-test   # sockets; needs wasmtime + wasm-tools
pixi run tests/local-sockets.sh build/local-sockets   # local sockets; wasmtime, wasm-tools, latha-run (latha-gui 0.3.1+)
ENABLE_GUI_TARGETS=ON pixi run ./build-engine.sh <ladybird> build/ladybird RequestServer requestserver-ipc requestserver-ipc-latha
tests/ipc.sh build/ladybird build/ipc-test                       # IPC in one module, then RequestServer.wasm as a child
```

Sources come from git (the versions Ladybird's vcpkg.json pins); GitHub release archives are not needed.

`deps/all.sh SRC WORK [stage...]` does every dependency step above in order, from the checkouts it makes of
`deps/sources.txt` (the versions Ladybird's vcpkg.json pins).

## Forge CI

Two jobs in `../.forge/jobs.toml` build this on the fileapi forge (nandi.uk/webby), each a `depot build` whose
BuildKit cache mounts Depot keeps between runs (`ci/forge_wasm.py`):

- `wasm-deps` runs `deps/all.sh` (`ci/deps.Dockerfile`, one layer per stage) and publishes the sysroot as
  `webby-wasi-sysroot-<key>.tar.zst` on the rolling `wasm-deps` release. `<key>` hashes `deps/`, `compat/`,
  `cmake/`, `tools/meson-wasi-cc`, `ci/deps.Dockerfile` and `ci/base.sh` (`python3 ci/forge_wasm.py key`); when
  the asset is already there the job builds nothing. Unpack it with `tar -C /opt -I zstd -xf ...`: it is
  `/opt/webby-wasi`, the path its `.pc` and CMake files name.
- `wasm-engine` (after `wasm-deps`) checks out `../LADYBIRD_COMMIT`, applies `../patches/*` and `patches/*`, runs
  `build-engine.sh` for the targets in `ci/engine-targets` (`ci/engine.sh`), smoke-tests `js.wasm` and publishes
  `<target>.wasm`, `SHA256SUMS` and the build log on the rolling `wasm-engine` release. The checkout and build
  directory live in Depot's cache, and a build that would pass the forge's one-hour limit stops in time and starts
  the job again, which carries on where it stopped.

The image (`ci/base.sh`): Ubuntu 24.04, wasi-sdk 27 in `/opt/wasi-sdk`, CMake/Ninja/Meson and PyPI wasmtime in
`/opt/venv`, Ladybird's Rust toolchain with wasm32-wasip1.
