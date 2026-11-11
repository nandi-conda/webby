#!/usr/bin/env bash
# Builds tests/local-sockets.c twice and runs it: in memory (wasmtime, or tools/wasi-run.py) and with the latha:proc
# backend as a component under latha-run (latha-gui 0.3.1+), where it also starts a child instance.
#   tests/local-sockets.sh OUT_DIR
# env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT (with compat/build.sh's libraries), WASMTIME, LATHA_RUN, WASM_TOOLS,
#      WEBBY_WASI_ADAPTER (wasi_snapshot_preview1.command.wasm)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); out=$1; mkdir -p "$out"
sdk=${WASI_SDK_PREFIX:?}; sys=${WEBBY_WASI_SYSROOT:?}
cc() { "$sdk/bin/clang" --target=wasm32-wasip1 -O2 -D_WASI_EMULATED_SIGNAL -isystem "$sys/include" -include webby_wasi_compat.h "$@" $(cat "$sys/lib/webby_wasi_compat.ldflags") -lwasi-emulated-signal; }
cc "$here/local-sockets.c" -o "$out/local-sockets.wasm"
cc "$here/local-sockets.c" -o "$out/local-sockets-latha.core.wasm" -lwebby_wasi_latha -Wl,--undefined=webby_latha_backend_ops
"${WASM_TOOLS:-wasm-tools}" component new "$out/local-sockets-latha.core.wasm" \
  --adapt "wasi_snapshot_preview1=${WEBBY_WASI_ADAPTER:?}" -o "$out/local-sockets-latha.wasm"
(cd "$out" && "${WASMTIME:-wasmtime}" run --dir . local-sockets.wasm)
(cd "$out" && "${LATHA_RUN:-latha-run}" local-sockets-latha.wasm)
