#!/usr/bin/env bash
# Builds the Nim front end (nim/) with the pixi env's Nim, clang and GTK when its sources changed, then runs it
# against the webby-ladybird package (or your own WEBBY_LADYBIRD_PREFIX). Arguments go to the browser (URLs, --incognito).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/nim/webby"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-$CONDA_PREFIX/lib/webby-ladybird}"

# The page shims are read from the Flutter app's Dart files and the window icon from icons/*.svg at compile time, so
# those count as sources too.
if [ ! -x "$BIN" ] || [ -n "$(find "$ROOT/nim" "$ROOT/framework/src" "$ROOT/app/lib" "$ROOT/icons" \( -name '*.nim' -o -name '*.dart' -o -name '*.svg' \) -newer "$BIN" -print -quit)" ]; then
  echo "Building nim/webby..." >&2
  # No -d:ssl: Nim's OpenSSL setup would load a libcrypto before libwebby's own. The rpath makes the binary use the
  # env's GTK at run time.
  nim c -d:release --hints:off --warnings:off --cc:clang --nimcache:"$ROOT/.pixi/nimcache" \
    --passL:"-fuse-ld=lld -L$CONDA_PREFIX/lib -Wl,-rpath,$CONDA_PREFIX/lib" -o:"$BIN" "$ROOT/nim/webby.nim"
fi
# A fontconfig file Ladybird's sandboxed helpers can read, as conda/webby's launcher sets up: they may only read
# share/Lagom/fonts, so without it each one prints "Cannot load default config file".
fonts_conf="$WEBBY_LADYBIRD_PREFIX/share/Lagom/fonts/webby-fonts.conf"
if [ ! -r "$fonts_conf" ] && [ -w "$WEBBY_LADYBIRD_PREFIX/share/Lagom/fonts" ]; then
  sed "s|@PREFIX@|$CONDA_PREFIX|" "$ROOT/conda/webby/webby-fonts.conf" > "$fonts_conf"
fi
if [ -z "${FONTCONFIG_FILE:-}" ] && [ -r "$fonts_conf" ]; then
  export FONTCONFIG_FILE="$fonts_conf"
fi
exec "$BIN" "$@"
