#!/usr/bin/env bash
# RequestServer over IPC in wasm (patches/0008): requestserver-ipc fetches a 300 KB body from a local HTTP server
# through Requests::RequestClient, first with RequestServer in the same module (a socketpair in memory, under
# wasmtime via tools/wasi-run.py), then with RequestServer.wasm as a latha:proc child instance (latha-run). Both
# bodies must match byte for byte. With HTTPS=1 it also fetches https://example.com/ both ways.
#   tests/ipc.sh BUILD_DIR OUT_DIR      (BUILD_DIR/bin has RequestServer, requestserver-ipc, requestserver-ipc-latha)
# env: WASM_TOOLS, WEBBY_WASI_ADAPTER (wasi_snapshot_preview1.command.wasm), LATHA_RUN, and what tools/wasi-run.py needs
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); bin=$(cd "$1/bin" && pwd); mkdir -p "$2"; out=$(cd "$2" && pwd)
head -c 300000 /dev/urandom > "$out/body.bin"
port=$((20000 + RANDOM % 20000))
(cd "$out" && exec python3 -m http.server "$port" --bind 127.0.0.1 > http.log 2>&1) & server=$!
trap 'kill $server 2>/dev/null' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done
url=http://127.0.0.1:$port/body.bin
extra=(); dirs=(); if [ "${HTTPS:-0}" = 1 ]; then extra=(https://example.com/ -C /etc/ssl/certs/ca-certificates.crt); dirs=(--dir /etc/ssl); fi

echo "== in one module"
(cd "$out" && WASI_RUN_DIRS=/etc/ssl python3 "$here/../tools/wasi-run.py" "$bin/requestserver-ipc" -o one.bin "$url" "${extra[@]}")
cmp "$out/one.bin" "$out/body.bin"

echo "== RequestServer.wasm in a child instance"
for p in RequestServer requestserver-ipc-latha; do
  "${WASM_TOOLS:-wasm-tools}" component new "$bin/$p" --adapt "wasi_snapshot_preview1=${WEBBY_WASI_ADAPTER:?}" -o "$out/$p.wasm"
done
(cd "$out" && "${LATHA_RUN:-latha-run}" "${dirs[@]}" requestserver-ipc-latha.wasm --spawn RequestServer.wasm -o two.bin "$url" "${extra[@]}")
cmp "$out/two.bin" "$out/body.bin"
echo "ipc: ok"
