#!/usr/bin/env bash
# Skia (Ladybird's pin, "skia 148") as a static library for wasm32-wasip1: CPU raster only (Ganesh's core is built,
# because the Compositor's code names GrDirectContext, but with no GL/Vulkan backend, so no GPU context is ever made;
# no Graphite, no PDF), FreeType with the empty/custom font manager (no fontconfig), Skia's own bundled FreeType, libpng and
# zlib. Image codecs: PNG only (Ladybird's Compositor only draws; LibGfx decodes images itself).
# Installs libskia.a, the headers, skia.pc and an unofficial-skia CMake config into PREFIX (see the end).
#
# usage: skia.sh SKIA_SRC BUILD PREFIX      env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT (for compat/)
#
# SKIA_SRC is a git checkout of https://skia.googlesource.com/skia at $SKIA_COMMIT. The script fetches gn and the
# three DEPS entries it needs (FreeType, libpng, zlib) by git if they are missing, and applies deps/skia-*.patch once.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SKIA_COMMIT=e7c90ecca9444fe09598f1630ab7cee2c0ee027a
src=$(realpath "$1"); mkdir -p "$2" "$3"; build=$(realpath "$2"); prefix=$(realpath "$3")
sdk=${WASI_SDK_PREFIX:?}; sysroot=${WEBBY_WASI_SYSROOT:?}

cd "$src"
[ "$(git rev-parse HEAD)" = "$SKIA_COMMIT" ] || { echo "skia.sh: $src is not at $SKIA_COMMIT" >&2; exit 1; }
[ -x bin/gn ] || python3 bin/fetch-gn
for dep in freetype libpng zlib; do
    [ -e "third_party/externals/$dep/.git" ] && continue
    url=$(sed -n "s|^ *\"third_party/externals/$dep\" *: *\"\(.*\)\",|\1|p" DEPS)
    git clone -q "${url%@*}" "third_party/externals/$dep"
    git -C "third_party/externals/$dep" checkout -q "${url#*@}"
done
for p in "$here"/skia-*.patch; do
    [ -e "$p" ] || continue
    if git apply --reverse --check "$p" 2>/dev/null; then continue; fi
    git apply "$p"
done

# Clang for WASI defines neither __unix__ nor __linux__, so SkFeatures.h would guess SK_BUILD_FOR_MAC: say UNIX
# (POSIX file and time ports, stdio logging). GN's target_os stays "linux" (its "wasm" OS means Emscripten) with an
# unknown target_cpu, so no x86/ARM SIMD flags are added. SK_FORCE_8_BYTE_ALIGNMENT is what Skia's own wasm build
# sets. The raster pipeline chains its stages with clang::musttail (-mtail-call, which the engine needs anyway) and
# SkVx uses wasm SIMD128 (-msimd128), both on by default in wasmtime.
# libpng (Skia's PNG codec and FreeType's colour PNG glyphs) and FreeType's cmap validation recover from errors with
# setjmp/longjmp, which wasi-sdk implements with wasm exception handling: -wasm-enable-sjlj with the standard
# (exnref) encoding, so programs that link libskia.a also link -lsetjmp and need an engine with exceptions on
# (wasmtime's Config.wasm_exceptions; tools/wasi-run.py turns it on).
q() { printf '"%s",' "$@"; }
cflags=$(q --target=wasm32-wasip1 -DSK_BUILD_FOR_UNIX -mtail-call -msimd128 -DSK_FORCE_8_BYTE_ALIGNMENT \
    -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID \
    -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false \
    -isystem "$sysroot/include" -include "$sysroot/include/webby_wasi_compat.h")
args="
target_os=\"linux\" target_cpu=\"wasm32\"
is_official_build=true is_component_build=false is_debug=false
cc=\"$sdk/bin/clang\" cxx=\"$sdk/bin/clang++\" ar=\"$sdk/bin/llvm-ar\"
extra_cflags=[${cflags%,}]
skia_enable_ganesh=true skia_enable_graphite=false skia_use_gl=false skia_use_vulkan=false skia_use_dawn=false
skia_use_webgl=false skia_use_webgpu=false skia_use_egl=false skia_use_x11=false
skia_enable_pdf=false skia_use_xps=false skia_enable_skottie=false skia_enable_svg=false skia_enable_tools=false
skia_use_lua=false skia_enable_android_utils=false skia_enable_spirv_validation=false
skia_use_fontconfig=false skia_use_freetype=true skia_use_system_freetype2=false
skia_enable_fontmgr_custom_empty=true skia_enable_fontmgr_custom_directory=false
skia_enable_fontmgr_custom_embedded=false skia_enable_fontmgr_android=false skia_use_expat=false
skia_use_harfbuzz=false skia_use_icu=false skia_use_client_icu=false skia_enable_skunicode=false
skia_use_libpng_decode=true skia_use_libpng_encode=true skia_use_system_libpng=false
skia_use_zlib=true skia_use_system_zlib=false
skia_use_libjpeg_turbo_decode=false skia_use_libjpeg_turbo_encode=false skia_use_no_jpeg_encode=true
skia_use_libwebp_decode=false skia_use_libwebp_encode=false skia_use_no_webp_encode=true
skia_use_wuffs=false skia_use_piex=false skia_use_dng_sdk=false skia_use_jpeg_gainmaps=false
skia_use_perfetto=false skia_disable_tracing=true
"
bin/gn gen "$build" --args="$(echo $args)" > "$build.gn.log" 2>&1 || { cat "$build.gn.log"; exit 1; }
ninja -C "$build" skia > "$build.build.log" 2>&1 || { grep -m10 -B2 -A8 "error" "$build.build.log"; exit 1; }

# Install like vcpkg's unofficial-skia port: the repository's headers under include/skia (so both <core/SkPath.h>, as
# Ladybird writes it, and "include/core/SkPath.h", as Skia's own headers do, resolve), libskia.a (complete: FreeType,
# libpng, zlib and skcms are in it), a pkg-config file and an unofficial-skia CMake config with the target
# unofficial::skia::skia that Ladybird's check_for_dependencies.cmake looks for.
rm -rf "$prefix/include/skia"; mkdir -p "$prefix/lib/pkgconfig" "$prefix/include/skia" "$prefix/share/unofficial-skia"
cp "$build/libskia.a" "$prefix/lib/"
for d in include modules src; do
    (cd "$src" && find "$d" -name '*.h' -exec install -D -m644 {} "$prefix/include/skia/{}" \;)
done
cp -r "$prefix/include/skia/include/." "$prefix/include/skia/"
# Public defines: Skia's own skia_public and every *_public config of the parts built, plus the WASI ones above.
defines=$(bin/gn desc "$build" //:skia defines --blame | awk '/^From /{pub = ($2 ~ /_public$/)} /^  [A-Z]/{if (pub) print $1}' | sort -u)
defines="$defines SK_BUILD_FOR_UNIX SK_FORCE_8_BYTE_ALIGNMENT"
dflags=$(for d in $defines; do printf -- '-D%s ' "$d"; done)
cat > "$prefix/lib/pkgconfig/skia.pc" <<PC
prefix=$prefix
Name: skia
Description: Skia ($SKIA_COMMIT) CPU raster for wasm32-wasip1
Version: 148
Cflags: -I\${prefix}/include/skia $dflags
Libs: -L\${prefix}/lib -lskia -lsetjmp
PC
cat > "$prefix/share/unofficial-skia/unofficial-skia-config.cmake" <<CM
# Generated by webby wasm/deps/skia.sh: Skia $SKIA_COMMIT, CPU raster, for wasm32-wasip1.
if(NOT TARGET unofficial::skia::skia)
    get_filename_component(_skia_prefix "\${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
    add_library(unofficial::skia::skia STATIC IMPORTED)
    set_target_properties(unofficial::skia::skia PROPERTIES
        IMPORTED_LOCATION "\${_skia_prefix}/lib/libskia.a"
        INTERFACE_INCLUDE_DIRECTORIES "\${_skia_prefix}/include/skia"
        INTERFACE_COMPILE_DEFINITIONS "$(echo $defines | tr ' ' ';')"
        INTERFACE_LINK_LIBRARIES "setjmp")
    unset(_skia_prefix)
endif()
set(unofficial-skia_FOUND TRUE)
CM
echo "skia for WASI in $prefix ($(du -h "$prefix/lib/libskia.a" | cut -f1))"
