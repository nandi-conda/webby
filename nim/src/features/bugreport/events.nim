## What a bug report captured from its pages (scripts/bug_capture.js), and the same as Jam events: the rrweb-style
## array Jam's recorder makes (a Meta event, then Plugin events for console and network and Custom events for user
## actions and navigations, all stamped in wall-clock ms), which Jam lines up with the video by their timestamps.

import std/[algorithm, json, sequtils, sets, strutils, tables, unicode, uri]

type
  Captured* = ref object
    console*, network*, actions*: seq[JsonNode]  ## page entries, each with "page" (its URL) and "tab" added
    seen: HashSet[string]                        ## "doc/seq" and resource keys already kept
    since*: Table[string, int]                   ## per page document: the last seq taken
    navigations*: seq[JsonNode]                  ## {t, url, title, tab, how}: loads and tab switches webby saw

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

proc errorCount*(c: Captured): tuple[console, network: int] =
  for e in c.console:
    if e{"level"}.getStr == "error": inc result.console
  for e in c.network:
    let s = e{"status"}.getInt
    if s >= 400 or (e{"status"} != nil and s == 0): inc result.network

# ---------------------------------------------------------------------------------------------------------------
# As Jam events

proc pageContext(e: JsonNode, url: string, tab: int) =
  e["tabInfo"] = %*{"id": tab, "url": url, "title": url}
  try:
    let u = parseUri(url)
    if u.scheme in ["http", "https"]:
      e["origin"] = %(u.scheme & "://" & u.hostname & (if u.port.len > 0: ":" & u.port else: ""))
      e["hostname"] = %u.hostname
  except CatchableError: discard

proc initiator(e: JsonNode): string =
  case e{"kind"}.getStr
  of "fetch": "fetch"
  of "xhr": "xmlhttprequest"
  of "document": "navigation"
  of "": "other"
  else: e{"kind"}.getStr

proc networkEvent(e: JsonNode): JsonNode =
  let t = e{"t"}.getBiggestInt
  let location = case e{"kind"}.getStr
    of "fetch": "HostFetch"
    of "xhr": "HostXHR"
    else: "BackgroundRequestLifecycle"
  var details = %*{"method": e{"method"}.getStr("GET")}
  if e{"status"} != nil: details["status"] = e{"status"}
  if e{"statusText"}.getStr.len > 0: details["statusText"] = e{"statusText"}
  elif e{"error"}.getStr.len > 0: details["statusText"] = e{"error"}
  for (src, dst) in [("requestHeaders", "requestHeaders"), ("responseHeaders", "responseHeaders"),
                     ("requestBody", "requestBody"), ("responseBody", "responseBody")]:
    if e{src} != nil: details[dst] = e{src}
  if e{"type"}.getStr.len > 0: details["responseMimeType"] = e{"type"}
  if e{"size"} != nil: details["responseBodySize"] = e{"size"}
  result = %*{"type": 6, "timestamp": t, "data": {"plugin": "jam/network@1", "payload": {
    "entry": {"name": e{"url"}.getStr, "initiatorType": initiator(e), "startTime": 0, "absoluteStart": t,
              "duration": e{"duration"}.getInt, "transferSize": e{"size"}.getInt},
    "timeOrigin": t, "complete": true,
    "eventSources": [{"location": location, "point": "Start"}, {"location": location, "point": "End"}],
    "fetchDetails": details}}}

proc consoleEvent(e: JsonNode): JsonNode =
  # Jam's console shows each argument as JSON text, as Chrome's DevTools protocol gives them.
  var args = newJArray()
  for a in e{"args"}.getElems: args.add %($(%a.getStr))
  %*{"type": 6, "timestamp": e{"t"}.getBiggestInt, "data": {"plugin": "rrweb/console@1", "payload": {
    "level": e{"level"}.getStr("log"), "payload": args, "trace": e{"trace"}}}}

proc actionEvent(e: JsonNode): JsonNode =
  let t = e{"t"}.getBiggestInt
  var payload = %*{"isTrusted": true, "composed": true, "targetsJamUi": false, "originalTimestamp": t,
                   "step": "output"}
  let target = if e{"target"} != nil and e{"target"}.kind == JObject: e{"target"} else: %*{"attributes": {}}
  case e{"kind"}.getStr
  of "click":
    payload["device"] = %"mouse"
    payload["type"] = %"click"
    payload["modifiers"] = e{"modifiers"}
    payload["x"] = e{"x"}
    payload["y"] = e{"y"}
    payload["target"] = target
  of "input", "key":
    let typed = if e{"kind"}.getStr == "input": e{"text"}.getStr else: e{"key"}.getStr
    var keys = newJArray()
    if e{"kind"}.getStr == "input":
      for r in typed.runes: keys.add %*{"key": $r, "code": $r, "repeat": false, "type": "keydown"}
    else: keys.add %*{"key": typed, "code": typed, "repeat": false, "type": "keydown"}
    payload["device"] = %"keyboard"
    payload["type"] = %"keyword"
    payload["isInputLike"] = %(e{"kind"}.getStr == "input")
    payload["events"] = keys
    var t2 = target.copy
    if e{"kind"}.getStr == "input" and t2{"attributes"} != nil: t2["attributes"]["value"] = %typed
    payload["target"] = t2
  of "navigation":
    return %*{"type": 5, "jamType": "navigationEvent", "timestamp": t, "data": {"tag": "", "payload": {
      "eventSource": (if e{"how"}.getStr in ["load", "tab"]: "onCommitted" else: "onHistoryStateUpdated"),
      "url": e{"url"}.getStr, "transitionType": "link", "transitionQualifiers": [], "originalTimestamp": t,
      "step": "output", "tabId": e{"tab"}.getInt}}}
  else: return nil
  %*{"type": 5, "jamType": "interactivityEvent", "timestamp": t, "data": {"tag": "", "payload": payload}}

proc jamEvents*(c: Captured, startedAt: int64, href: string, viewport: tuple[width, height: int],
                video: bool): JsonNode =
  ## The events for a Jam. A video's timeline starts at the Meta event, so for a video that is `startedAt` and
  ## nothing earlier goes along; a screenshot keeps everything.
  let (console, network, actions) = c.sorted
  var events: seq[JsonNode]
  for e in network:
    let ev = networkEvent(e)
    ev.pageContext(e{"page"}.getStr, e{"tab"}.getInt)
    events.add ev
  for e in console:
    let ev = consoleEvent(e)
    ev.pageContext(e{"page"}.getStr, e{"tab"}.getInt)
    events.add ev
  for e in actions:
    let ev = actionEvent(e)
    if ev == nil: continue
    ev.pageContext(e{"page"}.getStr(e{"url"}.getStr), e{"tab"}.getInt)
    events.add ev
  events.sort(proc (a, b: JsonNode): int = cmp(a{"timestamp"}.getBiggestInt, b{"timestamp"}.getBiggestInt))
  if video: events.keepItIf(it{"timestamp"}.getBiggestInt >= startedAt)
  result = newJArray()
  if events.len == 0: return
  let first = if video: startedAt else: min(startedAt, events[0]{"timestamp"}.getBiggestInt)
  result.add %*{"type": 4, "timestamp": first, "data": {"href": href, "width": viewport.width, "height": viewport.height}}
  for e in events: result.add e
