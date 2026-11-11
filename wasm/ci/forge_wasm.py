#!/usr/bin/env python3
"""webby's wasm build on the fileapi forge (nandi.uk/webby, .forge/jobs.toml). Two jobs, each a `depot build` with
BuildKit cache mounts Depot keeps between runs, so nothing is built twice:

  forge_wasm.py deps     The WASI sysroot (ci/deps.Dockerfile: deps/all.sh, every dependency plus the patched
                         wasm-opt) as webby-wasi-sysroot-<key>.tar.zst on the rolling `wasm-deps` release. <key> is
                         a hash of everything that goes into it (deps/, compat/, cmake/, tools/meson-wasi-cc, the
                         Dockerfile and ci/base.sh), so a push that changes none of them finds the asset there and builds nothing.
  forge_wasm.py engine   Ladybird for wasm32-wasip1 (ci/engine.Dockerfile, ci/engine.sh) against that sysroot: the
                         targets in ci/engine-targets (WASM_TARGETS overrides) as <target>.wasm on the rolling
                         `wasm-engine` release, with SHA256SUMS and the build log. A cold build doesn't fit the
                         forge's one-hour job limit, so the build stops itself in time, keeps what it compiled in
                         the cache and starts the job again; the next run carries on.

  forge_wasm.py key      Prints the sysroot key (no forge needed).

The forge gives FORGE_API, FORGE_TOKEN, FORGE_SHA, FORGE_BRANCH and forge-release; Depot needs the DEPOT_TOKEN and
DEPOT_PROJECT_ID secrets (user secrets on this forge).
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WASM = ROOT / "wasm"
CI = WASM / "ci"
DEPS_TAG, ENGINE_TAG = "wasm-deps", "wasm-engine"
JOB_LIMIT = 3600
START = time.time()
UA = "webby-forge-ci/1"  # the forge sits behind Cloudflare, which rejects urllib's default User-Agent


def say(*a):
    print(*a, flush=True)


def sysroot_key():
    h = hashlib.sha256()
    files = [CI / "deps.Dockerfile", CI / "base.sh"]
    files += [WASM / "tools" / "meson-wasi-cc"]
    for d in ("deps", "compat", "cmake"):
        files += [p for p in (WASM / d).rglob("*") if p.is_file()]
    for p in sorted(files):
        h.update(str(p.relative_to(ROOT)).encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()[:16]


def asset_name(key):
    return f"webby-wasi-sysroot-{key}.tar.zst"


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(os.environ["FORGE_API"].rstrip("/") + path, data=data, method=method, headers={
        "Authorization": f"Bearer {os.environ['FORGE_TOKEN']}", "User-Agent": UA,
        **({"Content-Type": "application/json"} if data else {})})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def assets(tag):
    status, rel = api("GET", f"/releases/{tag}")
    if status == 404:
        return []
    if status >= 300:
        sys.exit(f"reading the {tag} release failed: HTTP {status} {rel}")
    return rel.get("assets") or []


def download(tag, name, dest):
    url = os.environ["FORGE_API"].rstrip("/") + f"/releases/{tag}/assets/{urllib.parse.quote(name)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {os.environ['FORGE_TOKEN']}", "User-Agent": UA})
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(req, timeout=600) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    say(f"downloaded {name} ({dest.stat().st_size >> 20} MiB)")


def depot_build(dockerfile, out, build_args, log):
    """`depot build` of one of the Dockerfiles, its `out` stage exported to `out`. The job keeps only the first
    64 KiB of output, so the build log goes to a file with a line a minute here and its tail at the end."""
    if not shutil.which("depot"):
        sys.exit("the depot CLI is missing (the forge installs it for jobs whose run mentions depot)")
    shutil.rmtree(out, ignore_errors=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["depot", "build", "--progress", "plain", "--platform", "linux/amd64", "-f", str(dockerfile),
           "--target", "out", "--output", f"type=local,dest={out}", str(ROOT)]
    for k, v in build_args.items():
        cmd[2:2] = ["--build-arg", f"{k}={v}"]
    if os.environ.get("DEPOT_PROJECT_ID"):
        cmd[2:2] = ["--project", os.environ["DEPOT_PROJECT_ID"]]
    say("$ " + " ".join(cmd))
    t0 = time.time()
    with open(log, "wb") as f:
        p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        while p.poll() is None:
            time.sleep(60)
            last = [ln for ln in log.read_text("utf-8", "replace").splitlines() if ln.strip()][-1:] or [""]
            say(f"  [{int(time.time() - t0) // 60} min] {last[0][:180]}")
    lines = log.read_text("utf-8", "replace").splitlines()
    stages = [ln for ln in lines if " done in " in ln]  # deps/all.sh's "== <stage> done in N s"
    if stages:
        say("\n".join(stages[-30:]))
    say("\n".join(lines[-80:]))
    return p.returncode


def upload(tag, files, title, notes):
    subprocess.run(["forge-release", "upload", "--create", tag, *map(str, files)], check=True)
    status, out = api("PATCH", f"/releases/{tag}", {"name": title, "notes": notes, "draft": False, "prerelease": True})
    if status >= 300:
        sys.exit(f"updating the {tag} release failed: HTTP {status} {out}")


def deps():
    key = sysroot_key()
    name = asset_name(key)
    have = assets(DEPS_TAG)
    if any(a.get("name") == name for a in have):
        say(f"{name} is already on the {DEPS_TAG} release: nothing to build")
        return
    say(f"building the WASI sysroot {key}")
    out = ROOT / "build" / "wasm-deps"
    out.parent.mkdir(exist_ok=True)
    code = depot_build(CI / "deps.Dockerfile", out, {}, ROOT / "build" / "wasm-deps.log")
    tar = out / "webby-wasi-sysroot.tar.zst"
    if code != 0 or not tar.exists():
        sys.exit(f"the sysroot build failed (exit {code}); a rerun continues from the stages that finished")
    final = out / name
    tar.rename(final)
    sha = os.environ.get("FORGE_SHA", "")
    upload(DEPS_TAG, [final], f"WASI sysroot {key}",
           f"Every wasm32-wasip1 dependency of webby's engine (wasm/deps/all.sh, wasm/deps/sources.txt) and the "
           f"patched wasm-opt, from {sha}. Unpack it at /opt (it is /opt/webby-wasi, the path its .pc and CMake "
           f"files name): `tar -C /opt -I zstd -xf {name}`, then WEBBY_WASI_SYSROOT=/opt/webby-wasi.\n\n"
           f"The asset name carries a hash of wasm/deps, compat, cmake, tools/meson-wasi-cc, ci/deps.Dockerfile and ci/base.sh "
           f"(`python3 wasm/ci/forge_wasm.py key`).")
    # Keep this sysroot and the one before it (an engine build may still be using it); drop older ones.
    old = sorted((a for a in have if a.get("name", "").startswith("webby-wasi-sysroot-") and a["name"] != name),
                 key=lambda a: a.get("created_at") or a.get("updated_at") or "", reverse=True)[1:]
    for a in old:
        s, _ = api("DELETE", f"/releases/{DEPS_TAG}/assets/{urllib.parse.quote(a['name'])}")
        say(f"deleted old {a['name']} (HTTP {s})")
    say(f"Published {name}: {os.environ.get('FORGE_URL', 'https://fileapi.fastapicloud.dev')}/forge/"
        f"{os.environ.get('FORGE_REPO', 'nandi.uk/webby')}/-/releases/{DEPS_TAG}")


def again(reason):
    """Start this job again on the same branch, to carry on a build the time limit cut short."""
    branch = os.environ.get("FORGE_BRANCH") or "main"
    status, out = api("POST", "/runs", {"ref": branch, "job": "wasm-engine"})
    if status >= 300:
        say(f"{reason}; starting the job again failed (HTTP {status} {out}): run wasm-engine again by hand")
    else:
        say(f"{reason}; started wasm-engine again on {branch} to carry on")


def engine():
    listed = [ln.split("#")[0] for ln in (CI / "engine-targets").read_text().splitlines()]
    targets = " ".join((os.environ.get("WASM_TARGETS") or " ".join(listed)).split())
    name = asset_name(sysroot_key())
    if not any(a.get("name") == name for a in assets(DEPS_TAG)):
        sys.exit(f"{name} is not on the {DEPS_TAG} release: the wasm-deps job has to publish it first")
    download(DEPS_TAG, name, CI / "out" / "webby-wasi-sysroot.tar.zst")
    # What is left of the hour after this script's own work, minus time to export and upload.
    budget = int(JOB_LIMIT - (time.time() - START) - 900)
    if budget < 600:
        sys.exit("not enough of the job's hour left to build")
    out = ROOT / "build" / "wasm-engine"
    code = depot_build(CI / "engine.Dockerfile", out,
                       {"TARGETS": targets, "BUDGET": budget, "RUN_ID": f"{os.environ.get('FORGE_SHA', '')}-{time.time():.0f}"},
                       ROOT / "build" / "wasm-engine.log")
    status = (out / "status").read_text().strip() if (out / "status").exists() else ""
    if code != 0 or not status:
        sys.exit(f"the engine image build failed (exit {code})")
    say("--- build.log (tail)")
    say((out / "build.log").read_text("utf-8", "replace")[-12000:])
    if status == "partial":
        progress = (out / "progress").read_text().strip() if (out / "progress").exists() else "?"
        again(f"the build ran out of time at {progress}")
        return
    if status != "ok":
        sys.exit(f"the engine build failed ({status})")
    sha = os.environ.get("FORGE_SHA", "")
    wasms = sorted(out.glob("*.wasm"))
    upload(ENGINE_TAG, [*wasms, *out.glob("webby-render-test.png"), *out.glob("webby-render-net-*.png"), out / "SHA256SUMS", out / "build.log"], f"webby wasm engine {sha[:12]}",
           f"Ladybird ({(ROOT / 'LADYBIRD_COMMIT').read_text().strip()[:10]}) with webby's patches for wasm32-wasip1, "
           f"from {sha}, built against {name}: {', '.join(p.name for p in wasms)}.\n\n"
           f"Run with wasm/tools/wasi-run.py (PyPI wasmtime, wasm exceptions on, a big wasm stack): "
           f"`python wasm/tools/wasi-run.py js.wasm -c 'print(6 * 7)'`.")
    say(f"Published {', '.join(p.name for p in wasms)} on the {ENGINE_TAG} release")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "key":
        print(sysroot_key())
    elif cmd == "deps":
        deps()
    elif cmd == "engine":
        engine()
    else:
        sys.exit("usage: forge_wasm.py deps|engine|key")


if __name__ == "__main__":
    main()
