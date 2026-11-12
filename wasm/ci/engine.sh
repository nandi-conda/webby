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
  # The patched tree is made beside the build's one, then only files whose contents differ are copied over
  # (rsync -c): unchanged files keep their times, so ninja and cargo rebuild only what a patch touched. (A
  # checkout -f and clean of the tree itself gave every file a new time, and a patch change meant a cold build.)
  staged=$C/ladybird-staged; rm -rf "$staged"; mkdir -p "$staged"
  git -C "$lb" archive "$commit" | tar -x -C "$staged" || fail "exporting Ladybird $commit failed"
  for p in "$w"/patches/*.patch "$w"/wasm/patches/*.patch; do
    (cd "$staged" && git apply "$p") || fail "patch $(basename "$p") does not apply"
  done
  rsync -rlc --delete --exclude=/.git --exclude=/Build/caches "$staged/" "$lb/" || fail "updating the source tree failed"
  rm -rf "$staged"
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
# A different toolchain file starts the build directory over; build-engine.sh configures again every run, so its
# options apply without one. ccache (in the cache mount) makes a fresh build directory cheap anyway.
build=$C/build
conf=$(cat "$w/wasm/cmake/wasi.cmake" | sha256sum | cut -d' ' -f1)
if [ "$(cat "$build/.webby-conf" 2>/dev/null)" != "$conf" ]; then rm -rf "$build"; mkdir -p "$build"; echo "$conf" > "$build/.webby-conf"; fi
export CCACHE_DIR=$C/ccache CCACHE_MAXSIZE=10G CCACHE_COMPILERCHECK=content \
  CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime
ccache -z > /dev/null 2>&1 || true

# The Qt UI (wasm/ui) builds against qt2wasm's Qt for WASI, wit-bindgen, wasm-tools and the preview1 reactor adapter:
# a micromamba env, cached; ui/CMakeLists.txt finds it through WEBBY_QT_ENV.
if [[ " $targets " == *" webby-ui "* ]]; then
  export ENABLE_GUI_TARGETS=ON
  qtenv=$C/qt2wasm-env-0.10.2
  if [ ! -d "$qtenv/opt/qt6-wasi/wasi/lib" ]; then
    rm -rf "$qtenv"
    (cd /tmp && curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj bin/micromamba) \
      && /tmp/bin/micromamba create -y -q -r /tmp/mamba -p "$qtenv" -c conda-forge -c https://prefix.dev/nandi-testing \
         'qt2wasm=0.10.2' qt6-wasi wit-bindgen wasm-tools wasi-preview1-adapter > /dev/null \
      || fail "installing qt2wasm (Qt for WASI) failed"
  fi
  export WEBBY_QT_ENV=$qtenv
fi

export LIBJS_TARGET_RUNNER="python $w/wasm/tools/wasi-run.py"
echo "building $targets (budget ${budget}s)"
# shellcheck disable=SC2086
timeout "$budget" "$w/wasm/build-engine.sh" "$lb" "$build" $targets > "$out/build.full.log" 2>&1
rc=$?
grep -E "^\[[0-9]+/[0-9]+\]" "$out/build.full.log" | tail -1 > "$out/progress" || true
ccache -s >> "$out/build.full.log" 2>&1 || true
tail -150 "$out/build.full.log" > "$out/build.log"; rm -f "$out/build.full.log"
if [ $rc = 124 ]; then status partial; exit 0; fi
[ $rc = 0 ] || fail "build-engine.sh failed (exit $rc)"

for t in $targets; do
  if [ "$t" = webby-ui ]; then
    # The UI is a latha:gui component, bin/webby.wasm (bin/webby-ui.core.wasm is its core module).
    [ -f "$build/bin/webby.wasm" ] || fail "no $build/bin/webby.wasm after the build"
    cp "$build/bin/webby.wasm" "$out/webby.wasm"
    continue
  fi
  [ -f "$build/bin/$t" ] || fail "no $build/bin/$t after the build"
  cp "$build/bin/$t" "$out/$t.wasm"
done
if [[ " $targets " == *" js "* ]]; then
  got=$(cd /tmp && timeout 300 python "$w/wasm/tools/wasi-run.py" "$out/js.wasm" -c 'print(6 * 7)' 2>&1 | tail -1 | sed 's/\x1b\[[0-9;]*m//g')
  [ "$got" = 42 ] || fail "js.wasm smoke test printed: $got"
  echo "js.wasm prints $got"
fi
# Programs that use sockets (webby-render links RequestServer) run as components: wasm-tools makes them, the wasmtime
# CLI runs them with TCP (tools/wasi-run.py), latha-run runs latha:proc children. nandi-testing's packages, cached.
if [[ " $targets " == *" webby-render "* ]]; then
  # latha:proc shared memory and spawn-with-env (wasm/compat) need latha-gui 0.4; a new version gets a new directory.
  tools=$C/tools-env-latha-0.4
  if [ ! -x "$tools/bin/latha-run" ]; then
    (cd /tmp && curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj bin/micromamba) \
      && /tmp/bin/micromamba create -y -q -r /tmp/mamba -p "$tools" -c https://prefix.dev/nandi-testing -c conda-forge \
         wasmtime wasm-tools 'latha-gui>=0.4' > /dev/null || fail "installing wasmtime, wasm-tools and latha-run failed"
  fi
  adapter=$C/wasi_snapshot_preview1.command.wasm
  [ -s "$adapter" ] || curl -fsSL -o "$adapter" \
    https://github.com/bytecodealliance/wasmtime/releases/download/v36.0.0/wasi_snapshot_preview1.command.wasm \
    || fail "downloading the preview1 command adapter failed"
  # The conda wasmtime (36) cannot compile wasm exceptions, which setjmp/longjmp are on WASI; 40 can.
  wasmtime_cli=$C/wasmtime-v40.0.0-x86_64-linux/wasmtime
  [ -x "$wasmtime_cli" ] || curl -fsSL \
    https://github.com/bytecodealliance/wasmtime/releases/download/v40.0.0/wasmtime-v40.0.0-x86_64-linux.tar.xz \
    | tar -xJ -C "$C" || fail "downloading wasmtime 40 failed"
  export WASMTIME=$wasmtime_cli WASM_TOOLS=$tools/bin/wasm-tools LATHA_RUN=$tools/bin/latha-run WEBBY_WASI_ADAPTER=$adapter
fi
if [[ " $targets " == *" webby-render "* ]]; then
  # tests/webby-render-test.html (gradients, transforms, text, a script) to a PNG, as the wasm-port thread runs it.
  page=$(mktemp -d); cp "$w/wasm/tests/webby-render-test.html" "$page/index.html"
  (cd "$lb" && XDG_DATA_DIRS=/usr/share WASI_RUN_DIRS="/usr/share/fonts,$lb/Base/res=/res,$page" timeout 600 \
    python "$w/wasm/tools/wasi-run.py" "$out/webby-render.wasm" --theme /res/themes/Default.ini \
    -o "$page/out.png" "$page/index.html") > "$out/webby-render-test.log" 2>&1
  rc=$?
  if [ $rc != 0 ] || [ "$(head -c 8 "$page/out.png" 2>/dev/null | od -An -tx1 | tr -d ' ')" != 89504e470d0a1a0a ] \
     || [ "$(stat -c %s "$page/out.png")" -lt 10000 ]; then
    tail -40 "$out/webby-render-test.log"; fail "webby-render smoke test failed (exit $rc)"
  fi
  cp "$page/out.png" "$out/webby-render-test.png"
  echo "webby-render drew a $(stat -c %s "$out/webby-render-test.png")-byte PNG"
  # tests/webby-render-wasm.html runs a WebAssembly module in the page (LibWasm's C interpreter, patches/0013) and
  # paints itself green only if every result is right.
  cp "$w/wasm/tests/webby-render-wasm.html" "$page/wasm.html"
  (cd "$lb" && XDG_DATA_DIRS=/usr/share WASI_RUN_DIRS="/usr/share/fonts,$lb/Base/res=/res,$page" timeout 600 \
    python "$w/wasm/tools/wasi-run.py" "$out/webby-render.wasm" --theme /res/themes/Default.ini \
    -o "$page/wasm.png" "$page/wasm.html") > "$out/webby-render-wasm.log" 2>&1
  rc=$?
  [ -f "$page/wasm.png" ] && cp "$page/wasm.png" "$out/webby-render-wasm.png"
  colour=$(python3 "$w/wasm/tests/png-pixel.py" "$page/wasm.png" 50 50 2>/dev/null || true)
  if [ $rc != 0 ] || [ "$colour" != 00c000 ]; then
    tail -40 "$out/webby-render-wasm.log"; fail "webby-render WebAssembly test failed (exit $rc, pixel ${colour:-none})"
  fi
  echo "webby-render ran a page's WebAssembly"
fi
if [[ " $targets " == *" webby-render-latha "* ]]; then
  # A page over HTTP through RequestServer (in the module, then RequestServer.wasm in a latha:proc child) and
  # https://example.com/ both ways (tests/webby-render-net.sh).
  net=$(mktemp -d)
  HTTPS=1 timeout 1200 bash "$w/wasm/tests/webby-render-net.sh" "$build" "$lb" "$net" > "$out/webby-render-net.log" 2>&1
  rc=$?
  for f in one.png two.png https-one.png https-two.png; do [ -f "$net/$f" ] && cp "$net/$f" "$out/webby-render-net-$f"; done
  if [ $rc != 0 ]; then tail -60 "$out/webby-render-net.log" >> "$out/build.log"; fail "webby-render network test failed (exit $rc)"; fi
  echo "webby-render loaded pages over the network"
fi
if [[ " $targets " == *" webby-headless "* ]] && [ -n "${LATHA_RUN:-}" ]; then
  # webby-headless with WebContent, Compositor, RequestServer and ImageDecoder as child instances: screenshots of a
  # file: page, the same page over HTTP, and https://example.com/ (tests/multiprocess.sh).
  mp=$(mktemp -d)
  HTTPS=1 timeout 1800 bash "$w/wasm/tests/multiprocess.sh" "$build" "$lb" "$mp" > "$out/multiprocess.log" 2>&1
  rc=$?
  for f in file.png http.png https.png; do [ -f "$mp/$f" ] && cp "$mp/$f" "$out/multiprocess-$f"; done
  if [ $rc != 0 ]; then tail -60 "$out/multiprocess.log" >> "$out/build.log"; fail "multi-process test failed (exit $rc)"; fi
  echo "webby-headless ran its helpers as separate instances"
fi
if [[ " $targets " == *" webby-ui "* ]] && [ -n "${LATHA_RUN:-}" ]; then
  # The UI in latha-gui, headless: open a page with a script, screenshot it. Needs the tools env above.
  ui=$(mktemp -d)
  printf '<!doctype html><title>One</title><h1 style="color:#b03060">webby UI test</h1><p id=p>no script</p><p><a href="two.html">next</a></p><script>p.textContent = "script " + (6 * 7)</script>' > "$ui/one.html"
  printf '<!doctype html><title>Two</title><h1>page two</h1>' > "$ui/two.html"
  (cd "$ui" && QT_QPA_PLATFORM=offscreen timeout 1200 "$(dirname "$LATHA_RUN")/latha-gui" --dir "$lb/Base/res::/res" \
    --size 1100x760 --screenshot "$ui/ui.png" --quit-after 20000 "$out/webby.wasm" "$ui/one.html") > "$out/webby-ui-test.log" 2>&1
  rc=$?
  [ -f "$ui/ui.png" ] && cp "$ui/ui.png" "$out/webby-ui-test.png"
  if [ $rc != 0 ] || [ "$(stat -c %s "$ui/ui.png" 2>/dev/null || echo 0)" -lt 10000 ]; then
    tail -40 "$out/webby-ui-test.log"; fail "webby-ui smoke test failed (exit $rc)"
  fi
  # And as `latha-gui webby.wasm` with nothing opened to it (built-in theme and fonts), past several idle GCs.
  (cd "$ui" && QT_QPA_PLATFORM=offscreen timeout 1200 "$(dirname "$LATHA_RUN")/latha-gui" --no-root \
    --size 1100x760 --screenshot "$ui/bare.png" --quit-after 20000 "$out/webby.wasm") > "$out/webby-ui-bare.log" 2>&1
  rc=$?
  if [ $rc != 0 ] || grep -q "trapped\|could not start" "$out/webby-ui-bare.log" || [ "$(stat -c %s "$ui/bare.png" 2>/dev/null || echo 0)" -lt 10000 ]; then
    tail -40 "$out/webby-ui-bare.log"; fail "webby-ui with no arguments failed (exit $rc)"
  fi
  echo "webby.wasm ran in latha-gui"
fi
(cd "$out" && sha256sum ./*.wasm > SHA256SUMS)
status ok
