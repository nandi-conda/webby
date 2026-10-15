## Site permissions, notifications and location on Android (src/features/site/* on the desktop): the same
## site_permissions.json answers (site/permstore.nim); requests wait in a bar above the page ("permissionAsk" events,
## answered with "permissions.answer"); notifications come from the Dart app's page script and are shown by Java's
## NotificationManager; navigator.geolocation gets fixes from Android's LocationManager while a page wants them.
## The Site settings sheet sets a site's permissions and deletes its data.

import std/[math, strutils]
import ../core
import ../../../src/features/site/permstore

const notificationScript = block:
  let dart = staticRead("../../../../app/lib/src/notifications.dart")
  let start = dart.find("String notificationPageScript")
  let first = dart.find("'''", start) + 3
  dart[first ..< dart.find("''';", first)]

type Ask = ref object
  tab: Tab
  engineId: int64      ## the engine's request id, or -1 for one from a page script
  permission, origin: string
  done: seq[proc (allowed: bool)]

var
  asks: seq[Ask]
  lastAsk = ""

# ---------------------------------------------------------------------------------------------------------------
# "Allow this time" answers last as long as the tab (its props, as on the desktop).

proc allowedOnce(t: Tab): seq[string] = t.props.getOrDefault("site.once").splitLines

proc allowOnce(t: Tab, origin, permission: string) =
  t.props["site.once"] = (allowedOnce(t) & @[origin & " " & permission]).join("\n")

proc forgetOnce(t: Tab, origin: string) =
  var kept: seq[string]
  for l in allowedOnce(t):
    if l.len > 0 and not l.startsWith(origin & " "): kept.add l
  t.props["site.once"] = kept.join("\n")

proc permissionFor(t: Tab, origin, permission: string): Setting =
  if origin & " " & permission in allowedOnce(t): allow else: get(origin, permission)

# ---------------------------------------------------------------------------------------------------------------
# The bar

proc sendAsk() =
  let t = current()
  var j = %*{"kind": "none"}
  for a in asks:
    if a.tab == t:
      let k = kinds[kindNamed(a.permission)]
      j = %*{"kind": a.permission, "site": siteName(a.origin), "request": k.request, "label": k.label}
      break
  let text = $j
  if text != lastAsk:
    lastAsk = text
    event("permissionAsk", j)

proc finish(a: Ask, allowed, remember: bool) =
  # `a` may be borrowed from `asks` (answer's loop), so it leaves `asks` last: deleting it first could free it.
  if asks.find(a) < 0: return
  if remember: set(a.origin, a.permission, if allowed: allow else: blocked)
  elif allowed: allowOnce(a.tab, a.origin, a.permission)
  if a.engineId >= 0:
    if not a.tab.closed and not a.tab.asleep: webby_view_permission_respond(a.tab.view, uint64(a.engineId), allowed.cint)
    wake()
  for d in a.done: d(allowed)
  let i = asks.find(a)
  if i >= 0: asks.delete(i)
  sendAsk()

proc answer(args: JsonNode): JsonNode =
  ## {answer: remember | once | never | dismiss}
  let t = current()
  for a in asks:
    if a.tab == t:
      case args{"answer"}.getStr
      of "remember": finish(a, true, true)
      of "once": finish(a, true, false)
      of "never": finish(a, false, true)
      else: finish(a, false, false)
      break
  nil

proc enqueue(a: Ask) =
  asks.add a
  sendAsk()

proc askPermission(t: Tab, origin, permission: string, done: proc (allowed: bool)) =
  let s = permissionFor(t, origin, permission)
  if s != ask:
    done(s == allow)
    return
  for a in asks:
    if a.tab == t and a.engineId < 0 and a.origin == origin and a.permission == permission:
      a.done.add done
      return
  enqueue(Ask(tab: t, engineId: -1, origin: origin, permission: permission, done: @[done]))

proc dropEngineAsks(t: Tab) =
  var i = 0
  while i < asks.len:
    if asks[i].tab == t and asks[i].engineId >= 0: asks.delete(i) else: inc i
  sendAsk()

proc onEngineRequest(t: Tab, j: JsonNode) =
  dropEngineAsks(t)
  let id = j{"id"}.getBiggestInt
  let permission = j{"permission"}.getStr
  let origin = j{"origin"}.getStr
  let s = permissionFor(t, origin, permission)
  if s == ask and kindNamed(permission) >= 0:
    enqueue(Ask(tab: t, engineId: id, origin: origin, permission: permission))
  else:
    webby_view_permission_respond(t.view, uint64(id), (s == allow).cint)
    wake()

# ---------------------------------------------------------------------------------------------------------------
# Notifications

var nextNotification = 1
var shownNotifications: Table[int, tuple[tab: Tab, pageId: int, origin: string]]  ## Android id -> page's

proc pageState(t: Tab, origin: string): string =
  case permissionFor(t, origin, "notifications")
  of allow: "granted"
  of blocked: "denied"
  of ask: "default"

proc notificationScriptFor(t: Tab): string =
  let origin = secureOrigin(t.url)
  if origin.len == 0: return ""
  notificationScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))
    .replace("${jsonEncode(permission)}", $(%pageState(t, origin)))

proc callPage(t: Tab, js: string) =
  if not t.closed: t.runJs("window.__webbyNotifications && window.__webbyNotifications." & js)

proc onNotificationMessage(t: Tab, m: JsonNode): bool =
  let kind = m{"type"}.getStr
  if kind notin ["notificationPermission", "notify", "notificationClose"]: return false
  result = true
  let origin = secureOrigin(t.url)
  if origin.len == 0: return
  let id = m{"id"}.getInt
  case kind
  of "notificationPermission":
    askPermission(t, origin, "notifications", proc (allowed: bool) =
      if t.closed or secureOrigin(t.url) != origin: return
      let answer = if allowed: "granted" elif pageState(t, origin) == "denied": "denied" else: "default"
      callPage(t, "resolve(" & $id & ", " & $(%answer) & ")"))
  of "notify":
    if pageState(t, origin) == "granted":
      let n = nextNotification
      inc nextNotification
      shownNotifications[n] = (t, id, origin)
      event("notify", %*{"id": n, "tag": (if m{"tag"}.getStr.len > 0: origin & " " & m{"tag"}.getStr else: ""),
        "title": m{"title"}.getStr, "body": m{"body"}.getStr, "site": siteName(origin)})
  of "notificationClose":
    for n, s in shownNotifications:
      if s.tab == t and s.pageId == id:
        shownNotifications.del n
        event("notifyCancel", %*{"id": n})
        break
  else: discard

proc notificationClicked(args: JsonNode): JsonNode =
  let n = args{"id"}.getInt
  if n notin shownNotifications: return nil
  let s = shownNotifications[n]
  shownNotifications.del n
  if s.tab.closed: return nil
  activate(tabs.find(s.tab))
  callPage(s.tab, "click(" & $s.pageId & ")")
  callPage(s.tab, "closed(" & $s.pageId & ")")
  nil

proc refreshPages() =
  for t in tabs:
    let js = notificationScriptFor(t)
    if js.len > 0: t.runJs(js)

# ---------------------------------------------------------------------------------------------------------------
# Location: while libwebby wants a position, Java listens to the LocationManager and sends fixes.

var
  locating = false
  idleTicks = 0

proc pollLocation() =
  let wanted = webby_geolocation_wanted()
  if wanted != 0:
    idleTicks = 0
    if not locating:
      locating = true
      event("location", %*{"on": true})
  elif locating:
    inc idleTicks
    if idleTicks >= 20:      # 5 s after the last page stopped
      locating = false
      event("location", %*{"on": false})
  discard startTimer(250, pollLocation)

proc locationFix(args: JsonNode): JsonNode =
  proc num(k: string): float = (if args.hasKey(k) and args[k].kind in {JFloat, JInt}: args[k].getFloat else: NaN)
  if args.hasKey("error"):
    webby_geolocation_set_error(args{"code"}.getInt(2).cint, args{"error"}.getStr.cstring)
  else:
    webby_geolocation_set_position(num("lat"), num("lon"), num("accuracy"), num("altitude"), NaN, num("heading"),
      num("speed"))
  wake()
  nil

# ---------------------------------------------------------------------------------------------------------------
# Site settings

proc siteSettings(args: JsonNode): JsonNode =
  let t = current()
  let url = if t == nil: "" else: t.url
  let origin = originOf(url)
  if origin.len == 0: return %*{"origin": ""}
  var perms = newJArray()
  for k in kinds:
    perms.add %*{"name": k.name, "label": k.label, "setting": $get(origin, k.name)}
  %*{"origin": origin, "site": siteName(origin), "secure": origin.startsWith("https:"), "permissions": perms,
    "hasSettings": hasSettings(origin)}

proc setSetting(args: JsonNode): JsonNode =
  let t = current()
  let origin = originOf(if t == nil: "" else: t.url)
  if origin.len == 0: return nil
  let s = case args{"setting"}.getStr
          of "allow": allow
          of "block": blocked
          else: ask
  set(origin, args{"name"}.getStr, s)
  if s != allow: forgetOnce(t, origin)
  nil

proc resetSite(args: JsonNode): JsonNode =
  let t = current()
  let origin = originOf(if t == nil: "" else: t.url)
  if origin.len > 0:
    reset(origin)
    forgetOnce(t, origin)
  nil

proc deleteSiteData(args: JsonNode): JsonNode =
  let t = current()
  if t == nil or originOf(t.url).len == 0: return nil
  webby_clear_site_data(t.url.cstring)
  webby_view_reload(t.view)
  nil

proc install*() =
  permissionHandler = onEngineRequest
  activeTabHooks.add proc (t: Tab) = sendAsk()
  tabStateHooks.add proc (t: Tab) =
    if str(webby_view_permission_request(t.view)).len == 0: dropEngineAsks(t)
    var i = 0
    while i < asks.len:
      let a = asks[i]
      if a.tab == t and a.engineId < 0 and secureOrigin(t.url) != a.origin:
        asks.delete(i)
        for d in a.done: d(false)
      else: inc i
    sendAsk()
  tabClosedHooks.add proc (t: Tab) =
    var i = 0
    while i < asks.len:
      if asks[i].tab == t: asks.delete(i) else: inc i
    var gone: seq[int]
    for n, s in shownNotifications:
      if s.tab == t: gone.add n
    for n in gone: shownNotifications.del n
    sendAsk()
  pageScriptHooks.add notificationScriptFor
  pageMessageHooks.add onNotificationMessage
  storeListeners.add refreshPages
  startupHooks.add proc () = pollLocation()
  commands["permissions.answer"] = answer
  commands["notification.clicked"] = notificationClicked
  commands["location.fix"] = locationFix
  commands["site.settings"] = siteSettings
  commands["site.set"] = setSetting
  commands["site.reset"] = resetSite
  commands["site.deleteData"] = deleteSiteData
