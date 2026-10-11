#!/usr/bin/env bash
# Downloads Flutter into third_party/ (skipped when already there). The Ladybird runtime comes from the
# webby-ladybird conda package (see pixi.toml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_VERSION=3.35.5
mkdir -p "$ROOT/third_party"
cd "$ROOT/third_party"

if [ ! -x flutter/bin/flutter ]; then
  echo "Downloading Flutter $FLUTTER_VERSION..."
  curl -fL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz \
    | tar -xJ --no-same-owner
fi
