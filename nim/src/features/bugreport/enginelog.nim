## The engine's own log for bug reports: what webby and its Ladybird helpers (WebContent, RequestServer,
## ImageDecoder, ...) print to stderr. enginelog.c tees stderr into a per-process file in the runtime directory
## (tmpfs, gone at logout; deleted when webby quits), and `entries` reads a time window of it back as
## {t, process, pid, level, text}. Ladybird's lines look like "81.825 WebContent(553): FIXME: ...": the helper's
## uptime, its name and pid. Lines without that shape continue the entry before (stack traces) or are webby's own.
##
## Secrets: query strings in URLs keep their names but lose the values of secret-looking parameters, like the
## page capture does.

import std/[json, os, strutils]
import std/posix except Timer

{.compile: "enginelog.c".}
{.passL: "-pthread".}

proc webby_enginelog_start(path: cstring, maxBytes: clonglong): cint {.importc, cdecl.}

const
  maxFileBytes = 8 * 1024 * 1024   ## then the file moves to .1, so at most ~16 MB is kept
  maxEntries = 3000
  secretWords = ["pass", "secret", "token", "key", "auth", "session", "otp", "cvv", "cvc", "sig", "code",
                 "credential", "cookie"]

var path: string

proc logDir(): string =
  let runtime = getEnv("XDG_RUNTIME_DIR")
  if runtime.len > 0 and dirExists(runtime): runtime / "webby"
  else: getTempDir() / "webby-" & $getuid()

proc start*() =
  ## Call before the engine starts its helpers. Also drops logs left by webby processes that are gone.
  let dir = logDir()
  try:
    createDir(dir)
    for f in walkFiles(dir / "engine-*.log*"):
      let pid = f.extractFilename.split('-')[1].split('.')[0]
      if not dirExists("/proc" / pid): removeFile(f)
  except CatchableError: discard
  path = dir / "engine-" & $getCurrentProcessId() & ".log"
  if webby_enginelog_start(path.cstring, maxFileBytes) != 0: path = ""

proc stop*() =
  if path.len == 0: return
  try:
    removeFile(path)
    removeFile(path & ".1")
  except CatchableError: discard

proc secretName(name: string): bool =
  let n = name.toLowerAscii
  for w in secretWords:
    if w in n: return true

proc scrubQuery(query: string): string =
  var parts: seq[string]
  for part in query.split('&'):
    let eq = part.find('=')
    if eq > 0 and secretName(part[0 ..< eq]): parts.add part[0 .. eq] & "***"
    else: parts.add part
  parts.join("&")

proc scrub*(text: string): string =
  ## Secret-looking query parameters in every http(s) URL in `text`.
  result = text
  var at = 0
  while true:
    var start = result.find("http", at)
    if start < 0: break
    if not (result.continuesWith("http://", start) or result.continuesWith("https://", start)):
      at = start + 4
      continue
    var stop = start
    while stop < result.len and result[stop] notin {' ', '"', '\'', '<', '>', '\t', ')'}: inc stop
    let url = result[start ..< stop]
    let q = url.find('?')
    if q >= 0:
      let hash = url.find('#', q)
      let qEnd = if hash < 0: url.len else: hash
      let clean = url[0 .. q] & scrubQuery(url[q + 1 ..< qEnd]) & url[qEnd .. ^1]
      result = result[0 ..< start] & clean & result[stop .. ^1]
      stop = start + clean.len
    at = stop

proc stripAnsi(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and s[i] notin {'A' .. 'Z', 'a' .. 'z'}: inc i
      inc i
    else:
      result.add s[i]
      inc i

proc level(text: string): string =
  # A page's console as the engine prints it: "(js error) ..."
  for (tag, lvl) in [("(js error)", "error"), ("(js warn)", "warn"), ("(js info)", "info"), ("(js log)", "log"),
                     ("(js debug)", "debug"), ("(js trace)", "debug")]:
    if text.startsWith(tag): return lvl
  let t = text.toLowerAscii
  if "unhandled javascript exception" in t or "verification failed" in t or "assertion failed" in t or
      "crashed" in t or "segmentation fault" in t or t.startsWith("error") or " error:" in t or "failed to" in t:
    "error"
  elif "fixme" in t or "unimplemented" in t or "content security policy" in t or "refused to" in t or
      "warning" in t or "not supported" in t:
    "warn"
  elif "filtered request" in t: "info"
  else: "debug"

proc parse(line: string): tuple[process: string, pid: int, text: string, ok: bool] =
  ## "81.825 WebContent(553): text" (the uptime is optional)
  var s = line
  let sp = s.find(' ')
  if sp > 0 and s[0] in Digits and '.' in s[0 ..< sp]: s = s[sp + 1 .. ^1]
  let open = s.find('(')
  if open <= 0 or open > 40: return
  let close = s.find("): ", open)
  if close < 0: return
  let name = s[0 ..< open]
  for c in name:
    if not (c.isAlphaNumeric or c in {'_', '-'}): return
  let pid = try: parseInt(s[open + 1 ..< close]) except ValueError: return
  (name, pid, s[close + 3 .. ^1], true)

proc readLines(file: string): seq[string] =
  try: readFile(file).splitLines except CatchableError: @[]

proc entries*(fromMs, toMs: int64): seq[JsonNode] =
  ## The log between two wall-clock times (ms since the epoch), newest `maxEntries` at most.
  if path.len == 0: return
  var current: JsonNode
  proc flush(list: var seq[JsonNode]) =
    if current != nil:
      current["level"] = %level(current["text"].getStr)
      current["text"] = %scrub(current["text"].getStr)
      list.add current
      current = nil
  for line in readLines(path & ".1") & readLines(path):
    let sp = line.find(' ')
    if sp <= 0: continue
    let t = try: parseBiggestInt(line[0 ..< sp]) except ValueError: continue
    if t < fromMs or t > toMs: continue
    let raw = stripAnsi(line[sp + 1 .. ^1])
    if raw.strip.len == 0: continue
    let p = parse(raw)
    if p.ok and current != nil and p.text.startsWith(" ") and current["pid"].getInt == p.pid and
        current["text"].getStr.count('\n') < 40:
      current["text"] = %(current["text"].getStr & "\n" & p.text)   # a stack trace line, printed on its own
    elif p.ok:
      flush(result)
      current = %*{"t": t, "kind": "engine", "process": p.process, "pid": p.pid, "text": p.text}
    elif current != nil and (raw.startsWith(" ") or raw.startsWith("\t")) and
        current["text"].getStr.count('\n') < 40:
      current["text"] = %(current["text"].getStr & "\n" & raw)
    else:
      flush(result)
      current = %*{"t": t, "kind": "engine", "process": "webby", "pid": getCurrentProcessId(), "text": raw}
  flush(result)
  if result.len > maxEntries: result = result[^maxEntries .. ^1]
