## Web notifications (app/lib/src/notifications.dart), which Ladybird doesn't have: the Dart app's page script
## provides window.Notification, asks through the site permission prompt and hands notifications to
## org.freedesktop.Notifications on the session bus.

import std/[strutils, tables]
import ../../browser
import gio, permissions

# The Dart app's script, read at compile time so both front ends run the same JS.
const notificationScript = block:
  let dart = staticRead("../../../../app/lib/src/notifications.dart")
  let start = dart.find("String notificationPageScript")
  let first = dart.find("'''", start) + 3
  dart[first ..< dart.find("''';", first)]

const
  service = "org.freedesktop.Notifications"
  servicePath = "/org/freedesktop/Notifications"

type Shown = object
  tab: Tab
  pageId: int
  origin: string

var
  shown: Table[uint32, Shown]     ## system id to the page's notification
  tagged: Table[string, uint32]   ## "origin tag" to system id, so a notification with an earlier tag replaces it
  listening = false

proc pageState(t: Tab, origin: string): string =
  case permissionFor(t, origin, "notifications")
  of allow: "granted"
  of blocked: "denied"
  of ask: "default"

proc script(t: Tab): string =
  ## The page script for the tab's page as it is now ("" on pages that can't have notifications).
  let origin = secureOrigin(t.url)
  if origin.len == 0: return ""
  notificationScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))
    .replace("${jsonEncode(permission)}", $(%pageState(t, origin)))

proc callPage(t: Tab, js: string) =
  if not t.closed: t.runJs("window.__webbyNotifications && window.__webbyNotifications." & js)

proc clicked(id: uint32) =
  if id notin shown: return
  let s = shown[id]
  shown.del id
  if s.tab.closed: return
  activateTab(s.tab)
  gtk_window_present(window)
  callPage(s.tab, "click(" & $s.pageId & ")")
  callPage(s.tab, "closed(" & $s.pageId & ")")

proc closedBySystem(id: uint32) =
  if id notin shown: return
  let s = shown[id]
  shown.del id
  callPage(s.tab, "closed(" & $s.pageId & ")")

proc listen() =
  if listening: return
  listening = true
  discard subscribe(busSession, service, service, "ActionInvoked", servicePath,
    proc (p: string, v: GVariant) = clicked(uint32At(v, 0)))
  discard subscribe(busSession, service, service, "NotificationClosed", servicePath,
    proc (p: string, v: GVariant) = closedBySystem(uint32At(v, 0)))

proc show(t: Tab, origin: string, pageId: int, tag, title, body: string) =
  listen()
  var site = origin[origin.find("://") + 3 .. ^1]
  if site.startsWith("www."): site = site[4 .. ^1]
  let key = if tag.len > 0: origin & " " & tag else: ""
  let actions = g_variant_builder_new(variantType("as"))
  g_variant_builder_add(actions, "s", "default")
  g_variant_builder_add(actions, "s", "Open")
  let hints = g_variant_builder_new(variantType("a{sv}"))
  g_variant_builder_add(hints, "{sv}", "desktop-entry", g_variant_new_string("webby"))
  # Like Chrome, say which site it came from.
  let text = if body.len == 0: site else: body & "\n" & site
  let params = g_variant_new("(susssasa{sv}i)", "Webby", tagged.getOrDefault(key, 0'u32), "webby", title.cstring,
    text.cstring, actions, hints, -1.cint)
  g_variant_builder_unref(actions)
  g_variant_builder_unref(hints)
  call(busSession, service, servicePath, service, "Notify", params, proc (r: GVariant, e: string) =
    if r == nil:
      stderr.writeLine "webby: could not show a notification: ", e
      return
    let id = uint32At(r, 0)
    if key.len > 0: tagged[key] = id
    shown[id] = Shown(tab: t, pageId: pageId, origin: origin))

proc closePage(t: Tab, pageId: int) =
  for id, s in shown:
    if s.tab == t and s.pageId == pageId:
      shown.del id
      call(busSession, service, servicePath, service, "CloseNotification", g_variant_new("(u)", id))
      return

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"notif"): return false
  let m = try: parseJson(text) except CatchableError: return false
  let origin = secureOrigin(t.url)
  if origin.len == 0: return true
  let id = m{"id"}.getInt
  case m{"type"}.getStr
  of "notificationPermission":
    askPermission(t, origin, "notifications", proc (allowed: bool) =
      if t.closed or secureOrigin(t.url) != origin: return
      let answer = if allowed: "granted" elif pageState(t, origin) == "denied": "denied" else: "default"
      callPage(t, "resolve(" & $id & ", " & $(%answer) & ")"))
  of "notify":
    if pageState(t, origin) == "granted":
      show(t, origin, id, m{"tag"}.getStr, m{"title"}.getStr, m{"body"}.getStr)
  of "notificationClose": closePage(t, id)
  else: return false
  true

proc refreshPages() =
  ## Tells every page its site's answer after a change (the script only updates the permission when it's in).
  for t in tabs:
    let js = script(t)
    if js.len > 0: t.runJs(js)

proc onTabState(t: Tab) =
  # A page of another site starts with none of the tab's notifications.
  let origin = secureOrigin(t.url)
  var gone: seq[uint32]
  for id, s in shown:
    if s.tab == t and s.origin != origin: gone.add id
  for id in gone: shown.del id

proc install*() =
  pageScriptHooks.add script
  pageMessageHooks.add onMessage
  tabStateHooks.add onTabState
  tabClosedHooks.add proc (t: Tab) =
    var gone: seq[uint32]
    for id, s in shown:
      if s.tab == t: gone.add id
    for id in gone: shown.del id
  storeListeners.add refreshPages
