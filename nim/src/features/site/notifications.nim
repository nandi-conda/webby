## Web notifications, which Ladybird doesn't have: the page script (scripts/notifications.js)
## provides window.Notification, asks through the site permission prompt and hands notifications to
## org.freedesktop.Notifications on the session bus, or on Android to the app's Java host (WebbyHost notify,
## NotificationManager), whose taps and dismissals come back as host events.

import std/[strutils, tables]
import ../../browser
import permissions
when not defined(android): import gio

const notificationScript = staticRead("../../scripts/notifications.js")

when not defined(android):
  const
    service = "org.freedesktop.Notifications"
    servicePath = "/org/freedesktop/Notifications"

type Shown = object
  tab: Tab
  pageId: int
  origin: string
  onClick, onClosed: proc ()   ## a service worker's notification (features/site/push.nim; no tab)

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
  if s.onClick != nil:
    s.onClick()
    return
  if s.tab.closed: return
  activateTab(s.tab)
  when not defined(android): gtk_window_present(window)
  callPage(s.tab, "click(" & $s.pageId & ")")
  callPage(s.tab, "closed(" & $s.pageId & ")")

proc closedBySystem(id: uint32) =
  if id notin shown: return
  let s = shown[id]
  shown.del id
  if s.onClosed != nil: s.onClosed()
  elif s.tab != nil: callPage(s.tab, "closed(" & $s.pageId & ")")

when defined(android):
  var nextSystemId = 1'u32

  proc systemShow(replace: uint32, title, text: string, done: proc (id: uint32)) =
    let id = if replace != 0: replace else: (inc nextSystemId; nextSystemId - 1)
    if hostCall("notify", $(%*{"id": id, "title": title, "text": text})) == "ok": done(id)
    else: stderr.writeLine "webby: could not show a notification"

  proc systemClose(id: uint32) = discard hostCall("notificationClose", $id)

  proc onHostEvent(name, data: string) =
    case name
    of "notificationClick": (try: clicked(uint32(parseInt(data))) except ValueError: discard)
    of "notificationClosed": (try: closedBySystem(uint32(parseInt(data))) except ValueError: discard)
    else: discard

else:
  proc listen() =
    if listening: return
    listening = true
    discard subscribe(busSession, service, service, "ActionInvoked", servicePath,
      proc (p: string, v: GVariant) = clicked(uint32At(v, 0)))
    discard subscribe(busSession, service, service, "NotificationClosed", servicePath,
      proc (p: string, v: GVariant) = closedBySystem(uint32At(v, 0)))

  proc systemShow(replace: uint32, title, text: string, done: proc (id: uint32)) =
    listen()
    let actions = g_variant_builder_new(variantType("as"))
    g_variant_builder_add(actions, "s", "default")
    g_variant_builder_add(actions, "s", "Open")
    let hints = g_variant_builder_new(variantType("a{sv}"))
    g_variant_builder_add(hints, "{sv}", "desktop-entry", g_variant_new_string("webby"))
    let params = g_variant_new("(susssasa{sv}i)", "Webby", replace, "webby", title.cstring, text.cstring, actions,
      hints, -1.cint)
    g_variant_builder_unref(actions)
    g_variant_builder_unref(hints)
    call(busSession, service, servicePath, service, "Notify", params, proc (r: GVariant, e: string) =
      if r == nil: stderr.writeLine "webby: could not show a notification: ", e
      else: done(uint32At(r, 0)))

  proc systemClose(id: uint32) =
    call(busSession, service, servicePath, service, "CloseNotification", g_variant_new("(u)", id))

proc show(origin, tag, title, body: string, entry: Shown, done: proc (id: uint32) = nil) =
  var site = origin[origin.find("://") + 3 .. ^1]
  if site.startsWith("www."): site = site[4 .. ^1]
  let key = if tag.len > 0: origin & " " & tag else: ""
  # Like Chrome, say which site it came from.
  let text = if body.len == 0: site else: body & "\n" & site
  systemShow(tagged.getOrDefault(key, 0'u32), title, text, proc (id: uint32) =
    if key.len > 0: tagged[key] = id
    shown[id] = entry
    if done != nil: done(id))

proc notify*(origin, tag, title, body: string, onClick, onClosed: proc (), done: proc (id: uint32) = nil) =
  ## Shows a notification for `origin` that belongs to no page (a service worker's): `onClick` runs when it's
  ## clicked, `onClosed` when it's dismissed. `done` gets its id for closeNotification. A later one with the same
  ## tag replaces it.
  show(origin, tag, title, body, Shown(origin: origin, onClick: onClick, onClosed: onClosed), done)

proc closeNotification*(id: uint32) =
  if id in shown:
    shown.del id
    systemClose(id)

proc closePage(t: Tab, pageId: int) =
  for id, s in shown:
    if s.tab == t and s.pageId == pageId:
      shown.del id
      systemClose(id)
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
      show(origin, m{"tag"}.getStr, m{"title"}.getStr, m{"body"}.getStr, Shown(tab: t, pageId: id, origin: origin))
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
  when defined(android): hostEventHooks.add onHostEvent
  pageScriptHooks.add script
  pageMessageHooks.add onMessage
  tabStateHooks.add onTabState
  tabClosedHooks.add proc (t: Tab) =
    var gone: seq[uint32]
    for id, s in shown:
      if s.tab == t: gone.add id
    for id in gone: shown.del id
  storeListeners.add refreshPages
