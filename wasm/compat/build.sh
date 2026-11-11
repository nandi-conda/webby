#!/usr/bin/env bash
# Builds libwebby_wasi_compat.a and installs it with webby_wasi_compat.h, webby_wasi_net.h and include/ (netdb.h,
# pwd.h, grp.h, spawn.h, sys/wait.h, termios.h) into WEBBY_WASI_SYSROOT.
# The archive also carries wasi-sdk's WASI 0.2 bindings (wasip2.o, wasip2_component_type.o from its wasip2 libc),
# which the sockets in webby_wasi_net.c call.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); sdk=${WASI_SDK_PREFIX:?}; prefix=${WEBBY_WASI_SYSROOT:?}
sysroot=$sdk/share/wasi-sysroot
mkdir -p "$prefix/include" "$prefix/lib"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cc() { "$sdk/bin/clang" --target=wasm32-wasip1 -O2 -Wall -Wextra -I"$here/include" -I"$here" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_GETPID "$@"; }
cc -c "$here/webby_wasi_compat.c" -o "$tmp/webby_wasi_compat.o"
cc -c "$here/webby_wasi_net_wrap.c" -o "$tmp/webby_wasi_net_wrap.o"
# wasi/wasip2.h only: -idirafter keeps every other header the wasip1 one.
cc -idirafter "$sysroot/include/wasm32-wasip2" -c "$here/webby_wasi_net.c" -o "$tmp/webby_wasi_net.o"
(cd "$tmp" && "$sdk/bin/llvm-ar" x "$sysroot/lib/wasm32-wasip2/libc.a" wasip2.o wasip2_component_type.o)
rm -f "$prefix/lib/libwebby_wasi_compat.a"
"$sdk/bin/llvm-ar" rcs "$prefix/lib/libwebby_wasi_compat.a" "$tmp"/*.o
cp "$here/webby_wasi_compat.h" "$here/webby_wasi_net.h" "$prefix/include/"
cp -r "$here/include/." "$prefix/include/"
# Linker flags for programs built without cmake/wasi.cmake (same list as there).
{ echo -n "-L$prefix/lib -lwebby_wasi_compat"; for f in close read write readv writev send recv shutdown poll fcntl ioctl getsockopt; do echo -n " -Wl,--wrap=$f"; done; echo; } > "$prefix/lib/webby_wasi_compat.ldflags"
echo "compat library in $prefix"
