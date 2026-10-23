#!/usr/bin/env bash
# Builds the Nim front end (nim/) with the pixi env's Nim, clang and GTK when its sources changed, then runs it
# against the webby-ladybird package (or your own WEBBY_LADYBIRD_PREFIX). Arguments go to the browser (URLs, --incognito).
# WEBBY_BUILD_ONLY=1 stops after the build (the Dagger `nim-desktop` check, .dagger/).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/nim/webby"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-$CONDA_PREFIX/lib/webby-ladybird}"

# The page scripts (nim/src/scripts) and the window icon (icons/*.svg) are read at compile time, so they count as
# sources too.
# The commit it's built from goes into ⋮ > About (nim/src/features/about.nim), "-dirty" with uncommitted changes to
# those sources; a new commit rebuilds it even when the sources didn't change.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$COMMIT" != unknown ] && ! git -C "$ROOT" diff --quiet HEAD -- nim framework icons 2>/dev/null; then COMMIT="$COMMIT-dirty"; fi
STAMP="$ROOT/.pixi/webby-commit"
if [ ! -x "$BIN" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$COMMIT" ] || [ -n "$(find "$ROOT/nim" "$ROOT/framework/src" "$ROOT/icons" \( -name '*.nim' -o -name '*.js' -o -name '*.svg' \) -newer "$BIN" -print -quit)" ]; then
  echo "Building nim/webby..." >&2
  # GTK's flags come from pkg-config at compile time; fail here rather than with its error text as compiler flags.
  pkg-config --cflags --libs gtk+-3.0 > /dev/null
  # No -d:ssl: Nim's OpenSSL setup would load a libcrypto before libwebby's own. The rpath makes the binary use the
  # env's GTK at run time. libstdc++ is linked in so the env's (new enough for Ladybird's C++23) loads first:
  # otherwise a system library GTK pulls in can load the system's older one, and libwebby.so then fails to load.
  nim c -d:release --hints:off --warnings:off --cc:clang --nimcache:"$ROOT/.pixi/nimcache" -d:webbyCommit="$COMMIT" \
    --passL:"-fuse-ld=lld -L$CONDA_PREFIX/lib -Wl,-rpath,$CONDA_PREFIX/lib -Wl,--no-as-needed -lstdc++ -Wl,--as-needed" -o:"$BIN" "$ROOT/nim/webby.nim"
  echo "$COMMIT" > "$STAMP"
fi
if [ -n "${WEBBY_BUILD_ONLY:-}" ]; then exit 0; fi
# GTK reads favicons through gdk-pixbuf's loaders (.ico, SVG, GIF; PNG and JPEG are built in). conda-forge's loaders.cache
# names them relative to the program's own prefix, which webby (in nim/ or lib/webby/) isn't in, and pixi doesn't
# write the cache at all (no post-link scripts), so webby gets its own copy with whole paths.
if [ -z "${GDK_PIXBUF_MODULE_FILE:-}" ] && [ -x "$CONDA_PREFIX/bin/gdk-pixbuf-query-loaders" ]; then
  pixbuf_cache="${XDG_CACHE_HOME:-$HOME/.cache}/webby/gdk-pixbuf-loaders-$(printf %s "$CONDA_PREFIX" | cksum | cut -d' ' -f1).cache"
  if [ ! -s "$pixbuf_cache" ] || [ "$CONDA_PREFIX/lib/gdk-pixbuf-2.0/2.10.0/loaders" -nt "$pixbuf_cache" ]; then
    mkdir -p "$(dirname "$pixbuf_cache")"
    "$CONDA_PREFIX/bin/gdk-pixbuf-query-loaders" 2>/dev/null | sed "s|^\"lib/|\"$CONDA_PREFIX/lib/|" > "$pixbuf_cache.tmp" &&
      mv "$pixbuf_cache.tmp" "$pixbuf_cache" || rm -f "$pixbuf_cache.tmp"
  fi
  if [ -s "$pixbuf_cache" ]; then export GDK_PIXBUF_MODULE_FILE="$pixbuf_cache"; fi
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
