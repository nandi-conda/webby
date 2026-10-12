#!/bin/sh
# Launches webby against this environment's webby-ladybird, unless WEBBY_LADYBIRD_PREFIX is already set.
prefix="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-$prefix/lib/webby-ladybird}"
# A fontconfig file the sandboxed helpers can read, so they don't each print "Cannot load default config file".
fonts_conf="$WEBBY_LADYBIRD_PREFIX/share/Lagom/fonts/webby-fonts.conf"
if [ -z "${FONTCONFIG_FILE:-}" ] && [ -r "$fonts_conf" ]; then
  export FONTCONFIG_FILE="$fonts_conf"
fi
exec "$prefix/lib/webby/webby" "$@"
