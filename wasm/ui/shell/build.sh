#!/usr/bin/env bash
# Build webby's UI component (this directory, no Ladybird build) and compose it with the engine component into
# webby.wasm, the latha:gui app:
#   wasm/ui/shell/build.sh [BUILD_DIR]        (default wasm/ui/shell/build)
# env:
#   WEBBY_QT_ENV     env with qt2wasm, qt6-wasi, wit-bindgen, wasm-tools, wasi-preview1-adapter (default: the env that
#                    holds `qt2wasm` on PATH)
#   WEBBY_CORE_WASM  the engine component (default: webby-core.wasm from the forge's wasm-engine release, downloaded
#                    into BUILD_DIR once; WEBBY_CORE_REFRESH=1 downloads it again)
#   WAC              wac (default: on PATH, else wac-cli 0.8.1 downloaded into BUILD_DIR)
# Output: BUILD_DIR/webby.wasm. Run: latha-gui BUILD_DIR/webby.wasm [URL...]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
build=${1:-$here/build}; mkdir -p "$build"; build=$(cd "$build" && pwd)
if [ -z "${WEBBY_QT_ENV:-}" ]; then
  q=$(command -v qt2wasm || true)
  [ -n "$q" ] || { echo "set WEBBY_QT_ENV (or put qt2wasm's env on PATH)" >&2; exit 1; }
  WEBBY_QT_ENV=$(cd "$(dirname "$q")/.." && pwd)
fi
release=https://fileapi.fastapicloud.dev/api/forge/repos/nandi.uk/webby/releases/wasm-engine/assets
core=${WEBBY_CORE_WASM:-$build/webby-core.wasm}
if [ -z "${WEBBY_CORE_WASM:-}" ] && { [ ! -s "$core" ] || [ "${WEBBY_CORE_REFRESH:-0}" = 1 ]; }; then
  echo "downloading webby-core.wasm from the wasm-engine release"
  curl -fL --progress-bar -o "$core.part" "$release/webby-core.wasm" && mv "$core.part" "$core"
fi
wac=${WAC:-$(command -v wac || true)}
if [ -z "$wac" ]; then
  wac=$build/wac
  [ -x "$wac" ] || { curl -fsSL -o "$wac" https://github.com/bytecodealliance/wac/releases/download/v0.8.1/wac-cli-x86_64-unknown-linux-musl && chmod +x "$wac"; }
fi
if [ ! -f "$build/cmake/build.ninja" ]; then
  cmake -S "$here" -B "$build/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$WEBBY_QT_ENV/opt/qt6-wasi/cmake/wasi-qt.cmake" \
    -DCMAKE_C_FLAGS_RELEASE="-O2 -ffunction-sections -fdata-sections -DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="-O2 -ffunction-sections -fdata-sections -DNDEBUG" \
    -DWEBBY_QT_ENV="$WEBBY_QT_ENV" > /dev/null
fi
cmake --build "$build/cmake"
"$wac" plug "$build/cmake/webby-ui-shell.wasm" --plug "$core" -o "$build/webby.wasm"
echo "built $build/webby.wasm ($(du -h "$build/webby.wasm" | cut -f1); UI component $(du -h "$build/cmake/webby-ui-shell.wasm" | cut -f1))"
