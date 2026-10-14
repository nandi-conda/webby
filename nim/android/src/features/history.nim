## History on Android (src/features/history.nim on the desktop): every page a tab shows is a visit in the profile's
## history.jsonl (features/history/store.nim, the Flutter app's format); the History screen lists them by day with
## search and delete, and "Clear browsing data" clears the engine's data and the history.

import std/[strutils, tables, times, uri]
import ../core
import ../../../src/features/history/store
import ../../../src/features/summarize/cache
import omnibox

const
  maxRows = 400
  months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
    "November", "December"]
  weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

var visits: Table[int, tuple[url: string, visit: HistoryEntry]]  ## per tab id: the address last recorded

proc recordVisit(t: Tab) =
  if t.url.len == 0: return
  let last = visits.getOrDefault(t.id)
  if t.url != last.url:
    visits[t.id] = (t.url, record(t.url, t.title))
  elif last.visit != nil and t.title.len > 0:
    setTitle(last.visit, t.title)

proc localTime(ms: int64): DateTime = fromUnix(ms div 1000).local

proc dayLabel(t: DateTime, now: DateTime): string =
  let date = weekdays[t.weekday.ord] & ", " & months[t.month.ord - 1] & " " & $t.monthday & ", " & $t.year
  let today = dateTime(now.year, now.month, now.monthday, zone = local())
  let that = dateTime(t.year, t.month, t.monthday, zone = local())
  let daysAgo = (today - that).inHours div 24
  if daysAgo == 0: "Today - " & date elif daysAgo == 1: "Yesterday - " & date else: date

proc site(url: string): string =
  try:
    result = parseUri(url).hostname
    if result.startsWith("www."): result = result[4 .. ^1]
  except CatchableError: discard

proc list(args: JsonNode): JsonNode =
  ## {query} -> {rows: [{heading} | {ids, url, title, site, time, count}], more}
  reload()
  let found = search(args{"query"}.getStr)
  var rows = newJArray()
  let now = now()
  var day = ""
  var i = 0
  while i < found.len and rows.len < maxRows:
    let e = found[i]
    let t = localTime(e.time)
    let label = dayLabel(t, now)
    if label != day:
      day = label
      rows.add %*{"heading": label}
    var ids = @[e.id]
    inc i
    while i < found.len and samePage(found[i].url, e.url) and dayLabel(localTime(found[i].time), now) == day:
      ids.add found[i].id
      inc i
    rows.add %*{"ids": ids, "url": e.url, "title": e.label, "site": site(e.url),
      "time": align($t.hour, 2, '0') & ":" & align($t.minute, 2, '0'), "count": ids.len}
  %*{"rows": rows, "more": i < found.len, "empty": found.len == 0}

proc removeIds(args: JsonNode): JsonNode =
  var ids: seq[string]
  for id in args{"ids"}.getElems: ids.add id.getStr
  var gone: seq[HistoryEntry]
  for e in search(""):
    if e.id in ids: gone.add e
  store.remove(gone)
  nil

proc sinceMs(args: JsonNode): int64 =
  let secs = args{"seconds"}.getBiggestInt(0)
  if secs <= 0: 0'i64 else: nowMs() - secs * 1000

proc clearHistory(args: JsonNode): JsonNode =
  store.clear(sinceMs(args))
  nil

proc clearBrowsingData(args: JsonNode): JsonNode =
  ## {seconds (0 = all time), siteData, cache, history}
  let since = sinceMs(args)
  var what = 0
  if args{"siteData"}.getBool: what = what or browsingDataSiteData
  if args{"cache"}.getBool: what = what or browsingDataCache
  if args{"history"}.getBool: what = what or browsingDataHistory
  if what != 0:
    webby_clear_browsing_data(since, what.cint)
    if (what and browsingDataHistory) != 0:
      store.clear(since)
      clearSummaries(since)
  nil

proc install*() =
  tabStateHooks.add recordVisit
  tabClosedHooks.add proc (t: Tab) = visits.del t.id
  suggestionProviders.add proc (text: string): seq[Suggestion] =
    for s in suggest(text): result.add Suggestion(title: s.title, url: s.url, kind: "history")
  commands["history.list"] = list
  commands["history.remove"] = removeIds
  commands["history.clear"] = clearHistory
  commands["clearBrowsingData"] = clearBrowsingData
