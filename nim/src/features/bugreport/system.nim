## Webby's own state for bug reports: its process and the engine helpers under it (name, pid, memory, CPU) read
## from /proc, plus the tabs and settings bugreport.nim adds. A recording takes a sample every couple of seconds,
## so memory and CPU go along on the timeline.

import std/[algorithm, json, os, strutils, tables, times]

type
  Sampler* = ref object
    ticks: Table[int, int]       ## pid -> utime + stime at the last sample
    at: float                    ## epochTime() of the last sample

proc newSampler*(): Sampler = Sampler()

proc statFields(path: string): (string, seq[string]) =
  # comm is in parentheses and may contain spaces; the fields after it are space-separated.
  try:
    let s = readFile(path)
    let a = s.find('(')
    let b = s.rfind(')')
    if a < 0 or b < a: return ("", @[])
    (s[a + 1 ..< b], s[b + 2 .. ^1].splitWhitespace())
  except CatchableError: ("", @[])

proc kb(file, field: string): int =
  ## A "Field:   1234 kB" line of /proc/<pid>/status or smaps_rollup.
  try:
    for line in lines(file):
      if line.startsWith(field & ":"): return parseInt(line[field.len + 1 .. ^1].strip.split(' ')[0])
  except CatchableError: discard

proc ourProcesses(): seq[tuple[pid: int, name: string, stat: seq[string]]] =
  var parent: Table[int, int]
  var info: Table[int, (string, seq[string])]
  for kind, path in walkDir("/proc"):
    let pid = try: parseInt(path.extractFilename) except ValueError: -1
    if pid < 0: continue
    let (name, f) = statFields(path / "stat")
    if f.len < 13: continue
    parent[pid] = (try: parseInt(f[1]) except ValueError: 0)
    info[pid] = (name, f)
  let me = getCurrentProcessId()
  for pid, (name, f) in info:
    var p = pid
    for _ in 0 .. 32:
      if p == me:
        result.add (pid, (if pid == me: "webby" else: name), f)
        break
      if p <= 1 or p notin parent: break
      p = parent[p]

proc mb(k: int): string = $((k + 512) div 1024) & " MB"

proc sample*(s: Sampler): JsonNode =
  ## {t, processes: [{pid, name, rssKb, pssKb, cpu}], pssKb, cpu, text}; cpu is % of one core since the last
  ## sample (since each process started, for the first one).
  let now = epochTime()
  let hz = 100.0
  let uptime = try: parseFloat(readFile("/proc/uptime").split(' ')[0]) except CatchableError: 0.0
  var processes = newJArray()
  var totalPss, totalCpu = 0.0
  var fresh: Table[int, int]
  var parts: seq[string]
  var list = ourProcesses()
  list.sort(proc (a, b: tuple[pid: int, name: string, stat: seq[string]]): int = cmp(a.pid, b.pid))
  for (pid, name, f) in list:
    let ticks = (try: parseInt(f[11]) + parseInt(f[12]) except ValueError: 0)
    fresh[pid] = ticks
    let cpu =
      if s.at > 0 and pid in s.ticks: (ticks - s.ticks[pid]).float / hz / max(now - s.at, 0.001) * 100
      else:
        let started = (try: parseFloat(f[19]) / hz except ValueError, IndexDefect: 0.0)
        ticks.float / hz / max(uptime - started, 0.001) * 100
    let pss = kb("/proc" / $pid / "smaps_rollup", "Pss")
    let rss = kb("/proc" / $pid / "status", "VmRSS")
    totalPss += pss.float
    totalCpu += cpu
    processes.add %*{"pid": pid, "name": name, "rssKb": rss, "pssKb": pss, "cpu": int(cpu)}
    parts.add name & " " & $pid & " " & mb(if pss > 0: pss else: rss) & " " & $int(cpu) & "%"
  s.ticks = fresh
  s.at = now
  %*{"t": int64(now * 1000), "kind": "system", "processes": processes, "pssKb": int(totalPss), "cpu": int(totalCpu),
     "text": "memory " & mb(int(totalPss)) & ", CPU " & $int(totalCpu) & "% (" & parts.join(", ") & ")"}
