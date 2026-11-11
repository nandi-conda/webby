#!/usr/bin/env bash
# curl (Ladybird's RequestServer) for wasm32-wasip1 with the features Ladybird's vcpkg.json asks for: OpenSSL, HTTP/2
# (nghttp2), HTTP/3 (ngtcp2 + nghttp3 over OpenSSL's QUIC TLS API), brotli, zstd, zlib, WebSockets. Sockets are
# compat's (wasi:sockets).
# usage: curl.sh SRC BUILD      env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT (OpenSSL from deps/openssl.sh, zlib and brotli
#        from deps/libweb-deps.sh, zstd/nghttp2/nghttp3/ngtcp2 from deps/net-deps.sh installed there)
# Builds libcurl and the curl tool (a handy network test: tests/net.sh). The synchronous resolver is used (no threads);
# RequestServer resolves names itself and hands curl addresses (CURLOPT_RESOLVE). No socketpair, so no
# curl_multi_wakeup (the module has one thread).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
"$here/cmake-dep.sh" "$1" "$2" \
  -DCURL_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR="${WEBBY_WASI_SYSROOT:?}" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DUSE_NGHTTP2=ON -DUSE_NGTCP2=ON -DCURL_ZLIB=ON -DCURL_BROTLI=ON -DCURL_ZSTD=ON -DCURL_DISABLE_WEBSOCKETS=OFF \
  -DBUILD_CURL_EXE=ON -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DBUILD_EXAMPLES=OFF \
  -DENABLE_THREADED_RESOLVER=OFF -DENABLE_UNIX_SOCKETS=OFF -DENABLE_IPV6=ON \
  -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF \
  -DUSE_LIBIDN2=OFF -DCURL_USE_GSSAPI=OFF \
  -DCURL_DISABLE_SOCKETPAIR=ON -DHAVE_SOCKETPAIR=OFF -DHAVE_SYS_UN_H=OFF \
  -DCURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt -DCURL_CA_PATH=none
