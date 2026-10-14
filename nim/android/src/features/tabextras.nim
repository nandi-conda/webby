## Tabs on Android beyond the core: saved sessions (src/features/tabs/sessions.nim on the desktop, the same
## sessions.json), pinned tabs, window.open tabs in a process of their own (tabs/newtabs.nim), and the page menu's
## extras (Inspect with eruda, as context_menu.dart does).

import std/[sequtils, strutils]
import ../core
import ../../../src/features/tabs/store

proc dartString(dart, head: string): string =
  let start = dart.find(head) + head.len
  result = dart[start ..< dart.find("''';", start)]
  result = result.replace("\\\\", "\x01").replace("\\$", "$").replace("\x01", "\\")

const newTabScript = dartString(staticRead("../../../../app/lib/src/tabs/new_tab_requests.dart"),
  "String newTabPageScript(String prefix) => '''")
const contextMenuDart = staticRead("../../../../app/lib/src/context_menu.dart")
const inspectScript = dartString(contextMenuDart, "String inspectScriptWith(String erudaSource) => '''").replace(
  "$erudaSource", staticRead("../../../../app/assets/eruda/eruda.js"))

# ---------------------------------------------------------------------------------------------------------------
# Sessions

proc openTabsAsSession(): seq[DeviceTab] =
  for t in tabs: result.add DeviceTab(title: t.title, url: t.url)

proc isBlank(t: Tab): bool = t == nil or t.url.len == 0 or t.url == homePage

proc restore(urls: seq[string], front = 0) =
  ## Opens a session's tabs after the current one (a blank current tab takes the first) and shows its front tab.
  if urls.len == 0: return
  let cur = current()
  var at = if isBlank(cur): active else: active + 1
  var frontTab: Tab
  for i, url in urls:
    var t: Tab
    if i == 0 and isBlank(cur) and cur != nil:
      t = cur
      webby_view_load(t.view, url.cstring)
    else:
      t = openTab(url, focus = false, at = at)
    inc at
    if i == front: frontTab = t
  if frontTab != nil: activate(tabs.find(frontTab))
  saveTabsSoon()
  wake()

proc sessionJson(s: SavedSession): JsonNode =
  result = %*{"id": s.id, "name": s.name, "created": sessionCreated(s.savedAt), "active": s.active, "tabs": []}
  for t in s.tabs: result["tabs"].add %*{"title": t.title, "url": t.url}

proc find(id: string): SavedSession =
  for s in sessions():
    if s.id == id: return s

proc listSessions(args: JsonNode): JsonNode =
  result = %*{"error": sessionLoadError, "sessions": []}
  for s in sessions(): result["sessions"].add sessionJson(s)
  var n = 0
  for t in tabs:
    if isSessionUrl(t.url): inc n
  result["openTabs"] = %n
  result["defaultName"] = %defaultSessionName()

proc saveOpen(args: JsonNode): JsonNode =
  ## {name, closeAll}: saves the open tabs; with closeAll, closes them (pinned ones stay) to a blank tab.
  let s = saveSession(openTabsAsSession(), args{"name"}.getStr, max(active, 0))
  if s == nil: return %false
  if args{"closeAll"}.getBool:
    for i in countdown(tabs.high, 0):
      if not tabs[i].pinned and tabs.len > 1: closeTab(i)
    if not tabs.anyIt(not it.pinned): openTab(homePage)
    elif not isBlank(current()):
      let t = tabs[tabs.high]
      if not t.pinned: webby_view_load(t.view, homePage)
  %true

proc restoreCmd(args: JsonNode): JsonNode =
  ## {id, index (-1: all)}
  let s = find(args{"id"}.getStr)
  if s == nil: return nil
  let i = args{"index"}.getInt(-1)
  if i in 0 ..< s.tabs.len: restore(@[s.tabs[i].url])
  else:
    var urls: seq[string]
    for t in s.tabs: urls.add t.url
    restore(urls, s.active)
  nil

proc install*() =
  pageScriptHooks.add proc (t: Tab): string =
    newTabScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))
  pageMessageHooks.add proc (t: Tab, msg: JsonNode): bool =
    if msg{"type"}.getStr != "openTab": return false
    let url = msg{"url"}.getStr
    if url.startsWith("http://") or url.startsWith("https://"):
      let i = tabs.find(t)
      discard openTab(url, true, if i >= 0: i + 1 else: -1)
      saveTabsSoon()
    true
  sessionListeners.add proc () = event("sessionsChanged")
  commands["sessions.list"] = listSessions
  commands["sessions.saveOpen"] = saveOpen
  commands["sessions.restore"] = restoreCmd
  commands["sessions.rename"] = proc (args: JsonNode): JsonNode =
    let s = find(args{"id"}.getStr)
    if s != nil: renameSession(s, args{"name"}.getStr)
  commands["sessions.delete"] = proc (args: JsonNode): JsonNode =
    let s = find(args{"id"}.getStr)
    if s != nil: deleteSession(s)
  commands["sessions.removeTab"] = proc (args: JsonNode): JsonNode =
    let s = find(args{"id"}.getStr)
    if s != nil: discard removeSessionTab(s, args{"index"}.getInt)
  commands["sessions.deleteAll"] = proc (args: JsonNode): JsonNode = (deleteAllSessions(); nil)
  commands["tabs.pin"] = proc (args: JsonNode): JsonNode =
    setPinned(args{"index"}.getInt, args{"on"}.getBool)
  commands["tabs.closeOthers"] = proc (args: JsonNode): JsonNode =
    ## Closes every unpinned tab except `index`.
    let keep = tabs[clamp(args{"index"}.getInt, 0, tabs.high)]
    for i in countdown(tabs.high, 0):
      if tabs[i] != keep and not tabs[i].pinned: closeTab(i)
    activate(tabs.find(keep))
  commands["inspect"] = proc (args: JsonNode): JsonNode =
    let t = current()
    if t != nil: t.runJs(inspectScript)
