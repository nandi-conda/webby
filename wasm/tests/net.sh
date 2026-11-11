#!/usr/bin/env bash
# Networking in the wasm module (compat/webby_wasi_net.c over wasi:sockets), run by tools/wasi-run.py:
#  1. tests/net-fetch.c against a local HTTP server (TCP, 300 KB body), a local UDP echo server, a refused port and a
#     name that does not resolve;
#  2. with CURL=path/to/curl.wasm (deps/curl.sh), curl + OpenSSL fetching an HTTPS URL (default https://example.com/,
#     NET_URL to change; needs outbound HTTPS) with certificate checks, over HTTP/1.1 and HTTP/2, and HTTP/3 (QUIC over
#     UDP) from a local aioquic server (tests/h3-server.py; skipped without `pip install aioquic`);
#  3. with RS_FETCH=path/to/requestserver-fetch (patches/0007, build-engine.sh with ENABLE_GUI_TARGETS=ON), RequestServer's
#     resolver and curl multi handle on the LibCore event loop: the local 300 KB body, an unresolvable name, and
#     NET_URL plus a second HTTPS URL (NET_URL2, default https://www.google.com/) fetched at the same time.
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
    t_h2() { run "${dirs[@]}" curl.wasm -sS --noproxy '*' --http2 --compressed -o page2.html -w '%{http_version} %{http_code}\n' "$url" | grep -q '^2 200$'; }
    check "curl http/2: $url" t_h2
    if python3 -c 'import aioquic' 2> /dev/null; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout h3-key.pem -out h3-cert.pem \
            -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost 2> /dev/null
        python3 "$here/tests/h3-server.py" 18443 h3-cert.pem h3-key.pem 60 > h3.log 2>&1 &
        h3=$!
        sleep 1
        t_h3() { run curl.wasm -sS --noproxy '*' --http3-only --cacert h3-cert.pem -o page3.txt -w '%{http_version} %{http_code} %{size_download} %{ssl_verify_result}\n' https://localhost:18443/ | grep -q '^3 200 72000 0$'; }
        check "curl http/3 (QUIC, local aioquic)" t_h3
        kill $h3 2> /dev/null || true
    else
        echo "skip curl http/3 (pip install aioquic)"
    fi
fi
if [ -n "${RS_FETCH:-}" ]; then
    cp "$RS_FETCH" rs-fetch.wasm
    t_rs_local() { run rs-fetch.wasm -o rs-big.bin http://localhost:18765/big.bin | grep -q ' 200 300000 0 ' && cmp -s rs-big.bin www/big.bin; }
    check "requestserver-fetch: local http, 300000-byte body" t_rs_local
    t_rs_noname() { { run rs-fetch.wasm https://nonexistent.invalid/ 2>&1 || true; } | grep -q 'DNS lookup for nonexistent.invalid failed'; }
    check "requestserver-fetch: unresolvable name fails" t_rs_noname
    url=${NET_URL:-https://example.com/}; url2=${NET_URL2:-https://www.google.com/}
    # NB: no proxy here: the module connects to the sites itself, as curl.wasm does with --noproxy.
    t_rs_https() { env -u https_proxy -u HTTPS_PROXY python3 "$here/tools/wasi-run.py" --dir /etc/ssl rs-fetch.wasm \
        -C /etc/ssl/certs/ca-certificates.crt "$url" "$url2" | tee rs.out | grep -c ' 200 [0-9]* 0 http/2$' | grep -q '^2$'; }
    check "requestserver-fetch: $url + $url2 at once, http/2" t_rs_https
    sed 's/^/     /' rs.out 2>/dev/null || true
fi
exit $fails
