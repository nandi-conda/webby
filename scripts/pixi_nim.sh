#!/usr/bin/env bash
# Builds the Nim front end (nim/) with the pixi env's Nim, clang and GTK when its sources changed, then runs it
# against the webby-ladybird package (or your own WEBBY_LADYBIRD_PREFIX). Arguments go to the browser (URLs, --incognito).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/nim/webby"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-$CONDA_PREFIX/lib/webby-ladybird}"

# The page shims are read from the Flutter app's Dart files at compile time, so those count as sources too.
if [ ! -x "$BIN" ] || [ -n "$(find "$ROOT/nim" "$ROOT/app/lib" \( -name '*.nim' -o -name '*.dart' \) -newer "$BIN" -print -quit)" ]; then
  echo "Building nim/webby..." >&2
  # No -d:ssl: Nim's OpenSSL setup would load a libcrypto before libwebby's own. The rpath makes the binary use the
  # env's GTK at run time.
  nim c -d:release --hints:off --warnings:off --cc:clang --nimcache:"$ROOT/.pixi/nimcache" \
    --passL:"-fuse-ld=lld -L$CONDA_PREFIX/lib -Wl,-rpath,$CONDA_PREFIX/lib" -o:"$BIN" "$ROOT/nim/webby.nim"
fi
exec "$BIN" "$@"
