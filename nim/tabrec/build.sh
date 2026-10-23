#!/usr/bin/env bash
# Builds webby-tabrec (the tab recorder behind bug reports) into $1 against the conda env's GStreamer. Used by
# scripts/pixi_nim.sh and conda/webby/build.sh.
set -euo pipefail
OUT="$1"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/webby-tabrec.c"
PREFIX="${PREFIX:-$CONDA_PREFIX}"
clang -O2 -Wall -o "$OUT" "$SRC" \
  $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0) \
  -fuse-ld=lld -Wl,-rpath,"$PREFIX/lib"
