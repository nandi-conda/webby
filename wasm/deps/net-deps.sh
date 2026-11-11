#!/usr/bin/env bash
# curl's protocol libraries for wasm32-wasip1 (before deps/curl.sh): zstd, nghttp2 (HTTP/2), nghttp3 and ngtcp2
# (HTTP/3; ngtcp2's crypto backend is OpenSSL's QUIC TLS API, ngtcp2_crypto_ossl, so OpenSSL comes first).
# usage: net-deps.sh SRC_DIR BUILD_DIR      SRC_DIR holds checkouts named zstd, nghttp2, nghttp3, ngtcp2 (sources.txt)
# env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
S=$(realpath "$1"); mkdir -p "$2"; B=$(realpath "$2")
"$here/cmake-dep.sh" "$S/zstd/build/cmake" "$B/zstd" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF \
  -DZSTD_BUILD_TESTS=OFF -DZSTD_MULTITHREAD_SUPPORT=OFF -DZSTD_LEGACY_SUPPORT=OFF
"$here/cmake-dep.sh" "$S/nghttp2" "$B/nghttp2" -DENABLE_LIB_ONLY=ON -DBUILD_STATIC_LIBS=ON -DENABLE_DOC=OFF
"$here/cmake-dep.sh" "$S/nghttp3" "$B/nghttp3" -DENABLE_LIB_ONLY=ON -DENABLE_STATIC_LIB=ON -DENABLE_SHARED_LIB=OFF
"$here/cmake-dep.sh" "$S/ngtcp2" "$B/ngtcp2" -DENABLE_LIB_ONLY=ON -DENABLE_STATIC_LIB=ON -DENABLE_SHARED_LIB=OFF \
  -DENABLE_OPENSSL=ON -DOPENSSL_ROOT_DIR="${WEBBY_WASI_SYSROOT:?}" -DENABLE_GNUTLS=OFF -DENABLE_BORINGSSL=OFF \
  -DENABLE_WOLFSSL=OFF -DENABLE_PICOTLS=OFF
