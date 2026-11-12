#!/usr/bin/env bash
# MuPDF for wasm32-wasip1: the renderer behind wasm webby's PDF viewer (../pdf/webby_pdf.c, the webby-pdf
# component), as the Nim front end's webby-pdf (nim/pdf/) is behind its viewer.
#   deps/mupdf.sh MUPDF_SRC BUILD PREFIX
# Installs PREFIX/mupdf/{include,lib} (libmupdf.a, libmupdf-third.a): a directory of its own, because
# libmupdf-third.a holds MuPDF's own FreeType, HarfBuzz, zlib and libjpeg, which must never meet Ladybird's (they
# don't: only the webby-pdf component links them, and a component has its own symbols and memory).
#
# MuPDF's Makefile with wasi-sdk's clang: its thirdparty/ libraries, no X11/GLUT/threads/OpenSSL, no HTML-family
# documents (EPUB, FB2, MOBI, Office: html=no), no JavaScript in PDF forms, OCR, barcodes or docx output. Base-14
# fonts and DroidSansFallback are built in (TOFU_CJK_EXT, TOFU_NOTO, TOFU_SIL drop ~40 MB of fallback fonts that
# PDFs almost never need: they embed their fonts). fz_try is setjmp/longjmp, which wasi-sdk gives with wasm
# exceptions (-wasm-enable-sjlj, exnref), as cmake/wasi.cmake does for the engine; link with -lsetjmp.
# MuPDF is AGPL-3.0; so is any program linking it (the webby-pdf component), not the rest of webby.
set -euo pipefail
src=$(realpath "$1"); mkdir -p "$2" "$3"; build=$(realpath "$2"); prefix=$(realpath "$3")
: "${WASI_SDK_PREFIX:?}"
sdk=$WASI_SDK_PREFIX
# extract: not built (extract=no), but the Makefile still lists its docx/odt templates as sources of generated files.
for sub in freetype harfbuzz jbig2dec libjpeg openjpeg zlib lcms2 brotli gumbo-parser extract; do
  [ -n "$(ls -A "$src/thirdparty/$sub" 2>/dev/null)" ] || git -C "$src" submodule -q update --init --depth 1 "thirdparty/$sub"
done
flags="--target=wasm32-wasip1 --sysroot=$sdk/share/wasi-sysroot -O2 -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false"
flags+=" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID"
flags+=" -DTOFU_CJK_EXT -DTOFU_NOTO -DTOFU_SIL -DFZ_ENABLE_HYPHEN=0 -DFZ_ENABLE_OCR_OUTPUT=0 -DFZ_ENABLE_DOCX_OUTPUT=0"
flags+=" -DFZ_ENABLE_ODT_OUTPUT=0 -DFZ_ENABLE_BARCODE=0 -DFZ_ENABLE_HTML_ENGINE=0 -Wno-implicit-function-declaration"
# The font, CMap and ICC tables are generated on the build machine (host cc), then compiled for wasm like the rest.
make -C "$src" -s generate OUT="$build/host" XCFLAGS="-DTOFU_CJK_EXT -DTOFU_NOTO -DTOFU_SIL"
make -C "$src" -s -j"$(nproc)" libs OS=wasi build=release OUT="$build/out" \
  CC="$sdk/bin/clang" CXX="$sdk/bin/clang++" AR="$sdk/bin/llvm-ar" RANLIB="$sdk/bin/llvm-ranlib" \
  HAVE_X11=no HAVE_GLUT=no HAVE_OBJCOPY=no HAVE_LIBCRYPTO=no HAVE_PTHREAD=no HAVE_CURL=no \
  html=no mujs=no extract=no tesseract=no barcode=no brotli=yes \
  XCFLAGS="$flags" XLIBS=
rm -rf "$prefix/mupdf"; mkdir -p "$prefix/mupdf/lib"
cp -r "$src/include" "$prefix/mupdf/include"
cp "$build/out/libmupdf.a" "$build/out/libmupdf-third.a" "$prefix/mupdf/lib/"
echo "mupdf: $(du -ch "$prefix"/mupdf/lib/*.a | tail -1 | cut -f1) of libraries in $prefix/mupdf"
