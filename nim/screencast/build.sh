#!/usr/bin/env bash
# Builds webby-screencast (the screen recorder behind pages' getDisplayMedia) into $1 against the conda env's
# GStreamer, PipeWire, GIO and Xlib. Used by scripts/pixi_nim.sh and conda/webby/build.sh.
set -euo pipefail
OUT="$1"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/webby-screencast.c"
PREFIX="${PREFIX:-$CONDA_PREFIX}"
clang -O2 -Wall -o "$OUT" "$SRC" \
  $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0 gio-unix-2.0 libpipewire-0.3 x11) -ldl \
  -fuse-ld=lld -Wl,-rpath,"$PREFIX/lib"
