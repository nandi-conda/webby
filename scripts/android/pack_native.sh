#!/usr/bin/env bash
# Packs the Android native part from the Ladybird build of scripts/android/build_ladybird.sh: Ladybird's libraries
# and helper processes in jniLibs/<abi>/ and its resources in assets/lagom.zip, as one tarball. The app
# (nim/android-kit/build.sh) is built from such a tarball, so CI never cross-compiles Ladybird; publish it with
# scripts/android/release_native.sh.
#
# Usage: scripts/android/pack_native.sh <out.tar.zst>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_FILE="$(realpath -m "$1")"
TOOLS="${WEBBY_ANDROID_TOOLS:-/build/android-tools}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
ANDROID_ABI=arm64-v8a
LADYBIRD_DIR="${LADYBIRD_DIR:-$ROOT/third_party/ladybird}"
PREFIX="$LADYBIRD_DIR/Build/android-$ANDROID_ABI"
STRIP="${ANDROID_HOME:-$TOOLS/sdk}/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Native libraries: libwebby.so (plus any shared library it was built with), and the helper processes renamed to
# lib<Name>.so, so the APK installs them as files the app may run (see LadybirdRuntime.java).
JNI="$WORK/jniLibs/$ANDROID_ABI"
mkdir -p "$JNI"
for library in "$PREFIX"/lib/*.so; do
    # vcpkg's Vulkan validation layer is a debugging aid, not something the app loads.
    case "$(basename "$library")" in libVkLayer_*) continue ;; esac
    "$STRIP" --strip-unneeded -o "$JNI/$(basename "$library")" "$library"
done
for helper in WebContent RequestServer ImageDecoder Compositor MediaServer WebWorker WasmCompiler; do
    "$STRIP" --strip-unneeded -o "$JNI/lib$helper.so" "$PREFIX/libexec/$helper"
done
# WasmCompiler runs this to turn WebAssembly into machine code (LadybirdRuntime.java points LADYBIRD_CRANELIFT_COMPILER at it).
"$STRIP" --strip-unneeded -o "$JNI/libcranelift-compiler.so" "$PREFIX/bin/cranelift-compiler"

# Ladybird's resources, unpacked on first start.
mkdir -p "$WORK/assets"
(cd "$PREFIX/share/Lagom" && zip -qrX "$WORK/assets/lagom.zip" .)

tar -c -C "$WORK" jniLibs assets | zstd -19 -T0 -q -f -o "$OUT_FILE"
echo "Native part: $OUT_FILE"
