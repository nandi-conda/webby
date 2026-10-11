#!/usr/bin/env bash
# Builds Ladybird + libwebby.so on a Fly Machine (Ubuntu 26.04 image) with a volume mounted at /build.
# Everything big (sources, build tree, caches) lives on the volume so a restarted Machine picks up where it left off.
# Progress: /build/logs/build.log. Result: /build/BUILD_OK or a BUILD_FAILED line in the log.
set -x
mkdir -p /build/logs
exec > >(tee -a /build/logs/build.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git python3 python3-venv ccache cmake ninja-build clang lld llvm \
  autoconf autoconf-archive automake build-essential libtool nasm pkg-config zip unzip tar libgl1-mesa-dev \
  libdrm-dev libpulse-dev libncurses-dev glslang-tools fonts-liberation2 libgtk-3-dev xvfb xauth x11-utils \
  imagemagick xdotool xz-utils file bison flex gperf
export RUSTUP_HOME=/build/rustup CARGO_HOME=/build/cargo
[ -x /build/cargo/bin/cargo ] || curl -sSf https://sh.rustup.rs | sh -s -- -y -q --no-modify-path --default-toolchain 1.98.0
export PATH="/build/cargo/bin:$PATH"

cd /build
if [ -d webby/.git ]; then git -C webby pull -q --ff-only; else git clone -q https://github.com/nandi-conda/webby.git; fi
export LADYBIRD_DIR=/build/ladybird CC=clang CXX=clang++ LINKER=lld
export CCACHE_DIR=/build/ccache CCACHE_MAXSIZE=30G
if webby/scripts/build_ladybird.sh; then
    touch /build/BUILD_OK
    echo "=== BUILD_OK $(date -u)"
else
    echo "=== BUILD_FAILED $(date -u)"
fi
