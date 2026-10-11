#!/usr/bin/env bash
# Downloads Flutter and the prebuilt Ladybird runtime into third_party/ (skipped when already there).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_VERSION=3.35.5
PREBUILT_VERSION=2026.10.10
PREBUILT_URL=https://gitlab.latha.org/api/v4/projects/4/packages/generic/webby-prebuilt/$PREBUILT_VERSION
mkdir -p "$ROOT/third_party"
cd "$ROOT/third_party"

if [ ! -x flutter/bin/flutter ]; then
  echo "Downloading Flutter $FLUTTER_VERSION..."
  curl -fL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz \
    | tar -xJ --no-same-owner
fi

# A WEBBY_LADYBIRD_PREFIX from the environment (e.g. your own Ladybird build) wins over the prebuilt.
if [ -z "${WEBBY_LADYBIRD_PREFIX:-}" ] && [ ! -f webby-prebuilt/lib/libwebby.so ]; then
  echo "Downloading webby-prebuilt $PREBUILT_VERSION..."
  rm -rf webby-prebuilt webby-prebuilt-linux-x64.tar.zst*
  curl -fLO "$PREBUILT_URL/webby-prebuilt-linux-x64.tar.zst" -fLO "$PREBUILT_URL/webby-prebuilt-linux-x64.tar.zst.sha256"
  sha256sum -c webby-prebuilt-linux-x64.tar.zst.sha256
  tar --zstd --no-same-owner -xf webby-prebuilt-linux-x64.tar.zst
  rm webby-prebuilt-linux-x64.tar.zst webby-prebuilt-linux-x64.tar.zst.sha256
fi
