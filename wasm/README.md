# webby in WebAssembly (work in progress)

Goal: all of webby, the Ladybird engine and a Qt UI, as WebAssembly built with
[qt2wasm](https://fileapi.fastapicloud.dev/forge/nandi.uk/qt2wasm) (Qt 6 for WASI, wasm32-wasip1) and run by a
latha:gui host. Not usable yet.

| Path | What |
| --- | --- |
| `pixi.toml` | the toolchain: qt2wasm (wasi-sdk 27, Qt for WASI), CMake, Ninja, Rust |
| `cmake/wasi.cmake` | CMake toolchain for wasm32-wasip1 with wasi-libc's emulation libraries and `compat/` |
| `compat/` | `netdb.h` and the POSIX pieces wasi-libc lacks (one time zone), and TCP/UDP sockets over wasi:sockets (`webby_wasi_net.c`) |
| `deps/` | scripts that build Ladybird's dependencies for WASI into a sysroot (`WEBBY_WASI_SYSROOT`) |
| `patches/` | Ladybird changes for a WASI build, on top of `../LADYBIRD_COMMIT` and `../patches/` |
| `tests/` | small wasm programs that check a dependency works (`tests/skia-rect.sh`, `tests/net.sh`) |
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
7654 of 7668 tests in wasmtime, and `-g` (collect after every allocation) passes too. The 11 failures are 32-bit
limits: ArrayBuffers of 2 GiB and more, typed array lengths past 2^32, and two index edge cases (array length 2^32-1,
the order of `-1` among numeric property names).

`patches/0005-libwasm-engine-wasm32.patch` makes LibWasm's engine (`libwasm_engine`, which LibWeb's Rust bindings
depend on) build for wasm32-wasip1. The JIT is never enabled there (`jit::enabled()` is false), but the JIT crate
builds its x86-64 backend on wasm32 so the engine's glue type-checks. There is no LibWasm interpreter on wasm32 yet
(Engine/build.rs only runs flapc for x86_64/aarch64), so calling into a wasm module traps, and memories not backed by
the GC heap's primitive storage fail to allocate (WASI has no address-space reservations). Three LibWeb Rust
size asserts only hold on 64-bit targets. Running LibWasm's `interpreter.flap` through the Flap C backend needs the
WebAssembly profile, SIMD and atomics in `target/c.rs`.

`patches/0006-libweb-wasi.patch` builds LibWeb and the libraries it needs (LibGfx, LibMedia, LibCompositing, LibIPC,
LibTLS, LibHTTP, ...) for WASI when configured with `-DENABLE_GUI_TARGETS=ON`. There are no Services or UI; LibJS is
folded into LibWeb. It also adds `webby-render`, a one-process HTML-to-PNG renderer
(`Utilities/webby-render.cpp`). It parses a file: URL into a Page in the same process, lays it out, records the
display list, and rasterizes it on the CPU with the Compositor's Skia player sources linked in. Its deps come from
`deps/libweb-deps.sh`, `header-deps.sh`, `media-deps.sh` and `skia.sh`. Configure also needs the HSTS preload JSON in
`Build/caches/HSTSPreload/`. Fonts come from `$XDG_DATA_DIRS/fonts`, so preopen a host font dir with
`WASI_RUN_DIRS=/usr/share/fonts` (a comma list of `host[=guest]` dirs that tools/wasi-run.py preopens).

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

The module does its own networking: curl, OpenSSL and (later) RequestServer run inside it, and the host only gives it
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
