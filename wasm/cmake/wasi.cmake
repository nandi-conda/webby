# Toolchain for webby's wasm build: wasi-sdk's wasm32-wasip1 toolchain plus the emulation libraries Ladybird and its
# dependencies lean on (signals, process clocks, mmap, getpid; wasi-libc stubs pthreads for the single-threaded module).
# WEBBY_WASI_SYSROOT is where the dependencies are installed (find_package looks there first).
include("$ENV{WASI_SDK_PREFIX}/share/cmake/wasi-sdk-p1.cmake")
set(_emu "-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID")
set(_libs "-lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-mman -lwasi-emulated-getpid")
# compat/ (installed into the sysroot by compat/build.sh): netdb.h and the POSIX pieces wasi-libc lacks, included
# before every source and linked into every program.
if(DEFINED ENV{WEBBY_WASI_SYSROOT} AND EXISTS "$ENV{WEBBY_WASI_SYSROOT}/include/webby_wasi_compat.h")
    string(APPEND _emu " -isystem $ENV{WEBBY_WASI_SYSROOT}/include -include $ENV{WEBBY_WASI_SYSROOT}/include/webby_wasi_compat.h")
    string(APPEND _libs " -L$ENV{WEBBY_WASI_SYSROOT}/lib -lwebby_wasi_compat")
endif()
set(CMAKE_C_FLAGS_INIT "${_emu}")
set(CMAKE_CXX_FLAGS_INIT "${_emu}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${_libs}")
if(DEFINED ENV{WEBBY_WASI_SYSROOT})
    list(PREPEND CMAKE_FIND_ROOT_PATH "$ENV{WEBBY_WASI_SYSROOT}")
    list(PREPEND CMAKE_PREFIX_PATH "$ENV{WEBBY_WASI_SYSROOT}")
endif()
# pkg-config reads only the sysroot's .pc files, never the host's.
if(DEFINED ENV{WEBBY_WASI_SYSROOT})
    set(ENV{PKG_CONFIG_LIBDIR} "$ENV{WEBBY_WASI_SYSROOT}/lib/pkgconfig")
    set(ENV{PKG_CONFIG_PATH} "")
endif()
