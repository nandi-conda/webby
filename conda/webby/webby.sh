#!/bin/sh
# Launches webby against this environment's webby-ladybird, unless WEBBY_LADYBIRD_PREFIX is already set.
prefix="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-$prefix/lib/webby-ladybird}"
exec "$prefix/lib/webby/webby" "$@"
