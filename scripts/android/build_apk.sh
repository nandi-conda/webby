#!/usr/bin/env bash
# Builds the Android app around the Ladybird build from scripts/android/build_ladybird.sh.
#
# Usage: scripts/android/build_apk.sh [debug|release] [flutter build args...]      (default: debug)
# Output: app/build/app/outputs/flutter-apk/app-<mode>.apk, for arm64 phones running Android 11 or newer.
#
# The native part (Ladybird's libraries and helpers in jniLibs/, its resources in assets/lagom.zip) can be saved and
# reused, which is how CI builds the APK without cross-compiling Ladybird (.github/workflows/android-apk.yml):
#   WEBBY_ANDROID_NATIVE_OUT=native.tar.zst   also writes the native part as a tarball after packing it
#   WEBBY_ANDROID_NATIVE=native.tar.zst       takes the native part from such a tarball instead of the Ladybird build
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="${WEBBY_ANDROID_TOOLS:-/build/android-tools}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
MODE="${1:-debug}"
shift || true
ANDROID_ABI=arm64-v8a
LADYBIRD_DIR="${LADYBIRD_DIR:-$ROOT/third_party/ladybird}"
PREFIX="$LADYBIRD_DIR/Build/android-$ANDROID_ABI"

export ANDROID_HOME="$TOOLS/sdk"
export PATH="$TOOLS/flutter/bin:$PATH"
STRIP="$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
MAIN="$ROOT/app/android/app/src/main"

if [ -n "${WEBBY_ANDROID_NATIVE:-}" ]; then
    rm -rf "$MAIN/jniLibs" "$MAIN/assets"
    zstd -dc "$WEBBY_ANDROID_NATIVE" | tar -x -C "$MAIN"
else
    # Native libraries: libwebby.so (plus any shared library it was built with), and the helper processes renamed to
    # lib<Name>.so, so the APK installs them as files the app may run (see LadybirdRuntime.kt).
    JNI="$MAIN/jniLibs/$ANDROID_ABI"
    rm -rf "$MAIN/jniLibs"
    mkdir -p "$JNI"
    for library in "$PREFIX"/lib/*.so; do
        # vcpkg's Vulkan validation layer is a debugging aid, not something the app loads.
        case "$(basename "$library")" in libVkLayer_*) continue ;; esac
        "$STRIP" --strip-unneeded -o "$JNI/$(basename "$library")" "$library"
    done
    for helper in WebContent RequestServer ImageDecoder Compositor MediaServer WebWorker WasmCompiler; do
        "$STRIP" --strip-unneeded -o "$JNI/lib$helper.so" "$PREFIX/libexec/$helper"
    done
    # WasmCompiler runs this to turn WebAssembly into machine code (LadybirdRuntime.kt points LADYBIRD_CRANELIFT_COMPILER at it).
    "$STRIP" --strip-unneeded -o "$JNI/libcranelift-compiler.so" "$PREFIX/bin/cranelift-compiler"

    # Ladybird's resources, unpacked on first start.
    ASSETS="$MAIN/assets"
    rm -rf "$ASSETS"
    mkdir -p "$ASSETS"
    (cd "$PREFIX/share/Lagom" && zip -qrX "$ASSETS/lagom.zip" .)

    if [ -n "${WEBBY_ANDROID_NATIVE_OUT:-}" ]; then
        tar -c -C "$MAIN" jniLibs assets | zstd -19 -T0 -q -f -o "$WEBBY_ANDROID_NATIVE_OUT"
        echo "Native part: $WEBBY_ANDROID_NATIVE_OUT"
    fi
fi

# Launcher icon, rendered from icons/webby.svg.
for density in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    mkdir -p "$MAIN/res/mipmap-${density%%:*}"
    rsvg-convert -w "${density##*:}" -h "${density##*:}" "$ROOT/icons/webby.svg" -o "$MAIN/res/mipmap-${density%%:*}/ic_launcher.png"
done

cd "$ROOT/app"
flutter pub get
flutter build apk "--$MODE" --target-platform android-arm64 "$@"
echo "APK: $ROOT/app/build/app/outputs/flutter-apk/app-$MODE.apk"
