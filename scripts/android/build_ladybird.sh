#!/usr/bin/env bash
# Cross-compiles Ladybird's helper processes and libwebby.so for Android with the NDK.
#
# Usage: scripts/android/build_ladybird.sh                 # arm64-v8a
#        ANDROID_ABI=x86_64 scripts/android/build_ladybird.sh
#
# Needs the tools from scripts/android/setup_toolchain.sh. The result is $LADYBIRD_DIR/Build/android-<abi>:
# lib/libwebby.so, libexec/<helpers> and share/Lagom, the same layout as the Linux prefix. scripts/android/build_apk.sh
# packs it into the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLS="${WEBBY_ANDROID_TOOLS:-/build/android-tools}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
ANDROID_API="${ANDROID_API:-30}"
export LADYBIRD_DIR="${LADYBIRD_DIR:-$ROOT/third_party/ladybird}"

case "$ANDROID_ABI" in
    arm64-v8a) RUST_TRIPLE=aarch64-linux-android ;;
    x86_64) RUST_TRIPLE=x86_64-linux-android ;;
    *) echo "Unsupported ANDROID_ABI $ANDROID_ABI" >&2; exit 1 ;;
esac

export ANDROID_HOME="$TOOLS/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$NDK_VERSION"
export RUSTUP_HOME="$TOOLS/rustup" CARGO_HOME="$TOOLS/cargo"
export PATH="$CARGO_HOME/bin:$PATH"

# Same checkout, patches and vcpkg tool as the Linux build. CC/CXX only go to that step: exported, they'd override
# the NDK compilers in vcpkg's autotools ports.
CC="${HOST_CC:-clang}" CXX="${HOST_CXX:-clang++}" WEBBY_PREPARE_ONLY=1 "$ROOT/scripts/build_ladybird.sh"
export VCPKG_ROOT="$LADYBIRD_DIR/Build/vcpkg-release"

BUILD_DIR="$LADYBIRD_DIR/Build/android-$ANDROID_ABI"
cd "$LADYBIRD_DIR"
if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    # VCPKG_TARGET_ANDROID makes Ladybird chain vcpkg's toolchain with the NDK's (UI/Android/vcpkg_android.cmake).
    # The helpers are plain executables here, not Ladybird's Android services: the app ships them as lib*.so files
    # and runs them from its native library directory. Everything links libc++ statically, so the helpers need no
    # libc++_shared.so next to them.
    cmake -S . -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLADYBIRD_VCPKG_TYPE=release \
        -DVCPKG_TARGET_ANDROID=ON \
        -DANDROID_NDK="$ANDROID_NDK_HOME" \
        -DANDROID_ABI="$ANDROID_ABI" \
        -DANDROID_PLATFORM="android-$ANDROID_API" \
        -DANDROID_STL=c++_static \
        -DRUST_TARGET_TRIPLE="$RUST_TRIPLE" \
        -DLADYBIRD_UI_FLUTTER=ON \
        -DBUILD_TESTING=OFF \
        -DENABLE_LTO_FOR_RELEASE=OFF \
        -DENABLE_CRANELIFT_JIT=OFF
fi

cmake --build "$BUILD_DIR" --target ladybird

echo
echo "Android Ladybird prefix: $BUILD_DIR"
