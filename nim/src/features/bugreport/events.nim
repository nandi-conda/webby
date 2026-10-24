## What a bug report captured from its pages (scripts/bug_capture.js) and from webby itself, all stamped in
## wall-clock ms so report.html can line it up with the video.

import std/[algorithm, json, sequtils, sets, strutils, tables, unicode, uri]

type
  Captured* = ref object
    console*, network*, actions*: seq[JsonNode]  ## page entries, each with "page" (its URL) and "tab" added
    seen: HashSet[string]                        ## "doc/seq" and resource keys already kept
    since*: Table[string, int]                   ## per page document: the last seq taken
    navigations*: seq[JsonNode]                  ## {t, url, title, tab, how}: loads and tab switches webby saw
    engine*: seq[JsonNode]                       ## {t, process, pid, level, text}: the engine's log (enginelog.nim)
    system*: seq[JsonNode]                       ## {t, text, ...}: webby's memory and CPU (system.nim)
    state*: JsonNode                             ## {t, text, tabs, settings, ...}: webby when the report began

const keep = 2000

proc newCaptured*(): Captured = Captured()

proc trim(list: var seq[JsonNode]) =
  if list.len > keep: list.delete(0 ..< list.len - keep)

proc addDump*(c: Captured, dump: JsonNode, tab: int) =
  ## Takes in what a page's __webbyBug.dump() sent, skipping entries already taken.
  let doc = dump{"doc"}.getStr
  let page = dump{"url"}.getStr
  for (name, list) in [("console", addr c.console), ("network", addr c.network), ("actions", addr c.actions)]:
    for e in dump{name}.getElems:
      let key = doc & "/" & $e{"seq"}.getInt
      if e{"pending"}.getBool or key in c.seen: continue   # a request still waiting comes again once it's done
      c.seen.incl key
      e["page"] = %page
      e["tab"] = %tab
      list[].add e
  for e in dump{"resources"}.getElems:
    let key = "r/" & e{"url"}.getStr & "/" & $e{"t"}.getBiggestInt
    if key in c.seen: continue
    c.seen.incl key
    e["page"] = %page
    e["tab"] = %tab
    c.network.add e
  c.since[doc] = max(c.since.getOrDefault(doc), dump{"seq"}.getInt)
  c.console.trim
  c.network.trim
  c.actions.trim

proc addNavigation*(c: Captured, t: int64, url, title: string, tab: int, how: string) =
  if c.navigations.len > 0 and c.navigations[^1]{"url"}.getStr == url and c.navigations[^1]{"tab"}.getInt == tab:
    return
  c.navigations.add %*{"t": t, "kind": "navigation", "url": url, "title": title, "tab": tab, "how": how}

proc byTime(a, b: JsonNode): int = cmp(a{"t"}.getBiggestInt, b{"t"}.getBiggestInt)

proc sorted*(c: Captured): tuple[console, network, actions: seq[JsonNode]] =
  (c.console.sorted(byTime), c.network.sorted(byTime), (c.actions & c.navigations).sorted(byTime))
