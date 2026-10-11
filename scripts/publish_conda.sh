#!/usr/bin/env bash
# Builds the webby-ladybird conda package from the prebuilt runtime and uploads it to prefix.dev.
# Needs rattler-build (`pixi global install rattler-build`) and PREFIX_API_KEY, a prefix.dev API key with upload
# rights to the channel (sent as `Authorization: Bearer $PREFIX_API_KEY`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANNEL="${CHANNEL:-nandi-testing}"
OUT="${OUT:-$ROOT/build/conda}"

rattler-build build --recipe "$ROOT/conda/webby-ladybird/recipe.yaml" --output-dir "$OUT" -c conda-forge
: "${PREFIX_API_KEY:?set PREFIX_API_KEY}"  # rattler-build reads it from the environment
rattler-build upload prefix --skip-existing --channel "$CHANNEL" "$OUT"/linux-64/webby-ladybird-*.conda
