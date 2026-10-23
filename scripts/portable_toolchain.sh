#!/usr/bin/env bash
# Installs what scripts/portable_build.sh builds Ladybird with on Ubuntu 22.04: clang 21, libstdc++ 14, CMake 3.30+
# (/build/venv), Rust (/build/rustup, /build/cargo). Each part is skipped when already there, so it runs both from
# portable_build.sh and once in scripts/runtime_toolchain.Dockerfile (the image runtime-build.yml runs in).
# Sourced, so the PATH/RUSTUP_HOME/CARGO_HOME exports reach the caller.
export DEBIAN_FRONTEND=noninteractive
if [ ! -x /usr/lib/llvm-21/bin/clang ]; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl wget sudo gnupg software-properties-common lsb-release git python3 \
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
