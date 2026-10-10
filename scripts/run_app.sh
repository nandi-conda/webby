#!/usr/bin/env bash
# Runs the Flutter app against a Ladybird prefix built by scripts/build_ladybird.sh.
# Extra arguments go to `flutter run` (e.g. -a https://example.com to open a URL on start).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WEBBY_LADYBIRD_PREFIX="${WEBBY_LADYBIRD_PREFIX:-${LADYBIRD_DIR:-$ROOT/third_party/ladybird}/Build/release}"

cd "$ROOT/app"
# The Linux runner is stock `flutter create` output, so it's generated rather than checked in.
[ -d linux ] || flutter create --platforms=linux --project-name webby --org dev.webby .
flutter run -d linux "$@"
