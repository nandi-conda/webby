#!/usr/bin/env bash
# Runs the app inside the pixi environment against the webby-ladybird package (or your own WEBBY_LADYBIRD_PREFIX).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/third_party/flutter/bin:$PATH"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-$CONDA_PREFIX/lib/webby-ladybird}"

# Flutter's Linux build uses the pixi env's clang, lld and GTK; the rpath lets the runner find that GTK at run time.
# libflutter_linux_gtk.so has no rpath of its own, so the runner also links its other two deps (epoxy, fontconfig)
# to have them loaded from the pixi env as well.
export CC=clang CXX=clang++
export LDFLAGS="-fuse-ld=lld -L$CONDA_PREFIX/lib -Wl,-rpath,$CONDA_PREFIX/lib \
  -Wl,--push-state,--no-as-needed -lepoxy -lfontconfig -Wl,--pop-state ${LDFLAGS:-}"

flutter config --no-analytics --enable-linux-desktop >/dev/null
exec "$ROOT/scripts/run_app.sh" "$@"
