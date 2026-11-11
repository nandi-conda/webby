#!/usr/bin/env bash
# SQLite for wasm32-wasip1: the amalgamation is generated on the host from the git tree (needs tclsh/jimsh, which
# configure builds), then compiled single-threaded without WAL, mmap or extension loading.
# usage: sqlite.sh SQLITE_SRC WORK PREFIX
set -euo pipefail
src=$1; work=$2; prefix=$3; sdk=${WASI_SDK_PREFIX:?}
mkdir -p "$work" "$prefix/lib/pkgconfig" "$prefix/include"; cd "$work"
[ -f Makefile ] || "$src/configure" --disable-tcl > configure.log 2>&1
make sqlite3.c > make.log 2>&1
"$sdk/bin/clang" --target=wasm32-wasip1 -O2 -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
  -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID -isystem "$prefix/include" -include "$prefix/include/webby_wasi_compat.h" \
  -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_DEFAULT_LOCKING_MODE=1 -DSQLITE_ENABLE_FTS5 -DSQLITE_MAX_MMAP_SIZE=0 -c sqlite3.c -o sqlite3.o
rm -f "$prefix/lib/libsqlite3.a"; "$sdk/bin/llvm-ar" rcs "$prefix/lib/libsqlite3.a" sqlite3.o
cp sqlite3.h sqlite3ext.h "$prefix/include/"
version=$(sed -n 's/^#define SQLITE_VERSION *"\(.*\)"/\1/p' sqlite3.h)
cat > "$prefix/lib/pkgconfig/sqlite3.pc" <<PC
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: SQLite
Description: SQL database engine (WASI build, single-threaded)
Version: $version
Libs: -L\${libdir} -lsqlite3
Cflags: -I\${includedir}
PC
echo "SQLite $version for WASI in $prefix"
