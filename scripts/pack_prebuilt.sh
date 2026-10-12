#!/usr/bin/env bash
# Packs a Ladybird build (scripts/build_ladybird.sh) into webby-prebuilt-linux-x64.tar.zst, the runtime tarball
# conda/webby-ladybird repackages: lib/ (shared libraries), libexec/ (helper processes) and share/Lagom, stripped.
#
# Usage: scripts/pack_prebuilt.sh [BUILD_DIR] [OUT_DIR]   (defaults: third_party/ladybird/Build/release, .)
# Prints the highest glibc symbol version the result needs; conda/webby-ladybird's __glibc run dep must match it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(cd "${1:-$ROOT/third_party/ladybird/Build/release}" && pwd)"
OUT="$(mkdir -p "${2:-.}" && cd "${2:-.}" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/lib" "$STAGE/libexec" "$STAGE/share"
# Ladybird's own libraries, then the vcpkg-built ones they link against (ICU, Skia, ffmpeg, curl…).
for dir in "$BUILD/lib" "$BUILD/vcpkg_installed/x64-linux-dynamic/lib"; do
    find "$dir" -maxdepth 1 -name '*.so*' \( -type f -o -type l \) -exec cp -an {} "$STAGE/lib/" \;
done
cp -a "$BUILD/libexec/." "$STAGE/libexec/"
cp -a "$BUILD/share/Lagom" "$STAGE/share/"

# Ubuntu 22.04's binutils strip leaves libicudata.so unloadable ("ELF load command address/offset not page-aligned"),
# so llvm-strip is preferred.
STRIP="${STRIP:-$(command -v llvm-strip || command -v strip)}"
for f in "$STAGE"/lib/* "$STAGE"/libexec/*; do
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$(head -c4 "$f")" = "$(printf '\177ELF')" ] || continue
    "$STRIP" --strip-unneeded "$f"
done

tar --zstd -C "$STAGE" -cf "$OUT/webby-prebuilt-linux-x64.tar.zst" lib libexec share
(cd "$OUT" && sha256sum webby-prebuilt-linux-x64.tar.zst | tee webby-prebuilt-linux-x64.tar.zst.sha256)
echo -n "needs glibc "
for f in "$STAGE"/lib/* "$STAGE"/libexec/*; do
    [ -f "$f" ] && [ ! -L "$f" ] && objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' || true
done | sort -u -V | tail -1
