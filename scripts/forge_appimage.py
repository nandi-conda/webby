#!/usr/bin/env python3
"""The AppImage, built entirely on the fileapi forge (nandi.uk/webby, .forge/jobs.toml): no GitHub Actions, no
GitHub releases. Runs on Depot in the job's container (Ubuntu 22.04, the oldest glibc the AppImage supports).

1. Builds the webby conda package of this commit with rattler-build (conda/webby, as scripts/publish_conda.sh does;
   the engine, webby-ladybird, comes from prefix.dev/nandi-testing). Version: the build's UTC date and time,
   YYYY.MM.DD.HHMMSS, so every forge build is newer than the one before. It isn't uploaded anywhere.
2. Packs it with scripts/build_appimage.sh (LOCAL_CHANNEL = that build). The update information points at this
   repo's latest forge release (UPDATE_INFO = zsync|<forge>/api/forge/repos/<repo>/releases/latest/assets/...).
3. Launch check under Xvfb: WebContent and RequestServer must come up and stay up.
4. Cuts a release of its own, appimage-<version>, with webby-x86_64.AppImage + .zsync (the newest 5 are kept), so
   it is the forge's latest release; then puts the same files on the rolling `appimage` release, which webby's
   own updater (nim/src/features/update.nim) reads, and sets each title "webby AppImage <version>" last.

FORGE_API, FORGE_TOKEN, FORGE_SHA, FORGE_URL, FORGE_REPO and forge-release come from the forge.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANNEL = os.environ.get("CHANNEL", "nandi-testing")
TAG = "appimage"  # rolling: the fixed address installed webbys check for updates
BUILD_PREFIX, KEEP_BUILDS = "appimage-", 5  # one release per build (V, 2026-11-12), the newest few kept
SHA = os.environ["FORGE_SHA"]
API = os.environ["FORGE_API"].rstrip("/")
REPO = os.environ.get("FORGE_REPO", "nandi.uk/webby")
FORGE_URL = (os.environ.get("FORGE_URL") or "https://fileapi.fastapicloud.dev").rstrip("/")
UA = "webby-forge-ci/1"  # the forge sits behind Cloudflare, which rejects urllib's default User-Agent


def say(*a):
    print(*a, flush=True)


def forge(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": f"Bearer {os.environ['FORGE_TOKEN']}", "User-Agent": UA,
        **({"Content-Type": "application/json"} if data else {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def run_quiet(cmd, log, tail=40, **kw):
    """The job keeps only the first 64 KiB of output, so the long logs go to a file and only their tail shows."""
    with open(log, "wb") as f:
        code = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, **kw).returncode
    lines = Path(log).read_text("utf-8", "replace").splitlines()
    say("\n".join(lines[-tail:]))
    return code


PIXI_ENV = {**os.environ, "PATH": f"{Path.home()}/.pixi/bin:{os.environ['PATH']}"}


def conda_build(version, build_number, out):
    """The webby conda package of this commit, as scripts/publish_conda.sh builds it (without the upload)."""
    env = {**PIXI_ENV, "WEBBY_VERSION": version, "WEBBY_BUILD_NUMBER": str(build_number), "WEBBY_COMMIT": SHA}
    subprocess.run(["pixi", "global", "install", "rattler-build"], env=env, check=True, stdout=subprocess.DEVNULL)
    say(f"$ rattler-build build conda/webby  (webby {version})")
    code = run_quiet(["rattler-build", "build", "--recipe", str(ROOT / "conda/webby/recipe.yaml"),
                      "--output-dir", str(out), "-c", "conda-forge", "-c", f"https://prefix.dev/{CHANNEL}"],
                     ROOT / "conda-build.log", env=env)
    if code != 0:
        sys.exit(f"rattler-build failed (exit {code})")
    built = sorted((out / "linux-64").glob(f"webby-{version}-*.conda"))
    if not built:
        sys.exit("rattler-build made no webby package")
    say(f"built {built[0].name}")


def build(version, dist, channel):
    update_info = f"zsync|{FORGE_URL}/api/forge/repos/{REPO}/releases/latest/assets/webby-x86_64.AppImage.zsync"
    env = {**PIXI_ENV, "LOCAL_CHANNEL": channel.as_uri(), "UPDATE_INFO": update_info}
    for i in range(1, 4):
        say(f"$ scripts/build_appimage.sh {version} dist  (try {i})")
        if run_quiet([str(ROOT / "scripts/build_appimage.sh"), version, str(dist)], ROOT / "build.log", env=env) == 0:
            return
        if i == 3:
            sys.exit("build_appimage.sh failed 3 times")
        time.sleep(30)
        subprocess.run(["pixi", "clean", "cache", "--repodata", "-y"], env=env)


def launch_check(dist):
    """Unpacked (no FUSE in the container), under Xvfb: the page's helper processes must come up and stay up."""
    work = Path("/tmp/launch")
    work.mkdir(exist_ok=True)
    subprocess.run([str(dist / "webby-x86_64.AppImage"), "--appimage-extract"], cwd=work, check=True,
                   stdout=subprocess.DEVNULL)
    log = open(work / "webby.log", "wb")
    proc = subprocess.Popen(["xvfb-run", "-a", str(work / "squashfs-root/AppRun"), "https://example.com"],
                            stdout=log, stderr=subprocess.STDOUT, cwd=work)

    def up():
        return all(subprocess.run(["pgrep", n], stdout=subprocess.DEVNULL).returncode == 0
                   for n in ("WebContent", "RequestServer"))

    try:
        for i in range(120):
            if up():
                break
            time.sleep(0.5)
        ok = up() and (time.sleep(3) or up())
        if not ok:
            say((work / "webby.log").read_text("utf-8", "replace")[-8000:])
            sys.exit("the AppImage didn't start: WebContent/RequestServer not up")
        say(f"helpers up after ~{i // 2} s")
    finally:
        proc.terminate()
        subprocess.run(["pkill", "-f", "squashfs-root"], stdout=subprocess.DEVNULL)


def superseded():
    """Whether main has moved past this run's commit: its own run builds that, so this one need not."""
    status, out = forge("GET", f"/commits?ref={os.environ.get('FORGE_BRANCH') or 'main'}&limit=1")
    try:
        head = out["commits"][0]["sha"] if status == 200 else ""
    except (TypeError, KeyError, IndexError):
        head = ""
    return bool(head) and head != SHA


def main():
    if superseded():
        say(f"main has moved past {SHA[:12]}: its newer run builds the AppImage, so this one stops")
        return
    now = time.gmtime()
    version = time.strftime("%Y.%m.%d.", now) + str(now.tm_hour * 10000 + now.tm_min * 100 + now.tm_sec)
    build_number = now.tm_hour * 10000 + now.tm_min * 100 + now.tm_sec
    say(f"webby {version} from {SHA[:12]}")
    channel = ROOT / "build" / "conda"
    conda_build(version, build_number, channel)
    dist = ROOT / "dist"
    build(version, dist, channel)
    launch_check(dist)
    notes = (f"webby {version}, built on this forge from {SHA}.\n\n"
             "Download webby-x86_64.AppImage, `chmod +x` it and run it (glibc 2.35 or newer, e.g. Ubuntu 22.04+).\n"
             "Its update information points at this release (zsync), for AppImageUpdate / Gear Lever.")
    # The files first and the title (the version updaters compare with) last. The build's own release first: it
    # becomes /releases/latest, where the AppImage's zsync update information points.
    files = [str(dist / "webby-x86_64.AppImage"), str(dist / "webby-x86_64.AppImage.zsync")]
    build_tag = BUILD_PREFIX + version
    for tag in (build_tag, TAG):
        subprocess.run(["forge-release", "upload", "--create", tag, *files], check=True)
        status, out = forge("PATCH", f"/releases/{tag}", {"name": f"webby AppImage {version}", "notes": notes,
                                                          "draft": False, "prerelease": False, "ref": SHA})
        if status >= 300:
            sys.exit(f"updating the {tag} release failed: HTTP {status} {out}")
    say(f"Published webby AppImage {version}: {FORGE_URL}/forge/{REPO}/-/releases/{build_tag}")
    prune()


def prune():
    """Delete all but the KEEP_BUILDS newest appimage-<version> releases (each AppImage is ~290 MB)."""
    status, out = forge("GET", "/releases")
    rels = out.get("releases") if isinstance(out, dict) else None
    if status != 200 or not isinstance(rels, list):
        say(f"listing releases failed (HTTP {status}): nothing pruned")
        return
    ours = sorted((r for r in rels if r.get("tag", "").startswith(BUILD_PREFIX)), key=lambda r: r.get("created") or "",
                  reverse=True)
    for r in ours[KEEP_BUILDS:]:
        s, _ = forge("DELETE", f"/releases/{urllib.parse.quote(r['tag'])}")
        say(f"deleted old release {r['tag']} (HTTP {s})")


if __name__ == "__main__":
    main()
