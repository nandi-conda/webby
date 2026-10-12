#!/usr/bin/env bash
# Publishes the Android native part (jniLibs/ and assets/lagom.zip, as packed by scripts/android/build_apk.sh) as the
# GitHub Release `webby-android-native-<version>`, which .github/workflows/android-apk.yml builds the APK from.
# Run on the build machine after scripts/android/build_ladybird.sh and build_apk.sh, then put the printed version and
# sha256 in scripts/android/native.env and push.
#
# Usage: GH_TOKEN=... scripts/android/release_native.sh <version>      (run inside the checkout the native part was built from)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="$1"
REPO="${GITHUB_REPOSITORY:-nandi-conda/webby}"
# WEBBY_ANDROID_MAIN: where jniLibs/ and assets/ are, if not this checkout (e.g. a copy a rebuild cannot change).
MAIN="${WEBBY_ANDROID_MAIN:-$ROOT/app/android/app/src/main}"
OUT="$(mktemp -d)"
ASSET=webby-android-native-arm64.tar.zst

tar -c -C "$MAIN" jniLibs assets | zstd -19 -T0 -q -o "$OUT/$ASSET"
SHA256="$(sha256sum "$OUT/$ASSET" | cut -d' ' -f1)"
echo "$SHA256  $ASSET" > "$OUT/$ASSET.sha256"

API="https://api.github.com/repos/$REPO"
AUTH=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")
BODY="$(printf '{"tag_name":"webby-android-native-%s","target_commitish":"%s","name":"webby-android-native %s","body":"Ladybird for Android arm64 (jniLibs + assets/lagom.zip), built from %s. Used by the android-apk workflow.","prerelease":true}' \
    "$VERSION" "$(git rev-parse HEAD)" "$VERSION" "$(git rev-parse --short HEAD)")"
UPLOAD="$(curl -fsS "${AUTH[@]}" -d "$BODY" "$API/releases" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')"
for file in "$ASSET" "$ASSET.sha256"; do
    curl -fsS "${AUTH[@]}" -H "Content-Type: application/octet-stream" -X POST -T "$OUT/$file" "$UPLOAD?name=$file" > /dev/null
done
rm -rf "$OUT"
echo "NATIVE_VERSION=$VERSION"
echo "NATIVE_SHA256=$SHA256"
