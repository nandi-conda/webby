#!/usr/bin/env bash
# dav1d 1.5.4 (meson), libavif v1.4.2 and FFmpeg n9.0.2 for wasm32-wasip1 into WEBBY_WASI_SYSROOT. FFmpeg gets the
# decoders of Ladybird's vcpkg overlay port ("ladybird-components"), no threads, no asm, no avformat.
# usage: media-deps.sh SRC_DIR BUILD_DIR   (checkouts dav1d, libavif, ffmpeg in SRC_DIR); needs meson on PATH
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); S=$1; D=$2; P=${WEBBY_WASI_SYSROOT:?}; sdk=${WASI_SDK_PREFIX:?}; mkdir -p "$D"
emu="-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID"
cflags="--target=wasm32-wasip1 $emu -isystem $P/include -include $P/include/webby_wasi_compat.h"
libs="--target=wasm32-wasip1 -L$P/lib -lwebby_wasi_compat -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-mman -lwasi-emulated-getpid"
q() { printf "'%s', " $1; }
cat > "$D/wasi-cross.txt" <<CROSS
[binaries]
c = ['env', 'MESON_WASI_CC=clang', '$here/tools/meson-wasi-cc']
cpp = ['env', 'MESON_WASI_CC=clang++', '$here/tools/meson-wasi-cc']
ar = '$sdk/bin/llvm-ar'
strip = '$sdk/bin/llvm-strip'
pkg-config = 'pkg-config'
[built-in options]
# dav1d's clock_gettime check compiles with -std=c99, which hides it without a POSIX level.
c_args = [$(q "$cflags -D_POSIX_C_SOURCE=200809L")]
c_link_args = [$(q "$libs")]
[properties]
pkg_config_libdir = '$P/lib/pkgconfig'
[host_machine]
system = 'wasi'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
CROSS
meson setup "$D/dav1d" "$S/dav1d" --cross-file "$D/wasi-cross.txt" --prefix="$P" --libdir=lib --default-library=static \
  --buildtype=release -Denable_tools=false -Denable_tests=false -Denable_asm=false -Dlogging=false > "$D/dav1d.log"
ninja -C "$D/dav1d" install > /dev/null
# -pthread in dav1d.pc would make wasm-ld build a shared-memory module.
sed -i 's/ *-pthread//g' "$P/lib/pkgconfig/dav1d.pc"
"$here/deps/cmake-dep.sh" "$S/libavif" "$D/avif" -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_LIBYUV=OFF -DAVIF_BUILD_APPS=OFF \
  -DAVIF_BUILD_TESTS=OFF -DAVIF_LIBSHARPYUV=OFF -DAVIF_LIBXML2=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF
mkdir -p "$D/ffmpeg"; cd "$D/ffmpeg"
PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH= "$S/ffmpeg/configure" --prefix="$P" --enable-cross-compile \
  --target-os=none --arch=wasm32 --cc="$sdk/bin/clang" --cxx="$sdk/bin/clang++" --ar="$sdk/bin/llvm-ar" \
  --ranlib="$sdk/bin/llvm-ranlib" --nm="$sdk/bin/llvm-nm" --extra-cflags="$cflags" --extra-ldflags="$libs" \
  --pkg-config=pkg-config --enable-static --disable-shared --disable-programs --disable-doc --disable-autodetect \
  --disable-asm --disable-inline-asm --disable-pthreads --disable-w32threads --disable-os2threads --disable-network \
  --disable-everything --enable-libdav1d \
  --enable-decoder=vp8,vp9,libdav1d,theora,vorbis,opus,flac,mp3float,pcm_u8,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_alaw,pcm_mulaw \
  --enable-parser=vp8,vp9,av1,mpegaudio --disable-swscale --disable-avformat --disable-avfilter --disable-avdevice \
  --enable-swresample > configure.log
make -j"$(nproc)" > make.log 2>&1 && make install > /dev/null
echo "media libraries for WASI in $P"
