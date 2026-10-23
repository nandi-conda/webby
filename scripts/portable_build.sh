#!/usr/bin/env bash
# Builds the Ladybird runtime on Ubuntu 22.04 (glibc 2.35) so the webby-ladybird conda package installs on ordinary
# distros, not just ones as new as the build machine. Run it on a Fly Machine with image ubuntu:22.04 and a volume at
# /build; everything big lives there so a restarted Machine picks up where it left off.
# Progress: /build/logs/build.log. Result: /build/BUILD_OK or a BUILD_FAILED line in the log.
set -x
mkdir -p /build/logs
exec > >(tee -a /build/logs/build.log) 2>&1
export DEBIAN_FRONTEND=noninteractive HOME=/root
# The toolchain install is its own script so the runtime-build CI image can bake it in; fetch it when this script was
# copied somewhere on its own (a Fly Machine).
toolchain="$(dirname "$0")/portable_toolchain.sh"
[ -f "$toolchain" ] || toolchain=<(curl -fsSL https://raw.githubusercontent.com/nandi-conda/webby/main/scripts/portable_toolchain.sh)
source "$toolchain"

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
