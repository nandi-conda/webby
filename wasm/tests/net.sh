#!/usr/bin/env bash
# Networking in the wasm module (compat/webby_wasi_net.c over wasi:sockets), run by tools/wasi-run.py:
#  1. tests/net-fetch.c against a local HTTP server (TCP, 300 KB body), a local UDP echo server, a refused port and a
#     name that does not resolve;
#  2. with CURL=path/to/curl.wasm (deps/curl.sh), curl + OpenSSL fetching an HTTPS URL (default https://example.com/,
#     NET_URL to change; needs outbound HTTPS) with certificate checks.
# usage: net.sh OUT_DIR      env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT, and what tools/wasi-run.py needs for components
#        (WASMTIME or wasmtime on PATH, WASM_TOOLS or wasm-tools on PATH)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sdk=${WASI_SDK_PREFIX:?}; sysroot=${WEBBY_WASI_SYSROOT:?}
mkdir -p "$1/www"; out=$(realpath "$1")
emu="-D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID"
# shellcheck disable=SC2046,SC2086
"$sdk/bin/clang" --target=wasm32-wasip1 -O2 -D_GNU_SOURCE $emu -isystem "$sysroot/include" \
    -include "$sysroot/include/webby_wasi_compat.h" "$here/tests/net-fetch.c" -o "$out/net-fetch.wasm" \
    $(cat "$sysroot/lib/webby_wasi_compat.ldflags") \
    -lwasi-emulated-mman -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid
run() { python3 "$here/tools/wasi-run.py" "$@"; }
cd "$out"
head -c 300000 /dev/urandom > www/big.bin
python3 -m http.server 18765 --bind 127.0.0.1 --directory www > http.log 2>&1 &
http=$!
python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 18766)); s.settimeout(30)
data, addr = s.recvfrom(512); s.sendto(b"echo: " + data, addr)' &
udp=$!
trap 'kill $http $udp 2>/dev/null || true' EXIT
sleep 1
fails=0
check() { local name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi; }
t_tcp() { run net-fetch.wasm localhost 18765 /big.bin | grep -q '^300000 bytes of body'; }
t_udp() { run net-fetch.wasm -u 127.0.0.1 18766 | grep -q 'udp reply: echo: ping'; }
t_refused() { { run net-fetch.wasm 127.0.0.1 1 2>&1 || true; } | grep -q 'Connection refused'; }
t_noname() { { run net-fetch.wasm nonexistent.invalid 80 2>&1 || true; } | grep -q 'getaddrinfo nonexistent.invalid: Name does not resolve'; }
check "tcp: local http, 300000-byte body" t_tcp
check "udp: connected socket, echo" t_udp
check "tcp: refused port fails" t_refused
check "dns: unresolvable name fails" t_noname
if [ -n "${CURL:-}" ]; then
    url=${NET_URL:-https://example.com/}
    dirs=(--dir /etc/ssl)
    # A CA bundle named by the environment (CURL_CA_BUNDLE, SSL_CERT_FILE) has to be visible in the module too.
    for f in "${CURL_CA_BUNDLE:-}" "${SSL_CERT_FILE:-}"; do [ -n "$f" ] && dirs+=(--dir "$(dirname "$f")"); done
    cp "$CURL" curl.wasm
    t_curl() { run "${dirs[@]}" curl.wasm -sS --noproxy '*' -o page.html -w '%{http_code} %{ssl_verify_result} %{size_download}\n' "$url" | tee curl.out | grep -q '^200 0 '; }
    check "curl+openssl: $url" t_curl
    echo "     status, certificate check, bytes: $(cat curl.out 2>/dev/null)"
fi
exit $fails
