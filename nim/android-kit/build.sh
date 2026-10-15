#!/usr/bin/env bash
# Builds webby on nimkit for Android: the desktop's Nim front end (nim/webby.nim) as libwebbykit.so under nimkit's
# generic Host (framework/android/java) plus WebbyHost (java/dev/webby/kit), and Ladybird's native part (the same
# prebuilt one the Flutter APK uses, scripts/android/native.env), into one APK. No Gradle: aapt2, javac, d8,
# zipalign and apksigner from the Android SDK, and the NDK's clang for Nim.
#
# Usage: nim/android-kit/build.sh <native.tar.zst> [version-name] [version-code]
# Output: nim/android-kit/build/webby-kit-android-arm64.apk (arm64, Android 11 or newer), signed with
# nim/android/debug.keystore (password "android"; not a secret).
#
# Needs: ANDROID_HOME with ndk;$NDK_VERSION, platforms;android-36, build-tools;36.0.0; Nim 2.x as $NIM (or on PATH);
# a JDK 17+; python3, zstd; rsvg-convert for the launcher icon.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NATIVE="$(realpath "${1:?native part tarball (webby-android-native-arm64.tar.zst)}")"
VERSION_NAME="${2:-0.1}"
VERSION_CODE="${3:-1}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
BUILD_TOOLS="$ANDROID_HOME/build-tools/36.0.0"
ANDROID_JAR="$ANDROID_HOME/platforms/android-36/android.jar"
NIM="${NIM:-nim}"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC="$LLVM/aarch64-linux-android30-clang"
OUT="$HERE/build"

rm -rf "$OUT/apk" "$OUT/res" "$OUT/classes" "$OUT/dex"
mkdir -p "$OUT/apk/lib/arm64-v8a" "$OUT/apk/assets" "$OUT/res" "$OUT/classes" "$OUT/dex"

# Ladybird: libwebby.so, the helper processes as lib<Name>.so, and its resources (assets/lagom.zip).
zstd -dc "$NATIVE" | tar -x -C "$OUT" jniLibs assets
cp "$OUT"/jniLibs/arm64-v8a/*.so "$OUT/apk/lib/arm64-v8a/"
cp "$OUT/assets/lagom.zip" "$OUT/apk/assets/"
rm -rf "$OUT/jniLibs" "$OUT/assets"

# The Nim front end, with nimkit's JNI glue compiled in (framework/android/glue.c).
"$NIM" c --app:lib --noMain --os:android --cpu:arm64 -d:androidNDK --cc:clang \
    --clang.exe="$CC" --clang.linkerexe="$CC" -d:release --opt:speed --mm:orc --hints:off \
    --nimcache:"$OUT/nimcache" -o:"$OUT/apk/lib/arm64-v8a/libwebbykit.so" "$ROOT/nim/webby.nim"
"$LLVM/llvm-strip" --strip-unneeded "$OUT/apk/lib/arm64-v8a/libwebbykit.so"

# Resources: the theme and the launcher icon.
cp -r "$HERE/res/." "$OUT/res/"
for density in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    mkdir -p "$OUT/res/mipmap-${density%%:*}"
    rsvg-convert -w "${density##*:}" -h "${density##*:}" "$ROOT/icons/webby.svg" -o "$OUT/res/mipmap-${density%%:*}/ic_launcher.png"
done
"$BUILD_TOOLS/aapt2" compile --dir "$OUT/res" -o "$OUT/res.zip"
"$BUILD_TOOLS/aapt2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 30 --target-sdk-version 34 \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" -A "$OUT/apk/assets" "$OUT/res.zip"

# nimkit's Host and webby's subclass.
javac -source 11 -target 11 -Xlint:-options -encoding UTF-8 -cp "$ANDROID_JAR" -d "$OUT/classes" \
    $(find "$ROOT/framework/android/java" "$HERE/java" -name '*.java')
"$BUILD_TOOLS/d8" --release --min-api 30 --lib "$ANDROID_JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

# Into the APK, aligned and signed.
python3 - "$OUT/base.apk" "$OUT/dex/classes.dex" "$OUT/apk/lib/arm64-v8a" <<'PY'
import os, sys, zipfile
apk, dex, libs = sys.argv[1:]
with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as z:
    z.write(dex, "classes.dex")
    for name in sorted(os.listdir(libs)):
        z.write(os.path.join(libs, name), "lib/arm64-v8a/" + name)
PY
KEYSTORE="${WEBBY_ANDROID_KEYSTORE:-$ROOT/nim/android/debug.keystore}"
APK="$OUT/webby-kit-android-arm64.apk"
"$BUILD_TOOLS/zipalign" -f -P 16 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --ks-key-alias androiddebugkey --out "$APK" "$OUT/aligned.apk"
rm -f "$OUT/base.apk" "$OUT/aligned.apk" "$OUT/res.zip"
echo "APK: $APK ($(du -h "$APK" | cut -f1))"
