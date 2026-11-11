# syntax=docker/dockerfile:1
# The engine for wasm32-wasip1 (ci/engine.sh): Ladybird with webby's patches, built against the sysroot the
# wasm-deps job published. Built by ci/forge_wasm.py with `depot build` (context: the repo root), which first puts
# that sysroot at wasm/ci/out/webby-wasi-sysroot.tar.zst. Exports /export: status, build.log, <target>.wasm.
FROM ubuntu:24.04 AS base
COPY wasm/ci/base.sh /tmp/base.sh
RUN bash /tmp/base.sh
ENV WASI_SDK_PREFIX=/opt/wasi-sdk WEBBY_WASI_SYSROOT=/opt/webby-wasi PATH=/opt/venv/bin:/root/.cargo/bin:$PATH

FROM base AS engine
COPY wasm/ci/out/webby-wasi-sysroot.tar.zst /tmp/sysroot.tar.zst
RUN tar -C /opt -I zstd -xf /tmp/sysroot.tar.zst && rm /tmp/sysroot.tar.zst
COPY LADYBIRD_COMMIT /w/LADYBIRD_COMMIT
COPY patches /w/patches
COPY wasm/build-engine.sh /w/wasm/build-engine.sh
COPY wasm/cmake /w/wasm/cmake
COPY wasm/compat /w/wasm/compat
COPY wasm/tools /w/wasm/tools
COPY wasm/tests /w/wasm/tests
COPY wasm/patches /w/wasm/patches
COPY wasm/ui /w/wasm/ui
COPY wasm/ci/engine.sh /w/wasm/ci/engine.sh
ARG TARGETS=js
ARG BUDGET=2700
# Changes every run, so the build step always runs (ninja decides what is out of date).
ARG RUN_ID
RUN --mount=type=cache,id=webby-wasm-engine,target=/cache \
    echo "run $RUN_ID" && TARGETS="$TARGETS" BUDGET="$BUDGET" bash /w/wasm/ci/engine.sh

FROM scratch AS out
COPY --from=engine /export/ /
