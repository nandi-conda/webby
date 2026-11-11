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
| `build-engine.sh` | configures and builds Ladybird for wasm32-wasip1 (target `js` for now) |

## Status (2026-11-11)

Dependencies build for WASI: ICU 78.3 (data compiled in), OpenSSL 3.6.5, mimalloc 2.2.7, simdutf 9.1.1,
fast_float 8.3.1, zmij 1.2 (`deps/zmij-array-bounds.patch`), libtommath 1.3.0, libpsl 0.21.5. Ladybird configures in
WASI mode (`patches/0001-wasi-build-mode.patch`: only the libraries `js` needs, `AK_OS_WASI`, a software `f16`).

Two blockers on the current pin, both being worked on:

1. LibJS's interpreter is `Libraries/LibJS/Interpreter/interpreter.flap`, compiled by Flap (`Libraries/LibJS/Flap`)
   to x86-64 or arm64 machine code only. Plan: a C backend for Flap (handlers as C functions chained with
   `[[clang::musttail]]`, which becomes wasm tail calls).
2. LibGC reserves a 32 GiB heap region for 32-bit compressed cell pointers, and the Rust runtime asserts 64-bit
   pointers. Plan: on wasm32 a compressed pointer is the address itself (base 0, shift 0), and the runtime's layouts
   follow the target.

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
pixi run ./build-engine.sh <ladybird with ../patches and patches/ applied> build/ladybird js
```

Sources come from git (the versions Ladybird's vcpkg.json pins); GitHub release archives are not needed.
