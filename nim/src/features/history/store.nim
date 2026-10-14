## One profile's browsing history (app/lib/src/history/history_store.dart): every visit with its URL, title and
## time, as JSON lines in `<profile>/history.jsonl` (or $WEBBY_HISTORY_FILE), the Flutter app's format. New visits
## and title changes are appended, so several windows can add to the same file; deleting rewrites the file through a
## temporary one. Visits older than 90 days are dropped. Incognito records nothing.

import std/[algorithm, json, os, posix, sequtils, sets, strutils, tables, times, uri]
import ../../browser

type
  HistoryEntry* = ref object
    id*, url*, title*: string
    time*: int64               ## milliseconds since the epoch

  HistorySuggestion* = object
    url*, title*: string
    visits*: int
    lastVisit*: int64

const keepForMs = 90'i64 * 24 * 3600 * 1000

var
  entries: seq[HistoryEntry]   ## oldest first
  idCounter = 0
  loaded = false
  changeHooks*: seq[proc ()]

proc nowMs*(): int64 = (epochTime() * 1000).int64

proc label*(e: HistoryEntry): string = (if e.title.len > 0: e.title else: e.url)

proc file*(): string =
  let override = getEnv("WEBBY_HISTORY_FILE")
  if override.len > 0: override else: profileFile("history.jsonl")

proc toJson(e: HistoryEntry): JsonNode = %*{"id": e.id, "url": e.url, "title": e.title, "t": e.time}

proc notify() =
  for h in changeHooks: h()

proc rewrite() =
  if incognito: return
  var s = ""
  for e in entries: s.add $toJson(e) & "\n"
  try: writeFileAtomic(file(), s)
  except CatchableError as e: stderr.writeLine "webby: could not write ", file(), ": ", e.msg

proc append(e: HistoryEntry) =
  try:
    createDir(file().parentDir)
    let f = open(file(), fmAppend)
    f.write $toJson(e) & "\n"
    f.close()
  except CatchableError as err: stderr.writeLine "webby: could not write ", file(), ": ", err.msg

proc merge() =
  ## Adds the visits in the file that aren't in memory yet (from other windows) and the titles they got there.
  loaded = true
  let path = file()
  if not fileExists(path): return
  var byId: OrderedTable[string, HistoryEntry]
  for e in entries: byId[e.id] = e
  var lines = 0
  try:
    for line in lines(path):
      if line.strip.len == 0: continue
      inc lines
      let j = try: parseJson(line) except CatchableError: nil   # a line cut short by a crash
      if j == nil or j.kind != JObject: continue
      let id = j{"id"}
      let url = j{"url"}
      let t = j{"t"}
      if id == nil or id.kind != JString or url == nil or url.kind != JString or t == nil or t.kind != JInt: continue
      let title = j{"title"}.getStr
      # A later line for the same visit is its title update.
      let known = byId.getOrDefault(id.getStr)
      if known != nil:
        if title.len > 0: known.title = title
      else:
        byId[id.getStr] = HistoryEntry(id: id.getStr, url: url.getStr, title: title, time: t.getBiggestInt)
  except CatchableError as e:
    stderr.writeLine "webby: could not read ", path, ": ", e.msg
  let cutoff = nowMs() - keepForMs
  entries.setLen 0
  for e in byId.values:
    if e.time >= cutoff: entries.add e
  entries.sort(proc (a, b: HistoryEntry): int = cmp(a.time, b.time))
  # Drop expired visits and superseded title lines once they make up a good part of the file.
  if lines > 200 and lines > entries.len * 2: rewrite()

proc ensureLoaded*() =
  if not loaded: merge()

proc reload*() =
  ## Reads the file again, picking up visits other windows have added since.
  merge()
  notify()

proc count*(): int = (ensureLoaded(); entries.len)

proc records*(url: string): bool =
  ## Whether visits to `url` are recorded: web pages and local files, not about: pages, data: URLs and the like.
  try: parseUri(url).scheme.toLowerAscii in ["http", "https", "file"] except CatchableError: false

proc samePage*(a, b: string): bool =
  ## Whether `a` and `b` are the same page, ignoring a trailing slash.
  proc noSlash(s: string): string = (if s.endsWith('/'): s[0 ..< ^1] else: s)
  a == b or noSlash(a) == noSlash(b)

proc contains(e: HistoryEntry): bool =
  for x in entries:
    if x == e: return true

proc setTitle*(e: HistoryEntry, title: string) =
  ## The page's title arrived (or changed) after the visit was recorded.
  if incognito or e.title == title or not contains(e): return
  e.title = title
  append(e)
  notify()

proc base36(n: int64): string =
  const digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  var v = n
  if v == 0: return "0"
  while v > 0:
    result.insert($digits[v mod 36], 0)
    v = v div 36

proc record*(url, title: string): HistoryEntry =
  ## Records a visit to `url` and returns it, or nil when it isn't recorded (see `records`, incognito).
  if incognito or not records(url): return nil
  ensureLoaded()
  let now = nowMs()
  # The same page again within a few seconds (a redirect, the page settling its address) is the same visit.
  if entries.len > 0 and samePage(entries[^1].url, url) and now - entries[^1].time < 10000:
    if title.len > 0: setTitle(entries[^1], title)
    return entries[^1]
  result = HistoryEntry(id: base36(now) & base36(getpid().int64) & base36(idCounter), url: url, title: title, time: now)
  inc idCounter
  entries.add result
  append(result)
  notify()

proc remove*(gone: seq[HistoryEntry]) =
  var ids: HashSet[string]
  for e in gone: ids.incl e.id
  # Keep what other windows added since this one last read the file.
  merge()
  let before = entries.len
  entries.keepItIf(it.id notin ids)
  if entries.len == before: return
  rewrite()
  notify()

proc clear*(sinceMs: int64 = 0) =
  ## Deletes the visits made since `sinceMs`, or everything when it's 0 (Clear browsing data).
  if sinceMs == 0:
    loaded = true
    entries.setLen 0
  else:
    merge()
    entries.keepItIf(it.time < sinceMs)
  rewrite()
  notify()

proc words(q: string): seq[string] = q.toLowerAscii.splitWhitespace

proc matches(url, title: string, words: seq[string]): bool =
  let hay = url.toLowerAscii & " " & title.toLowerAscii
  for w in words:
    if w notin hay: return false
  true

proc search*(query: string): seq[HistoryEntry] =
  ## Visits whose title or address contain every word of `query`, newest first.
  ensureLoaded()
  let ws = words(query)
  for i in countdown(entries.high, 0):
    if ws.len == 0 or matches(entries[i].url, entries[i].title, ws): result.add entries[i]

proc bare(url: string): string =
  ## The address as typed: no scheme, no "www.", no trailing slash.
  result = url.toLowerAscii
  let s = result.find("://")
  if s > 0 and result[0] in {'a'..'z'} and result[0 ..< s].allCharsInSet({'a'..'z', '0'..'9', '+', '.', '-'}):
    result = result[s + 3 .. ^1]
  if result.startsWith("www."): result = result[4 .. ^1]
  if result.endsWith("/"): result.setLen result.len - 1

proc suggest*(input: string, limit = 6): seq[HistorySuggestion] =
  ## Pages for the address bar: the best few matches, one per address. Pages whose address (without "https://www.")
  ## starts with the input come first, then the most and most recently visited.
  ensureLoaded()
  let ws = words(input)
  if ws.len == 0: return
  var pages: OrderedTable[string, HistorySuggestion]
  for e in entries:
    let had = e.url in pages
    let page = pages.getOrDefault(e.url)
    pages[e.url] = HistorySuggestion(url: e.url, title: if e.title.len > 0 or not had: e.title else: page.title,
      visits: page.visits + 1, lastVisit: e.time)
  let now = nowMs()
  let typed = input.strip.toLowerAscii
  var scored: seq[(float, HistorySuggestion)]
  for s in pages.values:
    if not matches(s.url, s.title, ws): continue
    let ageDays = (now - s.lastVisit).float / 86_400_000.0
    var value = s.visits.float / (1 + ageDays / 7)
    let b = bare(s.url)
    if b.startsWith(typed):
      value += 1000
      # The site itself before its pages.
      if b.len - typed.len < 2 or '/' notin b[typed.len .. ^1]: value += 500
    elif typed in b:
      value += 100
    scored.add((value, s))
  scored.sort(proc (a, b: (float, HistorySuggestion)): int =
    if a[0] != b[0]: cmp(b[0], a[0]) else: cmp(a[1].url.len, b[1].url.len))
  for i in 0 ..< min(limit, scored.len): result.add scored[i][1]
