#!/usr/bin/env python3
"""The AppImage, built entirely on the fileapi forge (nandi.uk/webby, .forge/jobs.toml): no GitHub Actions, no
GitHub releases. Runs on Depot in the job's container (Ubuntu 22.04, the oldest glibc the AppImage supports).

1. Builds the webby conda package of this commit with rattler-build (conda/webby, as scripts/publish_conda.sh does;
   the engine, webby-ladybird, comes from prefix.dev/nandi-testing). Version: the build's UTC date and time,
   YYYY.MM.DD.HHMMSS, so every forge build is newer than the one before. It isn't uploaded anywhere.
2. Packs it with scripts/build_appimage.sh (LOCAL_CHANNEL = that build). The update information points at this
   repo's latest forge release (UPDATE_INFO = zsync|<forge>/api/forge/repos/<repo>/releases/latest/assets/...).
3. Launch check under Xvfb: WebContent and RequestServer must come up and stay up.
4. Uploads webby-x86_64.AppImage + .zsync to the forge's rolling `appimage` release (replacing the old files),
   then sets the title "webby AppImage <version>" last, like the GitHub job did.

FORGE_API, FORGE_TOKEN, FORGE_SHA, FORGE_URL, FORGE_REPO and forge-release come from the forge.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANNEL = os.environ.get("CHANNEL", "nandi-testing")
TAG = "appimage"
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


def main():
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
    # The files first and the title (the version updaters compare with) last.
    subprocess.run(["forge-release", "upload", "--create", TAG, str(dist / "webby-x86_64.AppImage"),
                    str(dist / "webby-x86_64.AppImage.zsync")], check=True)
    status, out = forge("PATCH", f"/releases/{TAG}", {"name": f"webby AppImage {version}", "notes": notes,
                                                      "draft": False, "prerelease": False})
    if status >= 300:
        sys.exit(f"updating the {TAG} release failed: HTTP {status} {out}")
    say(f"Published webby AppImage {version}: {FORGE_URL}/forge/{REPO}/-/releases/{TAG}")


if __name__ == "__main__":
    main()
