#!/usr/bin/env python3
"""The AppImage on the fileapi forge (nandi.uk/webby, .forge/jobs.toml): what publish.yml's `appimage` job does on
GitHub, published to the forge's rolling `appimage` release instead.

The AppImage follows conda: it's packed (scripts/build_appimage.sh) from the webby that GitHub's publish.yml put on
prefix.dev/nandi-testing for this very commit. The forge gets the commit from GitHub ([upstream] in jobs.toml) as
GitHub starts publishing it, so this first waits for that package: the newest webby in the channel whose recipe
names FORGE_SHA (scripts/publish_conda.sh bakes the commit in for ⋮ > About). If it doesn't show up in time (say a
newer commit superseded it), it packs the newest webby instead, unless the release already has that version.

Then: launch check under Xvfb (the job runs on Ubuntu 22.04, the oldest glibc the AppImage supports), upload
webby-x86_64.AppImage + .zsync to the `appimage` release (replacing the old files), and set the title
("webby AppImage <version>") last, like GitHub. The update information inside still points at GitHub's `appimage`
release, so a forge download updates itself from GitHub with the same files.

Runs on Depot in the job's container; needs pixi's install script (curl), python3, xvfb. FORGE_API, FORGE_TOKEN,
FORGE_SHA and forge-release come from the forge.
"""
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import zstandard

ROOT = Path(__file__).resolve().parent.parent
CHANNEL = os.environ.get("CHANNEL", "nandi-testing")
CHANNEL_URL = f"https://prefix.dev/{CHANNEL}/linux-64"
TAG = "appimage"
WAIT = int(os.environ.get("WAIT_SECONDS", "1800"))
SHA = os.environ["FORGE_SHA"]
API = os.environ["FORGE_API"].rstrip("/")
UA = "webby-forge-ci/1"  # the forge sits behind Cloudflare, which rejects urllib's default User-Agent


def say(*a):
    print(*a, flush=True)


def get(url, headers=None, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 or attempt == 4:
                raise
        except (urllib.error.URLError, OSError):
            if attempt == 4:
                raise
        time.sleep(5 * 2 ** attempt)


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


def released_version():
    status, rel = forge("GET", f"/releases/{TAG}")
    if status != 200:
        return None
    words = [w for w in (rel.get("name") or "").split() if w[:1].isdigit()]
    return words[0] if words else None


def newest_webby():
    repodata = json.loads(get(f"{CHANNEL_URL}/repodata.json"))
    pkgs = [(f, p) for key in ("packages", "packages.conda") for f, p in repodata.get(key, {}).items()
            if p["name"] == "webby"]
    return max(pkgs, key=lambda fp: (fp[1].get("timestamp", 0), fp[1]["build_number"]))


_commits = {}


def commit_of(filename):
    """The commit a webby package was built from: its rendered recipe has WEBBY_COMMIT (only the small info part
    of the .conda is read)."""
    if filename not in _commits:
        z = zipfile.ZipFile(io.BytesIO(get(f"{CHANNEL_URL}/{filename}")))
        info = next(n for n in z.namelist() if n.startswith("info-"))
        raw = zstandard.ZstdDecompressor().stream_reader(io.BytesIO(z.read(info))).read()
        with tarfile.open(fileobj=io.BytesIO(raw)) as t:
            recipe = t.extractfile("info/recipe/rendered_recipe.yaml").read().decode("utf-8", "replace")
        m = re.search(r"WEBBY_COMMIT:\s*['\"]?([0-9a-f]{40})", recipe)
        _commits[filename] = m.group(1) if m else ""
    return _commits[filename]


def pick_version():
    deadline = time.time() + WAIT
    say(f"Waiting up to {WAIT // 60} min for the webby conda package of {SHA[:12]} on {CHANNEL}")
    while True:
        filename, pkg = newest_webby()
        if commit_of(filename) == SHA:
            say(f"webby {pkg['version']} ({filename}) is this commit's")
            return pkg["version"]
        if time.time() > deadline:
            say(f"No webby package of {SHA[:12]} after {WAIT // 60} min; the newest is {pkg['version']} "
                f"({commit_of(filename)[:12] or 'unknown commit'})")
            return pkg["version"]
        time.sleep(60)


def run_quiet(cmd, log, tail=40, **kw):
    """The job keeps only the first 64 KiB of output, so the long logs go to a file and only their tail shows."""
    with open(log, "wb") as f:
        code = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, **kw).returncode
    lines = Path(log).read_text("utf-8", "replace").splitlines()
    say("\n".join(lines[-tail:]))
    return code


def build(version, dist):
    env = {**os.environ, "PATH": f"{Path.home()}/.pixi/bin:{os.environ['PATH']}"}
    for i in range(1, 6):
        say(f"$ scripts/build_appimage.sh {version} dist  (try {i})")
        if run_quiet([str(ROOT / "scripts/build_appimage.sh"), version, str(dist)], ROOT / "build.log", env=env) == 0:
            return
        if i == 5:
            sys.exit("build_appimage.sh failed 5 times")
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
    have = released_version()
    say(f"Forge release {TAG}: {have or 'none yet'}")
    version = pick_version()
    if version == have:
        say(f"The {TAG} release already has webby {version}; nothing to do")
        return
    dist = ROOT / "dist"
    build(version, dist)
    launch_check(dist)
    notes = (f"webby {version} ({SHA}), the same build as the conda package `webby=={version}`.\n\n"
             "Download webby-x86_64.AppImage, `chmod +x` it and run it (glibc 2.35 or newer, e.g. Ubuntu 22.04+).\n"
             "It updates itself with zsync from the `appimage` release on github.com/nandi-conda/webby "
             "(the same files): ⋮ > Help > Check for updates, or AppImageUpdate / Gear Lever.")
    # The files first and the title (the version updaters compare with) last, like GitHub.
    subprocess.run(["forge-release", "upload", "--create", TAG, str(dist / "webby-x86_64.AppImage"),
                    str(dist / "webby-x86_64.AppImage.zsync")], check=True)
    status, out = forge("PATCH", f"/releases/{TAG}", {"name": f"webby AppImage {version}", "notes": notes,
                                                      "draft": False, "prerelease": False})
    if status >= 300:
        sys.exit(f"updating the {TAG} release failed: HTTP {status} {out}")
    say(f"Published webby AppImage {version}: {os.environ.get('FORGE_URL', '')}/forge/{os.environ.get('FORGE_REPO', '')}/-/releases/{TAG}")


if __name__ == "__main__":
    main()
