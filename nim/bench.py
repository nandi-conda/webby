#!/usr/bin/env python3
"""A/B harness for webby front ends: CPU, memory and wheel latency of one browser on one page.

    bench.py TAG URL -- COMMAND...      (e.g. bench.py nim https://... -- nim/webby)

Needs an X display (Xvfb), xdotool, and WEBBY_LADYBIRD_PREFIX. Sets WEBBY_TRACE=1, so both front ends print
webby-trace lines with wheelMs (wheel event sent -> next new frame). Phases: LOAD s to settle, IDLE s measured
idle, SCROLL s of wheel notches (RATE per second, alternating down/up runs). CPU is % of one core, split into the
UI process (the front end) and Ladybird's helpers (WebContent, RequestServer, ...). Memory is PSS in MB.
"""
import os, re, subprocess, sys, time

LOAD, IDLE, SCROLL, RATE = (float(os.environ.get(k, d)) for k, d in
                            (("LOAD", 12), ("IDLE", 10), ("SCROLL", 10), ("RATE", 30)))
TICK = os.sysconf("SC_CLK_TCK")


def tree(pid):
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        out.append(p)
        # Children hang off the thread that spawned them (Flutter starts Ladybird on its UI thread), so read every task.
        try:
            tasks = os.listdir(f"/proc/{p}/task")
        except OSError:
            continue
        for t in tasks:
            try:
                with open(f"/proc/{p}/task/{t}/children") as f:
                    todo += [int(c) for c in f.read().split()]
            except OSError:
                pass
    return out


def cpu_ticks(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return int(fields[11]) + int(fields[12])
    except OSError:
        return 0


def pss_mb(pid):
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            m = re.search(r"^Pss:\s+(\d+)", f.read(), re.M)
            return int(m.group(1)) / 1024 if m else 0
    except OSError:
        return 0


def sample(root):
    pids = tree(root)
    return {p: cpu_ticks(p) for p in pids}


def cpu_split(root, before, after, secs):
    ui = (after.get(root, 0) - before.get(root, 0)) / TICK / secs * 100
    total = sum(after[p] - before.get(p, after[p]) for p in after) / TICK / secs * 100
    return ui, total - ui


def main():
    tag, url = sys.argv[1], sys.argv[2]
    cmd = sys.argv[sys.argv.index("--") + 1:] + [url]
    env = dict(os.environ, WEBBY_TRACE="1")
    log = open(f"{tag}.log", "w")
    proc = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    time.sleep(3)
    wid = subprocess.run(["xdotool", "search", "--sync", "--onlyvisible", "--pid", str(proc.pid)],
                         capture_output=True, text=True).stdout.split()
    if wid:
        subprocess.run(["xdotool", "windowmove", wid[0], "0", "0", "windowsize", wid[0], "1280", "800"])
    time.sleep(LOAD)
    subprocess.run(["xdotool", "mousemove", "640", "450"])
    time.sleep(1)

    a = sample(proc.pid); time.sleep(IDLE); b = sample(proc.pid)
    idle = cpu_split(proc.pid, a, b, IDLE)
    log.flush(); mark = os.path.getsize(f"{tag}.log")

    a = sample(proc.pid)
    end, n = time.time() + SCROLL, 0
    while time.time() < end:
        subprocess.run(["xdotool", "click", "5" if (n // 40) % 2 == 0 else "4"])
        n += 1
        time.sleep(1 / RATE)
    b = sample(proc.pid)
    scroll = cpu_split(proc.pid, a, b, SCROLL)
    time.sleep(5.5)  # let the 5 s trace line covering the scroll print
    pids = tree(proc.pid)
    ui_pss, all_pss = pss_mb(proc.pid), sum(pss_mb(p) for p in pids)
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
    log.close()

    with open(f"{tag}.log") as f:
        f.seek(mark)
        lat = [(float(w), float(m), int(c)) for c, w, m in
               re.findall(r"wheels=(\d+) wheelMs=([\d.]+) maxWheelMs=([\d.]+)", f.read()) if int(c) > 0]
    frames = sum(c for _, _, c in lat)
    wheel = sum(w * c for w, _, c in lat) / frames if frames else 0
    worst = max((m for _, m, _ in lat), default=0)
    print(f"{tag}: idle ui={idle[0]:.1f}% engine={idle[1]:.1f}% | scroll ui={scroll[0]:.1f}% engine={scroll[1]:.1f}% "
          f"| wheel->frame {wheel:.1f} ms avg, {worst:.1f} max ({frames} frames, {n} notches) "
          f"| PSS ui={ui_pss:.0f} MB total={all_pss:.0f} MB")


if __name__ == "__main__":
    main()
