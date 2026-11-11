#!/usr/bin/env bash
# The build image both wasm jobs start from (ci/deps.Dockerfile and ci/engine.Dockerfile run it as their first layer,
# so Depot caches it once): Ubuntu 24.04 host tools (GCC 13 for the few host programs: ICU's data tools, binaryen, build scripts), wasi-sdk 27 in /opt/wasi-sdk (the version qt2wasm ships),
# CMake/Ninja/Meson and PyPI wasmtime (tools/wasi-run.py) in /opt/venv, and Ladybird's Rust toolchain with the
# wasm32-wasip1 standard library (rustup in /root/.cargo).
set -euo pipefail
WASI_SDK_VERSION=27.0
# Ladybird's rust-toolchain.toml at ../LADYBIRD_COMMIT; ci/engine.sh stops if the checkout asks for another one.
RUST_TOOLCHAIN=1.98.0
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl git build-essential perl python3 \
  python3-venv pkg-config xz-utils zstd file unzip fonts-liberation > /dev/null
rm -rf /var/lib/apt/lists/*
curl -fsSL "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION%%.*}/wasi-sdk-${WASI_SDK_VERSION}-x86_64-linux.tar.gz" \
  | tar -xz -C /opt
mv "/opt/wasi-sdk-${WASI_SDK_VERSION}-x86_64-linux" /opt/wasi-sdk
python3 -m venv /opt/venv
/opt/venv/bin/pip install -q "cmake>=3.30" ninja meson "wasmtime==50.*"
curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain "$RUST_TOOLCHAIN" \
  --target wasm32-wasip1 > /dev/null
/root/.cargo/bin/rustup component add --toolchain "$RUST_TOOLCHAIN" rustfmt clippy > /dev/null
/opt/wasi-sdk/bin/clang --version | head -1
/opt/venv/bin/cmake --version | head -1
/root/.cargo/bin/rustc --version
