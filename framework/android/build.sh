#!/usr/bin/env bash
# Builds a nimkit app into an Android APK: the app's Nim code as lib<name>.so under the generic Java host
# (java/dev/nimkit). No Gradle: aapt2, javac, d8, zipalign and apksigner from the SDK, the NDK's clang for Nim.
#
# Usage: framework/android/build.sh <app.nim> <app-id> <label> [version-name] [version-code]
# Output: framework/android/build/<name>.apk (arm64 and x86_64, Android 11+), signed with webby's
# nim/android/debug.keystore (password "android"; not a secret).
#
# Needs: ANDROID_HOME with ndk;$NDK_VERSION, platforms;android-36, build-tools;36.0.0; Nim 2.x as $NIM; a JDK 17+.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(realpath "${1:?app source, e.g. framework/demo/demo.nim}")"
APP_ID="${2:?app id, e.g. dev.nimkit.demo}"
LABEL="${3:?app label}"
VERSION_NAME="${4:-0.1}"
VERSION_CODE="${5:-1}"
NAME="$(basename "$APP" .nim)"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
LLVM="$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin"
BUILD_TOOLS="$ANDROID_HOME/build-tools/36.0.0"
ANDROID_JAR="$ANDROID_HOME/platforms/android-36/android.jar"
NIM="${NIM:-nim}"
OUT="$HERE/build/$NAME"

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/lib"

# The app's Nim code, once per ABI.
for abi in arm64-v8a:arm64:aarch64 x86_64:amd64:x86_64; do
    IFS=: read -r dir cpu triple <<< "$abi"
    CC="$LLVM/$triple-linux-android30-clang"
    mkdir -p "$OUT/lib/$dir"
    "$NIM" c --app:lib --noMain --os:android --cpu:"$cpu" -d:androidNDK --cc:clang \
        --clang.exe="$CC" --clang.linkerexe="$CC" -d:release --opt:speed --mm:orc --hints:off \
        --path:"$HERE/../src" --nimcache:"$OUT/nimcache-$dir" -o:"$OUT/lib/$dir/lib$NAME.so" "$APP"
    "$LLVM/llvm-strip" --strip-unneeded "$OUT/lib/$dir/lib$NAME.so"
done

sed -e "s|@ID@|$APP_ID|" -e "s|@LABEL@|$LABEL|" -e "s|@LIB@|$NAME|" "$HERE/AndroidManifest.xml" > "$OUT/AndroidManifest.xml"
"$BUILD_TOOLS/aapt2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" --manifest "$OUT/AndroidManifest.xml" \
    --min-sdk-version 30 --target-sdk-version 34 --version-code "$VERSION_CODE" --version-name "$VERSION_NAME"

javac -source 11 -target 11 -Xlint:-options -encoding UTF-8 -cp "$ANDROID_JAR" -d "$OUT/classes" \
    $(find "$HERE/java" -name '*.java')
"$BUILD_TOOLS/d8" --release --min-api 30 --lib "$ANDROID_JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

python3 - "$OUT/base.apk" "$OUT/dex/classes.dex" "$OUT/lib" <<'PY'
import os, sys, zipfile
apk, dex, libs = sys.argv[1:]
with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as z:
    z.write(dex, "classes.dex")
    for abi in sorted(os.listdir(libs)):
        for name in sorted(os.listdir(os.path.join(libs, abi))):
            z.write(os.path.join(libs, abi, name), f"lib/{abi}/{name}", zipfile.ZIP_STORED)
PY
KEYSTORE="${NIMKIT_KEYSTORE:-$HERE/../../nim/android/debug.keystore}"
APK="$HERE/build/$NAME.apk"
"$BUILD_TOOLS/zipalign" -f -P 16 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --ks-key-alias androiddebugkey --out "$APK" "$OUT/aligned.apk"
echo "APK: $APK ($(du -h "$APK" | cut -f1))"
