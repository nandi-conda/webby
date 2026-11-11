#!/usr/bin/env bash
# Header-only dependencies of LibGfx/LibWeb for WASI:
#  - wuffs v0.3.5's release/c/wuffs-v0.3.c (LibGfx's GIF decoder includes it)
#  - ANGLE's GLES/EGL/KHR headers (WebGL's constants and types; nothing calls GL in the module) with angle.pc.
#    khrplatform.h is changed so GLintptr/GLsizeiptr stay 64-bit on wasm32: they are fields of the WebGL command
#    stream, whose layout the generator fixes at 8 bytes (Meta/Generators/libweb_webgl.py).
# usage: header-deps.sh WORK   (clones into WORK; installs into WEBBY_WASI_SYSROOT)
set -euo pipefail
work=$1; P=${WEBBY_WASI_SYSROOT:?}; mkdir -p "$work"
[ -d "$work/wuffs" ] || git clone -q --depth 1 --branch v0.3.5 https://github.com/google/wuffs "$work/wuffs"
mkdir -p "$P/include/wuffs"; cp "$work/wuffs/release/c/wuffs-v0.3.c" "$P/include/wuffs/"
if [ ! -d "$work/angle" ]; then
  git clone -q --depth 1 --filter=blob:none --sparse https://chromium.googlesource.com/angle/angle "$work/angle"
  git -C "$work/angle" sparse-checkout set include
fi
rm -rf "$P/include/angle"; mkdir -p "$P/include/angle"
cp -r "$work/angle/include/"{EGL,GLES,GLES2,GLES3,KHR} "$P/include/angle/"
sed -i 's/^#ifdef _WIN64$/#if defined(_WIN64) || defined(__wasm32__)/' "$P/include/angle/KHR/khrplatform.h"
grep -q "__wasm32__" "$P/include/angle/KHR/khrplatform.h"
mkdir -p "$P/lib/pkgconfig"
cat > "$P/lib/pkgconfig/angle.pc" <<PC
prefix=$P
includedir=\${prefix}/include/angle
Name: angle
Description: ANGLE's GLES and EGL headers only (no GL in the WASI build)
Version: 7258
Cflags: -I\${includedir}
PC
echo "wuffs + ANGLE headers in $P"
