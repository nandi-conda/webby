#!/usr/bin/env bash
# The C libraries LibGfx and LibWeb need, for wasm32-wasip1, into WEBBY_WASI_SYSROOT. Sources are git checkouts at the
# versions Ladybird's vcpkg.json pins (GitHub release archives are not needed):
#   zlib v1.3.2, libpng v1.6.59, libjpeg-turbo 3.2.0, libwebp v1.6.0, brotli v1.2.0, woff2 v1.0.2,
#   freetype VER-2-13-3, harfbuzz 10.2.0, libxml2 v2.15.4, sqlite version-3.53.4
# usage: libweb-deps.sh SRC_DIR BUILD_DIR   (SRC_DIR holds the checkouts under those names)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); S=$1; D=$2; P=${WEBBY_WASI_SYSROOT:?}; mkdir -p "$D"
dep() { "$here/cmake-dep.sh" "$@"; }
dep "$S/zlib" "$D/zlib" -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_SHARED=OFF
# LibImageDecoders needs APNG: the libpng-apng patch vcpkg applies (sourceforge.net/projects/libpng-apng).
git -C "$S/libpng" apply --check "$here/libpng-1.6.59-apng.patch" 2>/dev/null && git -C "$S/libpng" apply "$here/libpng-1.6.59-apng.patch"
dep "$S/libpng" "$D/libpng" -DPNG_SHARED=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_HARDWARE_OPTIMIZATIONS=OFF
dep "$S/libjpeg-turbo" "$D/jpeg" -DENABLE_SHARED=OFF -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DCMAKE_SYSTEM_PROCESSOR=wasm32
dep "$S/brotli" "$D/brotli" -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
dep "$S/libwebp" "$D/webp" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_ENABLE_SIMD=OFF -DWEBP_USE_THREAD=OFF
# woff2's command-line tools throw C++ exceptions, so only its libraries are built, and installed by hand.
CMAKE_DEP_TARGETS="woff2common woff2dec woff2enc" dep "$S/woff2" "$D/woff2" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="$P" -DCANONICAL_PREFIXES=ON -DNOISY_LOGGING=OFF 2>/dev/null || true
cp "$D"/woff2/libwoff2*.a "$P/lib/"; mkdir -p "$P/include/woff2"; cp "$S"/woff2/include/woff2/*.h "$P/include/woff2/"
for f in "$D"/woff2/*.pc; do sed "s|^prefix=.*|prefix=$P|" "$f" > "$P/lib/pkgconfig/$(basename "$f")"; done
dep "$S/freetype" "$D/freetype" -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON -DFT_REQUIRE_ZLIB=ON \
  -DFT_REQUIRE_PNG=ON -DFT_REQUIRE_BROTLI=ON
# HarfBuzz would map font files; WASI has no mmap of files worth using.
CXXFLAGS="-fno-exceptions -DHB_NO_MMAP" dep "$S/harfbuzz" "$D/harfbuzz" -DHB_HAVE_FREETYPE=ON -DHB_HAVE_ICU=ON \
  -DHB_BUILD_SUBSET=OFF -DHB_BUILD_UTILS=OFF -DHB_HAVE_GLIB=OFF -DHB_HAVE_GOBJECT=OFF
dep "$S/libxml2" "$D/libxml2" -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=OFF \
  -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_THREADS=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_HTTP=OFF -DLIBXML2_WITH_MODULES=OFF
"$here/sqlite.sh" "$S/sqlite" "$D/sqlite" "$P"
