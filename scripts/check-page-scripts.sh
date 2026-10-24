#!/usr/bin/env bash
# Syntax-checks the page scripts in nim/src/scripts. They are Nim format strings (${expr} / $name are filled in at
# build time), so each placeholder becomes a 0 before node --check reads it. A script with a syntax error runs as
# nothing in the page, with only an engine log line to show for it (Summarize stopped working that way).
set -euo pipefail
cd "$(dirname "$0")/../nim/src/scripts"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
for f in *.js; do
  sed -E 's/\$\{[^}]*\}/0/g; s/\$[A-Za-z_][A-Za-z0-9_]*/0/g' "$f" > "$tmp/$f"
  node --check "$tmp/$f" 2> "$tmp/err" || { echo "::error file=nim/src/scripts/$f::$(grep -m1 Error "$tmp/err")"; cat "$tmp/err"; fail=1; }
done
exit $fail
