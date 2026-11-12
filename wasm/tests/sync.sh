#!/usr/bin/env bash
# The wasm UI's sync (ui/SyncDoc.cpp, ui/SyncKeys.cpp) against the Nim front end's (nim/src/features/sync/doc.nim,
# keys.nim): the same canonical encodings, merges (both orders), sync code, blob ids, auth token and key, and each
# opens the other's encrypted blob. Fixtures in tests/sync/{a,b}.json.
#   tests/sync.sh OUT     env: WEBBY_QT_ENV (qt2wasm env), WEBBY_WASI_SYSROOT (libcrypto), nim and libcrypto.so.3
#                         on the host (LD_LIBRARY_PATH), wasmtime on PATH
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); out=$(mkdir -p "$1" && cd "$1" && pwd)
cp "$here"/sync/a.json "$here"/sync/b.json "$out"/
nim c -d:release --hints:off -o:"$out/gen" "$here/sync/gen.nim"
cmake -S "$here/sync" -B "$out/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$WEBBY_QT_ENV/opt/qt6-wasi/cmake/wasi-qt.cmake" -DWEBBY_QT_ENV="$WEBBY_QT_ENV" \
  -DWEBBY_WASI_SYSROOT="$WEBBY_WASI_SYSROOT" > /dev/null
cmake --build "$out/build"
cd "$out"
./gen > nim.json
wasmtime run --dir . build/synctest.wasm > cpp.json
./gen cpp-sealed.txt > nim2.json
python3 - <<'PY'
import json, sys
n = json.load(open('nim.json')); c = json.load(open('cpp.json')); n2 = json.load(open('nim2.json'))
bad = [k for k in n if k not in ('sealed',) and k in c and n[k] != c[k]]
if c['openedNim'] != n['mergeAB']: bad.append('C++ opens the Nim blob')
if n2['openedCpp'] != n['mergeAB']: bad.append('Nim opens the C++ blob')
print('sync interop:', 'FAIL ' + ', '.join(bad) if bad else 'all match')
sys.exit(1 if bad else 0)
PY
