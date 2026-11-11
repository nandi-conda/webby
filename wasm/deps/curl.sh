#!/usr/bin/env bash
# curl (Ladybird's RequestServer) for wasm32-wasip1 with OpenSSL, over compat's sockets (wasi:sockets).
# usage: curl.sh SRC BUILD      env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT (OpenSSL from deps/openssl.sh installed there)
# Builds libcurl and the curl tool (a handy network test: tests/net.sh). The synchronous resolver is used (no threads);
# RequestServer resolves names itself and hands curl addresses (CURLOPT_RESOLVE). No socketpair, so no
# curl_multi_wakeup (the module has one thread).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
"$here/cmake-dep.sh" "$1" "$2" \
  -DCURL_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR="${WEBBY_WASI_SYSROOT:?}" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DBUILD_CURL_EXE=ON -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DBUILD_EXAMPLES=OFF \
  -DENABLE_THREADED_RESOLVER=OFF -DENABLE_UNIX_SOCKETS=OFF -DENABLE_IPV6=ON \
  -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF \
  -DUSE_LIBIDN2=OFF -DUSE_NGHTTP2=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_USE_GSSAPI=OFF \
  -DCURL_DISABLE_SOCKETPAIR=ON -DHAVE_SOCKETPAIR=OFF -DHAVE_SYS_UN_H=OFF \
  -DCURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt -DCURL_CA_PATH=none
