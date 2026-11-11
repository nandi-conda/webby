# syntax=docker/dockerfile:1
# The WASI sysroot (WEBBY_WASI_SYSROOT=/opt/webby-wasi): every dependency deps/all.sh builds, packed as
# /webby-wasi-sysroot.tar.zst. Built by ci/forge_wasm.py with `depot build` (context: the repo root).
#
# One layer per stage, so a run cut off by the forge's one-hour limit keeps the stages it finished. The sources and
# build directories are BuildKit cache mounts that Depot keeps between builds, so a change to one script rebuilds
# the stages after it incrementally. The sysroot's .pc and CMake files name /opt/webby-wasi, so it has to be
# unpacked there (ci/engine.Dockerfile does).
FROM ubuntu:24.04 AS base
COPY wasm/ci/base.sh /tmp/base.sh
RUN bash /tmp/base.sh
ENV WASI_SDK_PREFIX=/opt/wasi-sdk WEBBY_WASI_SYSROOT=/opt/webby-wasi PATH=/opt/venv/bin:/root/.cargo/bin:$PATH

FROM base AS deps
COPY wasm/deps /w/deps
COPY wasm/compat /w/compat
COPY wasm/cmake /w/cmake
COPY wasm/tools/meson-wasi-cc /w/tools/meson-wasi-cc
RUN --mount=type=cache,id=webby-wasi-src,target=/cache/src --mount=type=cache,id=webby-wasi-work,target=/cache/work \
    /w/deps/all.sh /cache/src /cache/work fetch compat
RUN --mount=type=cache,id=webby-wasi-src,target=/cache/src --mount=type=cache,id=webby-wasi-work,target=/cache/work \
    /w/deps/all.sh /cache/src /cache/work icu
RUN --mount=type=cache,id=webby-wasi-src,target=/cache/src --mount=type=cache,id=webby-wasi-work,target=/cache/work \
    /w/deps/all.sh /cache/src /cache/work openssl libpsl cmake-deps header-deps
RUN --mount=type=cache,id=webby-wasi-src,target=/cache/src --mount=type=cache,id=webby-wasi-work,target=/cache/work \
    /w/deps/all.sh /cache/src /cache/work libweb-deps
RUN --mount=type=cache,id=webby-wasi-src,target=/cache/src --mount=type=cache,id=webby-wasi-work,target=/cache/work \
    /w/deps/all.sh /cache/src /cache/work media-deps
RUN --mount=type=cache,id=webby-wasi-src,target=/cache/src --mount=type=cache,id=webby-wasi-work,target=/cache/work \
    /w/deps/all.sh /cache/src /cache/work skia
RUN --mount=type=cache,id=webby-wasi-src,target=/cache/src --mount=type=cache,id=webby-wasi-work,target=/cache/work \
    /w/deps/all.sh /cache/src /cache/work binaryen
RUN mkdir /export && tar -C /opt -cf - webby-wasi | zstd -q -T0 -10 -o /export/webby-wasi-sysroot.tar.zst \
    && ls -l /export && du -sh /opt/webby-wasi

FROM scratch AS out
COPY --from=deps /export/ /
