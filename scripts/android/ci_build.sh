#!/usr/bin/env bash
# Builds the Android native part (scripts/android/build_ladybird.sh + pack_native.sh) inside an ubuntu:26.04 container,
# the same host the Fly android-build machine used. .github/workflows/android-native-build.yml runs it with the
# checkout at /build/webby and /build kept between runs (ccache, vcpkg binary cache, Android tools).
# Result: /build/out/webby-android-native-arm64.tar.zst, or a non-zero exit.
set -euxo pipefail
# A failed vcpkg port only says "see logs"; print the logs of the ports that failed, which the runner throws away.
dump_vcpkg_failures() {
    find /build/ladybird/Build/vcpkg-release/buildtrees -maxdepth 2 \( -name '*-out.log' -o -name '*-err.log' -o -name 'config-*.log' \) \
        -size +0 2>/dev/null | xargs -r grep -l -i -E 'error|failed' | while read -r log; do echo "=== $log"; tail -n 80 "$log"; done
}
trap 'status=$?; [ $status -eq 0 ] || dump_vcpkg_failures; exit $status' EXIT
export DEBIAN_FRONTEND=noninteractive HOME=/root
# No host libpulse-dev: the Android configure would find it and build the PulseAudio backend against missing headers.
apt-get update -qq
apt-get install -y -qq ca-certificates curl git python3 python3-venv ccache cmake ninja-build clang lld llvm \
  autoconf autoconf-archive automake build-essential libtool nasm pkg-config zip unzip tar libgl1-mesa-dev \
  libdrm-dev libncurses-dev glslang-tools xz-utils zstd file bison flex gperf default-jdk-headless
git config --global --add safe.directory '*'

export WEBBY_ANDROID_TOOLS=/build/android-tools LADYBIRD_DIR=/build/ladybird
export CCACHE_DIR=/build/ccache CCACHE_MAXSIZE=6G
export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
export VCPKG_DEFAULT_BINARY_CACHE=/build/vcpkg-cache
mkdir -p "$VCPKG_DEFAULT_BINARY_CACHE"
/build/webby/scripts/android/setup_toolchain.sh
# -k 0: a failed build reports every broken file, not only the first.
WEBBY_NINJA_ARGS="-k 0" /build/webby/scripts/android/build_ladybird.sh
ccache -s || true
mkdir -p /build/out
/build/webby/scripts/android/pack_native.sh /build/out/webby-android-native-arm64.tar.zst
