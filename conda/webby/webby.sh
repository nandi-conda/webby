#!/bin/sh
# Launches webby against this environment's webby-ladybird, unless WEBBY_LADYBIRD_PREFIX is already set.
prefix="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-$prefix/lib/webby-ladybird}"
# A fontconfig file the sandboxed helpers can read, so they don't each print "Cannot load default config file".
fonts_conf="$WEBBY_LADYBIRD_PREFIX/share/Lagom/fonts/webby-fonts.conf"
if [ -z "${FONTCONFIG_FILE:-}" ] && [ -r "$fonts_conf" ]; then
  export FONTCONFIG_FILE="$fonts_conf"
fi
# GTK reads favicons through gdk-pixbuf's loaders (.ico, SVG, GIF; PNG and JPEG are built in). conda-forge's loaders.cache
# names them relative to the program's own prefix, which webby (in nim/ or lib/webby/) isn't in, and pixi doesn't
# write the cache at all (no post-link scripts), so webby gets its own copy with whole paths.
if [ -z "${GDK_PIXBUF_MODULE_FILE:-}" ] && [ -x "$prefix/bin/gdk-pixbuf-query-loaders" ]; then
  pixbuf_cache="${XDG_CACHE_HOME:-$HOME/.cache}/webby/gdk-pixbuf-loaders-$(printf %s "$prefix" | cksum | cut -d' ' -f1).cache"
  if [ ! -s "$pixbuf_cache" ] || [ "$prefix/lib/gdk-pixbuf-2.0/2.10.0/loaders" -nt "$pixbuf_cache" ]; then
    mkdir -p "$(dirname "$pixbuf_cache")"
    "$prefix/bin/gdk-pixbuf-query-loaders" 2>/dev/null | sed "s|^\"lib/|\"$prefix/lib/|" > "$pixbuf_cache.tmp" &&
      mv "$pixbuf_cache.tmp" "$pixbuf_cache" || rm -f "$pixbuf_cache.tmp"
  fi
  if [ -s "$pixbuf_cache" ]; then export GDK_PIXBUF_MODULE_FILE="$pixbuf_cache"; fi
fi
exec "$prefix/lib/webby/webby" "$@"
