#!/usr/bin/env python3
"""Runs a wasm32-wasip1 command module or a WASI 0.2 command component: wasi-run.py [--dir HOST[::GUEST]]... MODULE [ARGS...].

More directories: --dir, or WASI_RUN_DIRS="host[=guest],...".

Stands in for `wasmtime run` where no wasmtime CLI is installed (it is not on conda-forge). Uses the wasmtime
package from PyPI. stdio, the environment and the current directory are passed through; the exit code is the module's.

Networking: a module that opened a socket through compat/webby_wasi_net.c imports wasi:sockets (and wasi:io, wasi:clocks)
next to wasi_snapshot_preview1. Such a module is turned into a component on the fly with wasmtime's preview1 command
adapter (`wasm-tools component new --adapt`, cached in ~/.cache/webby-wasm) and run with WASI 0.2, network on: TCP,
UDP and name lookup through the host's own sockets. Plain wasip1 modules run as before, and so does a module with
wasi:sockets imports when there is no wasm-tools: those imports trap.

Components run in the wasmtime CLI when there is one (nandi-testing's `wasmtime` package, or WASMTIME): wasmtime-py
cannot turn on wasi:sockets TCP or UDP (its C API has inherit-network and name lookup but not allow_tcp/allow_udp,
which wasmtime-wasi leaves off by default). Without a CLI the component runs here with name lookup only.

  WASMTIME            wasmtime CLI (default: wasmtime on PATH)
  WASM_TOOLS          wasm-tools binary (default: wasm-tools on PATH)
  WEBBY_WASI_ADAPTER  wasi_snapshot_preview1.command.wasm (default: downloaded once from wasmtime's release)
  WEBBY_WASI_NETWORK  0 turns the network off
"""
import hashlib
import os
import shutil
import subprocess
import sys
import urllib.request

import wasmtime
from wasmtime import _bindings
from wasmtime import component

ADAPTER_VERSION = "36.0.0"  # the wasmtime and wasi-preview1-adapter packages on nandi-testing
ADAPTER_URL = f"https://github.com/bytecodealliance/wasmtime/releases/download/v{ADAPTER_VERSION}/wasi_snapshot_preview1.command.wasm"
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "webby-wasm")
WASM_STACK = 256 << 20


def make_engine() -> wasmtime.Engine:
    config = wasmtime.Config()
    # setjmp/longjmp (libpng, FreeType in deps/skia.sh) are wasm exception handling on WASI.
    config.wasm_exceptions = True
    # A native engine checks recursion against its C stack; in wasm that is the shadow stack in linear memory (8 MiB,
    # cmake/wasi.cmake), while each frame also uses the engine's own stack. Give the engine's stack enough room that
    # the shadow stack check trips first, as it would natively.
    # NB: wasmtime refuses a max_wasm_stack above async_stack_size, which the Python API only sets through the C API.
    _bindings.wasmtime_config_async_stack_size_set(config.ptr(), WASM_STACK)
    config.max_wasm_stack = WASM_STACK
    return wasmtime.Engine(config)


def is_component(path: str) -> bool:
    with open(path, "rb") as f:
        header = f.read(8)
    # Core modules are version 1 (layer 0); components are layer 1.
    return len(header) == 8 and header[:4] == b"\0asm" and header[6:8] == b"\x01\x00"


def adapter() -> str:
    path = os.environ.get("WEBBY_WASI_ADAPTER")
    if path:
        return path
    path = os.path.join(CACHE, f"wasi_snapshot_preview1.command-{ADAPTER_VERSION}.wasm")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        with urllib.request.urlopen(ADAPTER_URL) as response, open(path + ".part", "wb") as f:
            shutil.copyfileobj(response, f)
        os.replace(path + ".part", path)
    return path


def componentize(path: str) -> str:
    """The module as a command component (cached by content)."""
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()[:24]
    out = os.path.join(CACHE, f"{os.path.basename(path)}-{digest}.component.wasm")
    if not os.path.exists(out):
        os.makedirs(CACHE, exist_ok=True)
        tool = os.environ.get("WASM_TOOLS") or shutil.which("wasm-tools")
        subprocess.run([tool, "component", "new", path, "--adapt", f"wasi_snapshot_preview1={adapter()}", "-o", out + ".part"],
                       check=True)
        os.replace(out + ".part", out)
    return out


def wasi_config(argv0: str, args: list, dirs: list) -> wasmtime.WasiConfig:
    wasi = wasmtime.WasiConfig()
    wasi.argv = [argv0] + args
    wasi.inherit_stdin()
    wasi.inherit_stdout()
    wasi.inherit_stderr()
    wasi.inherit_env()
    wasi.preopen_dir(".", ".")
    for host, guest in dirs:
        wasi.preopen_dir(host, guest)
    if os.environ.get("WEBBY_WASI_NETWORK", "1") != "0":
        _bindings.wasi_config_inherit_network(wasi.ptr())
        _bindings.wasi_config_allow_ip_name_lookup(wasi.ptr(), True)
    return wasi


def run_module(engine, module, argv0, args, dirs, trap_unknown=False) -> int:
    store = wasmtime.Store(engine)
    store.set_wasi(wasi_config(argv0, args, dirs))
    linker = wasmtime.Linker(engine)
    linker.define_wasi()
    if trap_unknown:
        linker.define_unknown_imports_as_traps(module)
    instance = linker.instantiate(store, module)
    try:
        instance.exports(store)["_start"](store)
    except wasmtime.ExitTrap as exit_trap:
        return exit_trap.code
    return 0


def run_component_cli(cli, path, args, dirs) -> int:
    network = os.environ.get("WEBBY_WASI_NETWORK", "1") != "0"
    cmd = [cli, "run", "-W", f"exceptions=y,max-wasm-stack={WASM_STACK},async-stack-size={WASM_STACK + (1 << 20)}"]
    if network:
        cmd += ["-S", "inherit-network=y,allow-ip-name-lookup=y,tcp=y,udp=y"]
    cmd += ["--dir", "."]
    for host, guest in dirs:
        cmd += ["--dir", f"{host}::{guest}"]
    for name in os.environ:
        cmd += ["--env", name]
    return subprocess.run(cmd + [path] + args).returncode


def run_component(engine, path, argv0, args, dirs) -> int:
    cli = os.environ.get("WASMTIME") or shutil.which("wasmtime")
    if cli:
        return run_component_cli(cli, path, args, dirs)
    print("wasi-run.py: no wasmtime CLI, so no TCP or UDP (name lookup only)", file=sys.stderr)
    comp = component.Component.from_file(engine, path)
    run = next((name for name in comp.type.exports(engine) if name.startswith("wasi:cli/run@")), None)
    if not run:
        sys.exit(f"wasi-run.py: {path} exports no wasi:cli/run")
    store = wasmtime.Store(engine)
    store.set_wasi(wasi_config(argv0, args, dirs))
    linker = component.Linker(engine)
    linker.add_wasip2()
    instance = linker.instantiate(store, comp)
    func = instance.get_func(store, instance.get_export_index(store, "run", instance.get_export_index(store, run)))
    try:
        result = func(store)
    except wasmtime.ExitTrap as exit_trap:
        return exit_trap.code
    return 1 if getattr(result, "tag", "ok") == "err" else 0


def main() -> int:
    argv = sys.argv[1:]
    # WASI_RUN_DIRS="host[=guest],...": more host directories for the module, e.g. /usr/share/fonts for webby-render.
    dirs = []
    for entry in filter(None, os.environ.get("WASI_RUN_DIRS", "").split(",")):
        host, _, guest = entry.partition("=")
        dirs.append((host, guest or host))
    while argv and argv[0] == "--dir":
        host, _, guest = argv[1].partition("::")
        dirs.append((host, guest or host))
        argv = argv[2:]
    if not argv:
        print("usage: wasi-run.py [--dir HOST[::GUEST]]... MODULE [ARGS...]", file=sys.stderr)
        return 2
    path, args = argv[0], argv[1:]
    argv0 = os.path.basename(path)
    engine = make_engine()
    if is_component(path):
        return run_component(engine, path, argv0, args, dirs)
    module = wasmtime.Module.from_file(engine, path)
    if any(i.module.startswith("wasi:") for i in module.imports):
        if os.environ.get("WASM_TOOLS") or shutil.which("wasm-tools"):
            return run_component(engine, componentize(path), argv0, args, dirs)
        # Without wasm-tools, run the module as it is: it works until it opens a socket, which traps.
        print("wasi-run.py: no wasm-tools, so sockets trap (the module imports wasi:sockets)", file=sys.stderr)
        return run_module(engine, module, argv0, args, dirs, trap_unknown=True)
    return run_module(engine, module, argv0, args, dirs)


if __name__ == "__main__":
    # wasmtime runs the module on the calling thread's stack, so that thread needs more than max_wasm_stack.
    import threading

    threading.stack_size(WASM_STACK + (64 << 20))
    result = []
    thread = threading.Thread(target=lambda: result.append(main()))
    thread.start()
    thread.join()
    sys.exit(result[0] if result else 1)
