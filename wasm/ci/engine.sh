#!/usr/bin/env bash
# Inside ci/engine.Dockerfile: Ladybird at ../LADYBIRD_COMMIT with ../patches/* and wasm/patches/* applied, built for
# wasm32-wasip1 by build-engine.sh against the sysroot in /opt/webby-wasi. /cache is a Depot cache mount (the
# checkout, the build directory), so each run continues where the last one stopped.
#
# The build gets BUDGET seconds. When it runs out, the step still succeeds (so the cache keeps what was compiled)
# and /export/status says "partial": ci/forge_wasm.py then starts the job again. Every outcome is written to
# /export (status, build.log tail, the programs as <target>.wasm), never a failed step, so the job can report it.
# env: TARGETS (space separated, default js), BUDGET (seconds)
set -uo pipefail
w=/w; C=/cache; out=/export; mkdir -p "$out" "$C"
targets=${TARGETS:-js}; budget=${BUDGET:-2700}
status() { echo "$1" > "$out/status"; echo "status: $1"; }
fail() { echo "$*" | tee -a "$out/build.log"; status failed; exit 0; }

lb=$C/ladybird; commit=$(cat "$w/LADYBIRD_COMMIT")
stamp=$( (echo "$commit"; cat "$w"/patches/*.patch "$w"/wasm/patches/*.patch) | sha256sum | cut -d' ' -f1)
if [ "$(cat "$lb/.git/webby-wasm-patches" 2>/dev/null)" != "$stamp" ]; then
  echo "checking out $commit with $(ls "$w"/patches/*.patch "$w"/wasm/patches/*.patch | wc -l) patches"
  [ -d "$lb/.git" ] || { git init -q "$lb" && git -C "$lb" remote add origin https://github.com/LadybirdBrowser/ladybird; }
  git -C "$lb" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$lb" fetch -q --depth 1 origin "$commit" \
    || fail "fetching Ladybird $commit failed"
  git -C "$lb" checkout -q -f "$commit" && git -C "$lb" clean -qfdx -e Build/caches || fail "checkout failed"
  for p in "$w"/patches/*.patch "$w"/wasm/patches/*.patch; do
    git -C "$lb" apply "$p" || fail "patch $(basename "$p") does not apply"
  done
  echo "$stamp" > "$lb/.git/webby-wasm-patches"
fi

want=$(sed -n 's/^channel = "\(.*\)"/\1/p' "$lb/rust-toolchain.toml")
rustup toolchain list | grep -q "^$want" || fail "Ladybird wants Rust $want; ci/base.sh installs $(rustc --version)"
export RUSTUP_TOOLCHAIN=$want

# ENABLE_NETWORK_DOWNLOADS is off (build-engine.sh), so the HSTS preload list has to be there already.
hsts=$lb/Build/caches/HSTSPreload/transport_security_state_static.json
if [ ! -s "$hsts" ]; then
  mkdir -p "$(dirname "$hsts")"
  curl -fsSL -o "$hsts" https://raw.githubusercontent.com/chromium/chromium/main/net/http/transport_security_state_static.json \
    || fail "downloading the HSTS preload list failed"
fi

# LibWeb and webby-render only exist with the GUI targets on (patches/0006).
if [[ " $targets " == *" webby-render "* ]]; then export ENABLE_GUI_TARGETS=ON; fi
# A different configuration (build-engine.sh's options, the toolchain file) starts the build directory over.
build=$C/build
conf=$( (cat "$w/wasm/build-engine.sh" "$w/wasm/cmake/wasi.cmake"; echo "gui=${ENABLE_GUI_TARGETS:-}") | sha256sum | cut -d' ' -f1)
if [ "$(cat "$build/.webby-conf" 2>/dev/null)" != "$conf" ]; then rm -rf "$build"; mkdir -p "$build"; echo "$conf" > "$build/.webby-conf"; fi

export LIBJS_TARGET_RUNNER="python $w/wasm/tools/wasi-run.py"
echo "building $targets (budget ${budget}s)"
# shellcheck disable=SC2086
timeout "$budget" "$w/wasm/build-engine.sh" "$lb" "$build" $targets > "$out/build.full.log" 2>&1
rc=$?
grep -E "^\[[0-9]+/[0-9]+\]" "$out/build.full.log" | tail -1 > "$out/progress" || true
tail -150 "$out/build.full.log" > "$out/build.log"; rm -f "$out/build.full.log"
if [ $rc = 124 ]; then status partial; exit 0; fi
[ $rc = 0 ] || fail "build-engine.sh failed (exit $rc)"

for t in $targets; do
  [ -f "$build/bin/$t" ] || fail "no $build/bin/$t after the build"
  cp "$build/bin/$t" "$out/$t.wasm"
done
if [[ " $targets " == *" js "* ]]; then
  got=$(cd /tmp && timeout 300 python "$w/wasm/tools/wasi-run.py" "$out/js.wasm" -c 'print(6 * 7)' 2>&1 | tail -1)
  [ "$got" = 42 ] || fail "js.wasm smoke test printed: $got"
  echo "js.wasm prints $got"
fi
(cd "$out" && sha256sum ./*.wasm > SHA256SUMS)
status ok
