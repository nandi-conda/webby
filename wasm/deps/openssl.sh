#!/usr/bin/env bash
# OpenSSL (Ladybird's LibCrypto/LibTLS) for wasm32-wasip1: static, no asm, threads, sockets or engines.
# usage: openssl.sh SRC BUILD PREFIX     env: WASI_SDK_PREFIX
set -euo pipefail
src=$(realpath "$1"); mkdir -p "$2" "$3"; build=$(realpath "$2"); prefix=$(realpath "$3")
sdk=${WASI_SDK_PREFIX:?}
cd "$build"
emu="-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID"
if [ ! -f Makefile ]; then
  CC="$sdk/bin/clang --target=wasm32-wasip1" AR="$sdk/bin/llvm-ar" RANLIB="$sdk/bin/llvm-ranlib" \
  "$src/Configure" linux-generic32 --prefix="$prefix" --libdir=lib --openssldir=/etc/ssl \
    no-asm no-threads no-shared no-dso no-sock no-afalgeng no-ui-console no-tests no-apps no-docs \
    no-secure-memory no-async no-dgram no-quic no-ktls -DOPENSSL_NO_SECURE_MEMORY $emu -O2 > configure.log 2>&1 \
    || { tail -20 configure.log; exit 1; }
fi
make -j"$(nproc)" build_libs > make.log 2>&1 || { grep -m5 -B2 -A6 "error" make.log; exit 1; }
make install_dev > install.log 2>&1
echo "OpenSSL for WASI in $prefix"
