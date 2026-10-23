#!/usr/bin/env bash
# Copies the conda-forge packages that `webby` needs at run time into the prefix.dev channel, so
#   pixi global install -c https://prefix.dev/nandi-testing webby
# works with that one channel. Solves webby from nandi-testing + conda-forge (glibc 2.35, like the runtime's floor),
# downloads every conda-forge package in the solution and uploads it (already-present files are skipped).
# Needs pixi, rattler-build and PREFIX_API_KEY. Run after publishing webby/webby-ladybird (publish.yml does).
#
# Builds and the dev workspace list conda-forge *first*: under strict channel priority a package name found in an
# earlier channel hides it in later ones, so nandi-testing first would pin them to these mirrored copies.
# This solve doesn't use strict priority for the same reason: a new webby that needs a newer conda-forge package
# than the mirrored copy (or one not mirrored yet) can't be solved with nandi-testing first, so the solve fell back
# to the previous webby and nothing new got mirrored (2026.10.23.412's xorg-libx11 >=1.8.14).
set -euo pipefail

CHANNEL="${CHANNEL:-nandi-testing}"
GLIBC="${GLIBC:-2.35}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/pixi.toml" <<TOML
[workspace]
name = "webby-mirror"
channels = ["https://prefix.dev/$CHANNEL", "conda-forge"]
platforms = ["linux-64"]
channel-priority = "disabled"

[system-requirements]
libc = "$GLIBC"

[dependencies]
webby = "${WEBBY_VERSION:-*}"
TOML
pixi lock --manifest-path "$WORK/pixi.toml"

# Every package URL in the lock file that isn't already from our channel.
grep -oE 'https?://[^ "]+\.(conda|tar\.bz2)' "$WORK/pixi.lock" | { grep -v "/$CHANNEL/" || true; } | sort -u > "$WORK/urls"
sed 's|/[^/]*/[^/]*$||' "$WORK/urls" | sort | uniq -c
echo "$(wc -l < "$WORK/urls") packages in webby's closure aren't in $CHANNEL yet"
[ -s "$WORK/urls" ] || exit 0
mkdir "$WORK/pkgs"
(cd "$WORK/pkgs" && xargs -n1 -P8 curl -fsSLO --retry 3 < "$WORK/urls")

: "${PREFIX_API_KEY:?set PREFIX_API_KEY}"  # rattler-build reads it from the environment
ls "$WORK/pkgs" | wc -l
rattler-build upload prefix --skip-existing --channel "$CHANNEL" "$WORK"/pkgs/* 2>&1 | tail -n 20
