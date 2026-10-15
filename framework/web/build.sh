#!/usr/bin/env bash
# Builds a nimkit app for the web: <out>/index.html + <out>/app.js, to serve as static files.
# Usage: framework/web/build.sh <app.nim> [out-dir]   (default out-dir: framework/web/build)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(realpath "${1:?app source, e.g. framework/demo/demo.nim}")"
OUT="${2:-$HERE/build}"
mkdir -p "$OUT"
"${NIM:-nim}" js -d:release --hints:off --path:"$HERE/../src" --nimcache:"$OUT/nimcache" -o:"$OUT/app.js" "$APP"
cp "$HERE/index.html" "$OUT/index.html"
echo "Built $OUT/index.html and app.js"
