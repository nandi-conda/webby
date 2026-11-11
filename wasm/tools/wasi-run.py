#!/usr/bin/env python3
"""Runs a wasm32-wasip1 command module: wasi-run.py MODULE [ARGS...].

Stands in for `wasmtime run` where no wasmtime CLI is installed (it is not on conda-forge). Uses the wasmtime
package from PyPI. stdio and the current directory are passed through; the exit code is the module's.
"""
import os
import sys

import wasmtime


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: wasi-run.py MODULE [ARGS...]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    config = wasmtime.Config()
    # setjmp/longjmp (libpng, FreeType in deps/skia.sh) are wasm exception handling on WASI.
    config.wasm_exceptions = True
    # A native engine checks recursion against its C stack; in wasm that is the shadow stack in linear memory (8 MiB,
    # cmake/wasi.cmake), while each frame also uses the engine's own stack. Give the engine's stack enough room that
    # the shadow stack check trips first, as it would natively.
    # NB: wasmtime refuses a max_wasm_stack above async_stack_size, which the Python API only sets through the C API.
    from wasmtime import _bindings

    _bindings.wasmtime_config_async_stack_size_set(config.ptr(), WASM_STACK)
    config.max_wasm_stack = WASM_STACK
    engine = wasmtime.Engine(config)
    store = wasmtime.Store(engine)
    wasi = wasmtime.WasiConfig()
    wasi.argv = [os.path.basename(path)] + sys.argv[2:]
    wasi.inherit_stdin()
    wasi.inherit_stdout()
    wasi.inherit_stderr()
    wasi.inherit_env()
    wasi.preopen_dir(".", ".")
    # WASI_RUN_DIRS="host[=guest],...": more host directories for the module, e.g. /usr/share/fonts for webby-render.
    for entry in filter(None, os.environ.get("WASI_RUN_DIRS", "").split(",")):
        host, _, guest = entry.partition("=")
        wasi.preopen_dir(host, guest or host)
    store.set_wasi(wasi)
    linker = wasmtime.Linker(engine)
    linker.define_wasi()
    module = wasmtime.Module.from_file(engine, path)
    instance = linker.instantiate(store, module)
    try:
        instance.exports(store)["_start"](store)
    except wasmtime.ExitTrap as exit_trap:
        return exit_trap.code
    return 0


WASM_STACK = 256 << 20

if __name__ == "__main__":
    # wasmtime runs the module on the calling thread's stack, so that thread needs more than max_wasm_stack.
    import threading

    threading.stack_size(WASM_STACK + (64 << 20))
    result = []
    thread = threading.Thread(target=lambda: result.append(main()))
    thread.start()
    thread.join()
    sys.exit(result[0] if result else 1)
