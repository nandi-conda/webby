# webby in WebAssembly (work in progress)

Goal: all of webby, the Ladybird engine and a Qt UI, as WebAssembly built with
[qt2wasm](https://fileapi.fastapicloud.dev/forge/nandi.uk/qt2wasm) (Qt 6 for WASI, wasm32-wasip1) and run by a
latha:gui host. Not usable yet.

| Path | What |
| --- | --- |
| `pixi.toml` | the toolchain: qt2wasm (wasi-sdk 27, Qt for WASI), CMake, Ninja, Rust |
| `cmake/wasi.cmake` | CMake toolchain for wasm32-wasip1 with wasi-libc's emulation libraries and `compat/` |
| `compat/` | `netdb.h` and the POSIX pieces wasi-libc lacks (socket calls fail with ENOTSUP, one time zone) |
| `deps/` | scripts that build Ladybird's dependencies for WASI into a sysroot (`WEBBY_WASI_SYSROOT`) |
| `patches/` | Ladybird changes for a WASI build, on top of `../LADYBIRD_COMMIT` and `../patches/` |
| `tools/wasi-run.py` | runs a wasm32-wasip1 program with PyPI wasmtime (`LIBJS_TARGET_RUNNER` for the layout generator) |
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

## Building what exists

```sh
pixi install
export WASI_SDK_PREFIX=$PWD/.pixi/envs/default/opt/wasi-sdk WEBBY_WASI_SYSROOT=$PWD/build/sysroot
pixi run compat/build.sh
pixi run deps/icu.sh <icu>/icu4c/source build/icu "$WEBBY_WASI_SYSROOT"
pixi run deps/openssl.sh <openssl> build/openssl "$WEBBY_WASI_SYSROOT"
pixi run deps/libpsl.sh <libpsl> build/psl "$WEBBY_WASI_SYSROOT"
pixi run deps/cmake-dep.sh <src> build/<name> [cmake args]   # fast_float, zmij, simdutf, libtommath, mimalloc
rustup target add wasm32-wasip1 --toolchain "$(sed -n 's/channel = "\(.*\)"/\1/p' <ladybird>/rust-toolchain.toml)"
pip install wasmtime   # for tools/wasi-run.py
export LIBJS_TARGET_RUNNER="python $PWD/tools/wasi-run.py"
pixi run ./build-engine.sh <ladybird with ../patches and patches/ applied> build/ladybird js
```

Sources come from git (the versions Ladybird's vcpkg.json pins); GitHub release archives are not needed.
