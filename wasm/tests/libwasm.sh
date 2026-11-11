#!/usr/bin/env bash
# LibWasm on wasm32 (patches/0013): runs LibWasm's Engine tests and the WebAssembly spec test suite with the C
# interpreter in a wasm32-wasip1 module under wasmtime, and the suite natively with the assembly and the C
# interpreters too. The three must agree; the spec suite totals are printed for each.
#   tests/libwasm.sh LADYBIRD_SRC OUT_DIR [TESTSUITE_DIR]
# LADYBIRD_SRC is a checkout with webby's patches and patches/0001-0013. TESTSUITE_DIR defaults to a clone of
# github.com/WebAssembly/testsuite in OUT_DIR.
# env: WASI_SDK_PREFIX (wasi-sdk 27), WASMTIME (36 or later), RUSTUP_TOOLCHAIN (Ladybird's, with wasm32-wasip1)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$1" && pwd); mkdir -p "$2"; out=$(cd "$2" && pwd)
suite=${3:-$out/testsuite}
[ -d "$suite" ] || git clone -q --depth 1 https://github.com/WebAssembly/testsuite.git "$suite"
wasmtime=${WASMTIME:-wasmtime}
export RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-$(sed -n 's/^channel = "\(.*\)"/\1/p' "$src/rust-toolchain.toml")}
export CC_wasm32_wasip1=$WASI_SDK_PREFIX/bin/clang AR_wasm32_wasip1=$WASI_SDK_PREFIX/bin/llvm-ar
export LIBJS_TARGET_RUNNER=$wasmtime LIBWASM_JIT=off
# NB: The interpreter's frames live in the shadow stack (64 MiB here), its handlers chain with return_call.
run_wasm="$wasmtime -W tail-call=y,max-wasm-stack=67108864"
"$CC_wasm32_wasip1" --target=wasm32-wasip1 -O2 -c "$here/../tools/libwasm-wast/ladybird-rust-hooks.c" -o "$out/hooks.o"
wasm_rustflags="-C link-arg=-zstack-size=67108864 -C link-arg=$out/hooks.o"

echo "== Engine tests in wasm"
(cd "$src/Libraries/LibWasm/Engine" &&
  CARGO_TARGET_DIR=$out/engine-wasm32 RUSTFLAGS=$wasm_rustflags \
  CARGO_TARGET_WASM32_WASIP1_RUNNER="$run_wasm --dir=$src" \
  cargo test --release --target wasm32-wasip1 --test execution --test fixtures --test side_table --test validation)

runner=$here/../tools/libwasm-wast
ln -sfn "$src" "$runner/ladybird"
(cd "$runner" && CARGO_TARGET_DIR=$out/wast-asm cargo build -q --release)
(cd "$runner" && CARGO_TARGET_DIR=$out/wast-c LIBWASM_INTERPRETER_BACKEND=c cargo build -q --release)
(cd "$runner" && CARGO_TARGET_DIR=$out/wast-wasm32 RUSTFLAGS=$wasm_rustflags cargo build -q --release --target wasm32-wasip1)

spec() { # name command...
  local name=$1; shift
  ls "$suite"/*.wast | xargs -P"$(nproc)" -I{} sh -c 'timeout 300 "$@" {} 2>&1 | tail -1' sh "$@" | sort > "$out/spec-$name.txt"
  awk -v name="$name" '/passed/ {p += $(NF-5); f += $(NF-3)} !/passed/ {c++} END {printf "%s: %d passed, %d failed, %d scripts did not run\n", name, p, f, c}' "$out/spec-$name.txt"
}
echo "== spec test suite"
spec asm "$out/wast-asm/release/libwasm-wast"
spec c "$out/wast-c/release/libwasm-wast"
spec wasm32 $run_wasm --dir="$suite" "$out/wast-wasm32/wasm32-wasip1/release/libwasm-wast.wasm"
diff "$out/spec-asm.txt" "$out/spec-c.txt"
diff "$out/spec-asm.txt" "$out/spec-wasm32.txt"
echo "libwasm: ok"
