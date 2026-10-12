#!/usr/bin/env bash
# Builds the Ladybird runtime on Ubuntu 22.04 (glibc 2.35) so the webby-ladybird conda package installs on ordinary
# distros, not just ones as new as the build machine. Run it on a Fly Machine with image ubuntu:22.04 and a volume at
# /build; everything big lives there so a restarted Machine picks up where it left off.
# Progress: /build/logs/build.log. Result: /build/BUILD_OK or a BUILD_FAILED line in the log.
set -x
mkdir -p /build/logs
exec > >(tee -a /build/logs/build.log) 2>&1
export DEBIAN_FRONTEND=noninteractive HOME=/root
if [ ! -x /usr/lib/llvm-21/bin/clang ]; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl wget gnupg software-properties-common lsb-release git python3 \
      python3-venv python3-pip ccache ninja-build autoconf autoconf-archive automake build-essential libtool nasm \
      pkg-config zip unzip tar libgl1-mesa-dev libdrm-dev libpulse-dev libncurses-dev glslang-tools xz-utils zstd \
      file bison flex gperf patchelf
    # Ladybird needs C++23: clang 21 from apt.llvm.org and libstdc++ 14 from the toolchain PPA. The runtime then needs
    # a libstdc++ that new at run time, which the conda package gets from conda-forge's libstdcxx.
    wget -qO /usr/share/keyrings/llvm-snapshot.gpg.key https://apt.llvm.org/llvm-snapshot.gpg.key
    echo "deb [signed-by=/usr/share/keyrings/llvm-snapshot.gpg.key] https://apt.llvm.org/jammy/ llvm-toolchain-jammy-21 main" \
      > /etc/apt/sources.list.d/llvm.list
    add-apt-repository -y ppa:ubuntu-toolchain-r/test
    apt-get update -qq
    apt-get install -y -qq clang-21 lld-21 llvm-21 libstdc++-14-dev g++-14
fi
# CMake 3.30+ isn't in jammy.
[ -x /build/venv/bin/cmake ] || { python3 -m venv /build/venv && /build/venv/bin/pip install -q 'cmake>=3.30,<4'; }
export PATH="/usr/lib/llvm-21/bin:/build/venv/bin:$PATH"
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
