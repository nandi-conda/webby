#!/usr/bin/env bash
# ICU 78.3 (the version Ladybird pins) for wasm32-wasip1: a native build for the data tools, then the cross build.
# usage: icu.sh SRC_DIR(icu4c/source) WORK_DIR PREFIX      env: WASI_SDK_PREFIX
set -euo pipefail
src=$(realpath "$1"); work=$2; prefix=$3
sdk=${WASI_SDK_PREFIX:?}
mkdir -p "$work/host" "$work/wasi" "$prefix"
work=$(realpath "$work"); prefix=$(realpath "$prefix")
jobs=$(nproc)
if [ ! -f "$work/host/bin/icupkg" ]; then
  (cd "$work/host" && CC=cc CXX=c++ "$src/configure" --disable-tests --disable-samples --disable-extras \
     --disable-icuio --disable-layoutex > configure.log && make -j"$jobs" > make.log)
fi
cd "$work/wasi"
CC_WASI="$sdk/bin/clang --target=wasm32-wasip1 --sysroot=$sdk/share/wasi-sysroot"
# configure has no platform file for wasm32-unknown-wasi and falls back to mh-unknown: make that Linux's (static
# libraries only, so its shared-library rules never run).
[ -f "$src/config/mh-unknown.orig" ] || { cp "$src/config/mh-unknown" "$src/config/mh-unknown.orig"; cp "$src/config/mh-linux" "$src/config/mh-unknown"; }
flags="-O2 -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN -DU_HAVE_MMAP=0 -DU_HAVE_POPEN=0 -DU_HAVE_TZSET=0 -DU_HAVE_TIMEZONE=0 -DU_HAVE_TZNAME=0"
if [ ! -f Makefile ]; then
  CC="$sdk/bin/clang --target=wasm32-wasip1 --sysroot=$sdk/share/wasi-sysroot" \
  CXX="$sdk/bin/clang++ --target=wasm32-wasip1 --sysroot=$sdk/share/wasi-sysroot" \
  AR="$sdk/bin/llvm-ar" RANLIB="$sdk/bin/llvm-ranlib" \
  CFLAGS="$flags" CXXFLAGS="$flags -std=c++17" LDFLAGS="-lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-mman" \
  "$src/configure" --host=wasm32-unknown-wasi --with-cross-build="$work/host" --prefix="$prefix" \
     --enable-static --disable-shared --disable-tests --disable-samples --disable-extras --disable-tools \
     --disable-icuio --disable-layoutex --with-data-packaging=static > configure.log
fi
# pkgdata cannot write a wasm object for the data, so the data library fails; the .dat it packs is made by then.
make -j"$jobs" > make.log 2>&1 || grep -q "packagedata" make.log || { tail -40 make.log; exit 1; }
dat=$(ls data/out/tmp/icudt*l.dat)
# The entry point libicuuc looks for has no endianness letter: icudt<major>_dat.
entry=$(basename "$dat" .dat); entry=${entry%l}
LD_LIBRARY_PATH="$work/host/lib" "$work/host/bin/genccode" -e "$entry" -d data/out/tmp "$dat" > /dev/null
datc=data/out/tmp/$(basename "$dat" .dat)_dat.c
$CC_WASI -O2 -I"$src/common" -c "$datc" -o data/out/tmp/icudata.o
rm -f lib/libicudata.a && "$sdk/bin/llvm-ar" rcs lib/libicudata.a data/out/tmp/icudata.o
# Install everything but the data (whose rules fail), then the library made above.
for d in common i18n; do make -C $d install > install.log 2>&1; done
make install-headers-recursive > /dev/null 2>&1 || true
cp lib/libicudata.a "$prefix/lib/"
mkdir -p "$prefix/lib/pkgconfig"; cp config/icu-uc.pc config/icu-i18n.pc "$prefix/lib/pkgconfig/" 2>/dev/null || true
echo "ICU for WASI in $prefix"
