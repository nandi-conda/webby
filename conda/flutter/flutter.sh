#!/usr/bin/env bash
# `flutter` / `dart` launcher from the conda flutter package: downloads the official Flutter @VERSION@ Linux release on
# first use into ~/.cache/conda-flutter/@VERSION@ (or $CONDA_FLUTTER_ROOT), then runs the SDK's own command.
set -euo pipefail

version=@VERSION@
sha256=@SHA256@
root="${CONDA_FLUTTER_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/conda-flutter/$version}"
cmd="$root/flutter/bin/$(basename "$0")"

if [ ! -x "$cmd" ]; then
  mkdir -p "$root"
  # One download at a time; whoever waits finds the SDK in place.
  exec 9>"$root/.lock"
  flock 9
  if [ ! -x "$cmd" ]; then
    url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$version-stable.tar.xz"
    echo "Downloading Flutter $version (1.4 GB, once) into $root..." >&2
    tmp="$(mktemp -d "$root/.download.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    curl -fL --retry 3 -o "$tmp/flutter.tar.xz" "$url"
    echo "$sha256  $tmp/flutter.tar.xz" | sha256sum -c --quiet -
    echo "Unpacking Flutter $version..." >&2
    tar -xJf "$tmp/flutter.tar.xz" -C "$tmp" --no-same-owner
    rm -rf "$root/flutter"
    mv "$tmp/flutter" "$root/flutter"
    rm -rf "$tmp"
    trap - EXIT
  fi
  exec 9>&-
fi

exec "$cmd" "$@"
