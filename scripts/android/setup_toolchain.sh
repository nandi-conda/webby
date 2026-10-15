#!/usr/bin/env bash
# Installs what the Android build needs on an Ubuntu 26.04 host (the Fly build machine): Android SDK, NDK and
# platform, and Rust with the Android target. Everything lands under $WEBBY_ANDROID_TOOLS (default
# /build/android-tools) so a restarted machine with the same volume skips the downloads.
#
# System packages first (as root): see the apt-get line in scripts/android/fly_build.sh.
set -euo pipefail

TOOLS="${WEBBY_ANDROID_TOOLS:-/build/android-tools}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
RUST_VERSION="${RUST_VERSION:-1.98.0}"
CMDLINE_TOOLS_ZIP=commandlinetools-linux-13114758_latest.zip

mkdir -p "$TOOLS"
export ANDROID_HOME="$TOOLS/sdk"

if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
    curl -fsSL -o "$TOOLS/cmdline-tools.zip" "https://dl.google.com/android/repository/$CMDLINE_TOOLS_ZIP"
    rm -rf "$ANDROID_HOME/cmdline-tools"
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    unzip -q "$TOOLS/cmdline-tools.zip" -d "$ANDROID_HOME/cmdline-tools"
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    rm "$TOOLS/cmdline-tools.zip"
fi
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
yes | "$SDKMANAGER" --licenses > /dev/null || true
"$SDKMANAGER" --install "platform-tools" "platforms;android-36" "platforms;android-35" "build-tools;36.0.0" \
    "build-tools;35.0.0" "ndk;$NDK_VERSION" "cmake;3.22.1" > /dev/null

export RUSTUP_HOME="$TOOLS/rustup" CARGO_HOME="$TOOLS/cargo"
if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y -q --no-modify-path --default-toolchain "$RUST_VERSION" --profile minimal
fi
"$CARGO_HOME/bin/rustup" toolchain install "$RUST_VERSION" --profile minimal -c rustfmt -c clippy
"$CARGO_HOME/bin/rustup" target add --toolchain "$RUST_VERSION" aarch64-linux-android

git config --global --add safe.directory '*'

echo "Android tools ready in $TOOLS"
