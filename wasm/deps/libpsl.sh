#!/usr/bin/env bash
# libpsl 0.21.5 (LibURL's public suffix list) for wasm32-wasip1: the built-in list, IDNA through ICU, no build system.
# usage: libpsl.sh SRC(with the list/ submodule) BUILD PREFIX     env: WASI_SDK_PREFIX
set -euo pipefail
src=$(realpath "$1"); mkdir -p "$2" "$3"; build=$(realpath "$2"); prefix=$(realpath "$3")
sdk=${WASI_SDK_PREFIX:?}
cd "$build"
python3 "$src/src/psl-make-dafsa" --output-format=cxx+ "$src/list/public_suffix_list.dat" suffixes_dafsa.h
ver=$(cat "$src/version.txt" 2>/dev/null || echo 0.21.5); IFS=. read -r ma mi pa <<< "$ver"
sed -e "s/@LIBPSL_VERSION@/$ver/; s/@LIBPSL_VERSION_MAJOR@/$ma/; s/@LIBPSL_VERSION_MINOR@/$mi/; s/@LIBPSL_VERSION_PATCH@/$pa/" \
    -e "s/@LIBPSL_VERSION_NUMBER@/$(printf '0x%02x%02x%02x' "$ma" "$mi" "$pa")/" "$src/include/libpsl.h.in" > libpsl.h
cat > config.h <<'H'
#define ENABLE_BUILTIN 1
#define WITH_LIBICU 1
#define HAVE_STRINGS_H 1
#define PACKAGE_VERSION "0.21.5"
H
"$sdk/bin/clang" --target=wasm32-wasip1 -O2 -DHAVE_CONFIG_H -DPSL_STATIC -I. -I"$prefix/include" -c "$src/src/psl.c" -o psl.o
"$sdk/bin/llvm-ar" rcs libpsl.a psl.o
mkdir -p "$prefix/lib/pkgconfig" "$prefix/include"
cp libpsl.a "$prefix/lib/"; cp libpsl.h "$prefix/include/"
cat > "$prefix/lib/pkgconfig/libpsl.pc" <<PC
prefix=$prefix
Name: libpsl
Description: Public Suffix List library (WASI)
Version: $ver
Cflags: -I\${prefix}/include -DPSL_STATIC
Libs: -L\${prefix}/lib -lpsl
PC
echo "libpsl for WASI in $prefix"
