#!/usr/bin/env bash
# Builds a conda package from conda/<name>/ (default webby-ladybird; `webby` is the app) and uploads it to prefix.dev.
# Needs rattler-build (`pixi global install rattler-build`) and PREFIX_API_KEY, a prefix.dev API key with upload
# rights to the channel (sent as `Authorization: Bearer $PREFIX_API_KEY`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${1:-webby-ladybird}"
CHANNEL="${CHANNEL:-nandi-testing}"
OUT="${OUT:-$ROOT/build/conda}"

rattler-build build --recipe "$ROOT/conda/$PKG/recipe.yaml" --output-dir "$OUT" -c "https://prefix.dev/$CHANNEL" -c conda-forge
: "${PREFIX_API_KEY:?set PREFIX_API_KEY}"  # rattler-build reads it from the environment
rattler-build upload prefix --skip-existing --channel "$CHANNEL" "$OUT"/linux-64/"$PKG"-[0-9]*.conda
