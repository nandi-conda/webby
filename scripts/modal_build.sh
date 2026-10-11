#!/usr/bin/env bash
# Builds Ladybird + libwebby.so + the Flutter app inside a fresh Ubuntu 24.04 Modal sandbox.
# Persistent caches live on the volume mounted at /build (vcpkg binary cache, ccache).
set -x
exec > >(tee -a /build/logs/build.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget gnupg ca-certificates curl git python3 python3-pip python3-venv ccache \
  clang-20 lld-20 libclang-rt-20-dev autoconf autoconf-archive automake build-essential ninja-build libtool nasm \
  pkg-config zip unzip tar libgl1-mesa-dev libdrm-dev libpulse-dev libncurses-dev glslang-tools fonts-liberation2 \
  libgtk-3-dev libstdc++-14-dev xvfb xauth x11-utils imagemagick xdotool libegl1 mesa-utils xz-utils file bison flex gperf
pip install -q --break-system-packages 'cmake>=3.30'
curl -sSf https://sh.rustup.rs | sh -s -- -y -q --default-toolchain 1.98.0
source $HOME/.cargo/env
( cd /opt && curl -sSL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.35.5-stable.tar.xz | tar xJ \
  && git config --global --add safe.directory /opt/flutter && /opt/flutter/bin/flutter --disable-analytics \
  && /opt/flutter/bin/flutter precache --linux ) > /build/logs/flutter.log 2>&1 &
echo SETUP_DONE
mkdir -p /work && cd /work
git clone -q https://github.com/nandi-conda/webby.git
git clone -q https://github.com/LadybirdBrowser/ladybird.git
export LADYBIRD_DIR=/work/ladybird CC=clang-20 CXX=clang++-20
export VCPKG_BINARY_SOURCES="clear;files,/build/vcpkg-binary-cache,readwrite"
export CCACHE_DIR=/build/ccache CCACHE_MAXSIZE=30G
/work/webby/scripts/build_ladybird.sh && echo BUILD_OK || echo BUILD_FAILED
