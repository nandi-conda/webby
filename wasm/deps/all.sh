#!/usr/bin/env bash
# Every WASI dependency of the engine, from sources.txt, into WEBBY_WASI_SYSROOT, in order. The forge's wasm-deps job
# (ci/deps.Dockerfile) runs it one stage per layer; by hand, run it with no stage for all of them.
# usage: all.sh SRC_DIR WORK_DIR [stage...]
#   stages: fetch compat icu openssl libpsl cmake-deps header-deps libweb-deps net-deps curl media-deps skia mupdf binaryen
# env: WASI_SDK_PREFIX, WEBBY_WASI_SYSROOT. SRC_DIR and WORK_DIR may be kept between runs (checkouts are reused,
# builds are incremental); the sysroot is only ever added to.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1" "$2"; S=$(realpath "$1"); W=$(realpath "$2"); shift 2
P=${WEBBY_WASI_SYSROOT:?}; : "${WASI_SDK_PREFIX:?}"; mkdir -p "$P"
stages=("$@"); [ ${#stages[@]} -gt 0 ] || stages=(fetch compat icu openssl libpsl cmake-deps header-deps libweb-deps net-deps curl \
  media-deps skia mupdf binaryen)

ref_of() { awk -v n="$1" '$1 == n { print $3 }' "$here/sources.txt"; }

# A checkout of NAME at its ref in SRC_DIR/NAME. A tag is cloned shallow; a commit is fetched by itself.
fetch() {
  local name=$1 url ref dir=$S/$1
  url=$(awk -v n="$name" '$1 == n { print $2 }' "$here/sources.txt"); ref=$(ref_of "$name")
  if [ -d "$dir/.git" ] && [ "$(cat "$dir/.git/webby-ref" 2>/dev/null)" = "$ref" ]; then return; fi
  rm -rf "$dir"
  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    git init -q "$dir"; git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch -q --depth 1 origin "$ref"; git -C "$dir" checkout -q FETCH_HEAD
  else
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" "$url" "$dir"
  fi
  case $name in
    libpsl) git -C "$dir" submodule -q update --init --depth 1 list ;;
    nghttp2 | ngtcp2) git -C "$dir" submodule -q update --init --depth 1 third-party/urlparse ;;
    nghttp3) git -C "$dir" submodule -q update --init --depth 1 lib/sfparse ;;
    mupdf) git -C "$dir" submodule -q update --init --depth 1 thirdparty/freetype thirdparty/harfbuzz thirdparty/jbig2dec \
      thirdparty/libjpeg thirdparty/openjpeg thirdparty/zlib thirdparty/lcms2 thirdparty/brotli thirdparty/gumbo-parser thirdparty/extract ;;
  esac
  echo "$ref" > "$dir/.git/webby-ref"
  echo "fetched $name $ref"
}

# Projects patched in place: put the checkout back first, so a run after a patch change starts clean.
clean_checkout() { git -C "$S/$1" checkout -q -- . && git -C "$S/$1" clean -qfdx; }

run_stage() {
  local t0=$SECONDS
  echo "== $1"
  case $1 in
    fetch)
      for n in $(awk '!/^#/ && NF { print $1 }' "$here/sources.txt"); do fetch "$n"; done ;;
    compat) "$here/../compat/build.sh" ;;
    icu) "$here/icu.sh" "$S/icu/icu4c/source" "$W/icu" "$P" ;;
    openssl) "$here/openssl.sh" "$S/openssl" "$W/openssl" "$P" ;;
    libpsl) "$here/libpsl.sh" "$S/libpsl" "$W/psl" "$P" ;;
    cmake-deps)
      "$here/cmake-dep.sh" "$S/fast_float" "$W/fast_float" -DFASTFLOAT_TEST=OFF -DFASTFLOAT_BENCHMARKS=OFF
      clean_checkout zmij; git -C "$S/zmij" apply "$here/zmij-array-bounds.patch"
      "$here/cmake-dep.sh" "$S/zmij" "$W/zmij" -DZMIJ_TEST=OFF -DZMIJ_EXAMPLE=OFF
      "$here/cmake-dep.sh" "$S/simdutf" "$W/simdutf" -DSIMDUTF_TESTS=OFF -DSIMDUTF_TOOLS=OFF -DSIMDUTF_BENCHMARKS=OFF
      "$here/cmake-dep.sh" "$S/libtommath" "$W/libtommath"
      "$here/cmake-dep.sh" "$S/mimalloc" "$W/mimalloc" -DMI_BUILD_SHARED=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF \
        -DMI_OVERRIDE=OFF
      "$here/cmake-dep.sh" "$S/fmt" "$W/fmt" -DFMT_TEST=OFF -DFMT_DOC=OFF
      "$here/cmake-dep.sh" "$S/simdjson" "$W/simdjson" -DSIMDJSON_DEVELOPER_MODE=OFF -DSIMDJSON_ENABLE_THREADS=OFF ;;
    header-deps) "$here/header-deps.sh" "$W/header-deps" ;;
    libweb-deps) clean_checkout libpng; "$here/libweb-deps.sh" "$S" "$W/libweb" ;;
    net-deps) "$here/net-deps.sh" "$S" "$W/net" ;;
    curl) "$here/curl.sh" "$S/curl" "$W/curl" ;;
    # meson setup refuses a configured build directory, so the media libraries start over each time (a few minutes).
    media-deps) rm -rf "$W/media"; "$here/media-deps.sh" "$S" "$W/media" ;;
    skia) "$here/skia.sh" "$S/skia" "$W/skia" "$P" ;;
    # The PDF viewer's MuPDF, for the webby-pdf component only (its own directory in the sysroot: deps/mupdf.sh).
    mupdf) "$here/mupdf.sh" "$S/mupdf" "$W/mupdf" "$P" ;;
    binaryen) "$here/binaryen.sh" "$W/binaryen" "$P" ;;
    *) echo "all.sh: unknown stage $1" >&2; exit 2 ;;
  esac
  echo "== $1 done in $((SECONDS - t0)) s"
}

for stage in "${stages[@]}"; do run_stage "$stage"; done
