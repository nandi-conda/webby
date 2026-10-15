## Find in page on Android (src/features/find.nim on the desktop): Java's find bar runs the find.* commands, and
## the state Java gets carries "find": [active match (1-based, 0 for none), match count] while a search is on.
## Ladybird searches when the runtime has webby_view_find; older ones run the page script in
## app/lib/src/find_in_page.dart.

import std/strutils
import ../core

const findScript = block:
  let dart = staticRead("../../../../app/lib/src/find_in_page.dart")
  let start = dart.find("r'''") + 4
  dart[start ..< dart.find("'''", start)]

var
  searching = -1            ## the tab id being searched (-1 for none)
  scriptResult = (0, 0)     ## the page script's last report

proc script(t: Tab, call: string) =
  t.runJs(findScript.replace("__WEBBY_FIND_PREFIX__", $(%t.messagePrefix)) & call)

proc findCmd(args: JsonNode): JsonNode =
  let t = current()
  if t == nil: return nil
  let query = args{"query"}.getStr
  let caseSensitive = args{"caseSensitive"}.getBool
  searching = t.id
  scriptResult = (0, 0)
  if hasNativeFind(): webby_view_find(t.view, query.cstring, caseSensitive.cint)
  else: script(t, "window.__webbyFind.find(" & $(%query) & ", " & $caseSensitive & ");")
  wake()
  sendState()
  nil

proc stepCmd(forward: bool): proc (args: JsonNode): JsonNode =
  result = proc (args: JsonNode): JsonNode =
    let t = current()
    if t == nil or t.id != searching: return nil
    if hasNativeFind():
      if forward: webby_view_find_next(t.view) else: webby_view_find_previous(t.view)
    else: script(t, "window.__webbyFind." & (if forward: "next" else: "previous") & "();")
    wake()
    nil

proc endFind() =
  for t in tabs:
    if t.id == searching:
      if hasNativeFind(): webby_view_find_end(t.view)
      else: t.runJs("window.__webbyFind && window.__webbyFind.end();")
  searching = -1
  wake()
  sendState()

proc install*() =
  pageMessageHooks.add proc (t: Tab, msg: JsonNode): bool =
    if msg{"type"}.getStr != "find": return false
    if t.id == searching:
      scriptResult = (msg{"current"}.getInt, msg{"total"}.getInt)
      sendState()
    true
  activeTabHooks.add proc (t: Tab) =
    if searching >= 0 and t.id != searching: endFind()
  tabClosedHooks.add proc (t: Tab) =
    if t.id == searching: searching = -1
  stateHooks.add proc (t: Tab, state: JsonNode) =
    if t == nil or t.id != searching: return
    state["find"] = if hasNativeFind(): %[int(webby_view_find_current(t.view)), int(webby_view_find_total(t.view))]
                    else: %[scriptResult[0], scriptResult[1]]
  commands["find.find"] = findCmd
  commands["find.next"] = stepCmd(true)
  commands["find.previous"] = stepCmd(false)
  commands["find.end"] = proc (args: JsonNode): JsonNode = (endFind(); nil)
