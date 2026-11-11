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
    engine = wasmtime.Engine(config)
    store = wasmtime.Store(engine)
    wasi = wasmtime.WasiConfig()
    wasi.argv = [os.path.basename(path)] + sys.argv[2:]
    wasi.inherit_stdin()
    wasi.inherit_stdout()
    wasi.inherit_stderr()
    wasi.inherit_env()
    wasi.preopen_dir(".", ".")
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


if __name__ == "__main__":
    sys.exit(main())
