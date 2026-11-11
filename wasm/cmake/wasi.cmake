# Toolchain for webby's wasm build: wasi-sdk's wasm32-wasip1 toolchain plus the emulation libraries Ladybird and its
# dependencies lean on (signals, process clocks, mmap, getpid; wasi-libc stubs pthreads for the single-threaded module).
# WEBBY_WASI_SYSROOT is where the dependencies are installed (find_package looks there first).
include("$ENV{WASI_SDK_PREFIX}/share/cmake/wasi-sdk-p1.cmake")
set(_emu "-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID")
set(_libs "-lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-mman -lwasi-emulated-getpid")
# compat/ (installed into the sysroot by compat/build.sh): netdb.h, sockets and the POSIX pieces wasi-libc lacks,
# included before every source and linked into every program.
if(DEFINED ENV{WEBBY_WASI_SYSROOT} AND EXISTS "$ENV{WEBBY_WASI_SYSROOT}/include/webby_wasi_compat.h")
    string(APPEND _emu " -isystem $ENV{WEBBY_WASI_SYSROOT}/include -include $ENV{WEBBY_WASI_SYSROOT}/include/webby_wasi_compat.h")
    string(APPEND _libs " -L$ENV{WEBBY_WASI_SYSROOT}/lib -lwebby_wasi_compat")
    # Sockets (compat/webby_wasi_net.c, over wasi:sockets) are descriptors too: libc's descriptor calls go through
    # compat/webby_wasi_net_wrap.c first. Same list as WEBBY_NET_WRAPPED and compat/build.sh.
    foreach(_f close read write readv writev send recv shutdown poll fcntl ioctl getsockopt)
        string(APPEND _libs " -Wl,--wrap=${_f}")
    endforeach()
endif()
# setjmp/longjmp (libpng's and libjpeg's error handling) use the exception-handling proposal with exnref, which
# wasmtime runs with wasm_exceptions on (tools/wasi-run.py); libsetjmp is wasi-libc's runtime for it.
string(APPEND _emu " -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false")
string(APPEND _libs " -lsetjmp")
set(CMAKE_C_FLAGS_INIT "${_emu}")
# wasi-sdk's libc++ has no exception runtime (no __cxa_throw), so C++ dependencies build without exceptions, as
# Ladybird does.
set(CMAKE_CXX_FLAGS_INIT "${_emu} -fno-exceptions")
# LibGC and PrimitiveStorage treat the low 2 GiB of linear memory as their region (patches/0002), so memory never
# grows past it. The main thread's shadow stack, which the conservative GC scans, gets 8 MiB like a native one.
string(APPEND _libs " -Wl,--max-memory=2147483648 -Wl,-z,stack-size=8388608")
# crt1's _start reaches main through a weak reference to __main_argc_argv, which does not pull LibMain's Main.cpp out of
# its static archive: without this, wasm-ld turns the call to main into `unreachable`.
string(APPEND _libs " -Wl,--undefined=__main_argc_argv")
# clang runs binaryen's wasm-opt after linking whenever one is on PATH (pixi has one), which drops the name section.
# The build runs wasm-opt itself where it wants it.
string(APPEND _libs " --no-wasm-opt")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${_libs}")
# After linking, every program goes through binaryen (deps/binaryen.sh builds the patched webby-wasm-opt):
#  --spill-pointers: LibGC's conservative scan cannot see wasm locals, so live i32 and i64 (NaN-boxed JS value) locals
#    are stored to the shadow stack before each call.
#  --stack-check: the shadow stack sits right above the static data, so an overflow traps instead of overwriting it.
# Names are kept for backtraces.
if(DEFINED ENV{WEBBY_WASI_SYSROOT} AND EXISTS "$ENV{WEBBY_WASI_SYSROOT}/bin/webby-wasm-opt")
    set(_spill "$ENV{WEBBY_WASI_SYSROOT}/bin/webby-wasm-opt -g --all-features --spill-pointers --stack-check --pass-arg=stack-check-size@8388608 <TARGET> -o <TARGET>")
    foreach(_lang C CXX)
        set(CMAKE_${_lang}_LINK_EXECUTABLE
            "<CMAKE_${_lang}_COMPILER> <FLAGS> <CMAKE_${_lang}_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> <LINK_LIBRARIES> && ${_spill}")
    endforeach()
endif()
if(DEFINED ENV{WEBBY_WASI_SYSROOT})
    list(PREPEND CMAKE_FIND_ROOT_PATH "$ENV{WEBBY_WASI_SYSROOT}")
    list(PREPEND CMAKE_PREFIX_PATH "$ENV{WEBBY_WASI_SYSROOT}")
endif()
# pkg-config reads only the sysroot's .pc files, never the host's.
if(DEFINED ENV{WEBBY_WASI_SYSROOT})
    set(ENV{PKG_CONFIG_LIBDIR} "$ENV{WEBBY_WASI_SYSROOT}/lib/pkgconfig")
    set(ENV{PKG_CONFIG_PATH} "")
endif()
