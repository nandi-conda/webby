#!/usr/bin/env bash
# Builds webby-pdf (the MuPDF renderer behind webby's PDF viewer, src/features/pdf.nim) into $1 against the conda
# env's MuPDF. Used by scripts/pixi_nim.sh and conda/webby/build.sh.
set -euo pipefail
OUT="$1"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/webby-pdf.c"
PREFIX="${PREFIX:-$CONDA_PREFIX}"
clang -O2 -Wall -o "$OUT" "$SRC" -I"$PREFIX/include" -L"$PREFIX/lib" -lmupdf -lm \
  -fuse-ld=lld -Wl,-rpath,"$PREFIX/lib"
