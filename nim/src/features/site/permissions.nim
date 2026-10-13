## Per-site permissions (app/lib/src/site_permissions.dart): each origin is asked once whether it may use a feature
## such as the location, and the answer is remembered in the profile's site_permissions.json until changed in the
## site settings popover. Requests come from the engine (permissionHandler) and from the browser's own page scripts
## (askPermission, for notifications); both wait in a bar under the toolbar for the user's answer.

import std/[os, strutils, uri]
import ../../browser

type
  Setting* = enum ask = "ask", allow = "allow", blocked = "block"
  Kind* = tuple[name, label, request, icon: string]

const kinds*: array[3, Kind] = [
  ("geolocation", "Location", "Know your location", "location_on_outlined"),
  ("microphone", "Microphone", "Use your microphones", "mic_none"),
  ("notifications", "Notifications", "Show notifications", "notifications_outlined")]

proc kindNamed*(name: string): int =
  for i, k in kinds:
    if k.name == name: return i
  -1

proc reveal*(w: Widget) =
  ## Shows a widget kept out of the window's show_all (no_show_all) with all its children.
  gtk_widget_set_no_show_all(w, 0)
  gtk_widget_show_all(w)
  gtk_widget_set_no_show_all(w, 1)

# ---------------------------------------------------------------------------------------------------------------
# Origins

proc originOf*(url: string): string =
  ## "https://example.com[:port]" for http(s) URLs, "" for pages without a site worth keeping settings for.
  try:
    let u = parseUri(url)
    let scheme = u.scheme.toLowerAscii
    if scheme notin ["http", "https"] or u.hostname.len == 0: return ""
    result = scheme & "://" & u.hostname.toLowerAscii
    if u.port.len > 0 and not (scheme == "http" and u.port == "80" or scheme == "https" and u.port == "443"):
      result.add ":" & u.port
  except CatchableError: result = ""

proc siteName*(origin: string): string =
  ## The host without "www.", with the scheme only when it isn't https.
  let i = origin.find("://")
  if i < 0: return origin
  var host = origin[i + 3 .. ^1]
  if host.startsWith("www."): host = host[4 .. ^1]
  if origin.startsWith("https://"): host else: origin[0 ..< i + 3] & host

proc secureOrigin*(url: string): string =
  ## The origin when it may use permission-gated features (https, or http on localhost), else "".
  let o = originOf(url)
  if o.startsWith("https://") or o.startsWith("http://localhost") or o.startsWith("http://127.0.0.1"): o else: ""

# ---------------------------------------------------------------------------------------------------------------
# The remembered answers: {"version": 1, "sites": {origin: {permission: "allow" | "block"}}}

var
  sites: seq[(string, seq[(string, Setting)])]
  loaded = false
  storeListeners*: seq[proc ()]   ## a remembered answer changed

proc isKind(n: JsonNode, kind: JsonNodeKind): bool = n != nil and n.kind == kind

proc storeFile(): string =
  let o = getEnv("WEBBY_SITE_PERMISSIONS_FILE")
  if o.len > 0: o else: profileFile("site_permissions.json")

proc load() =
  if loaded: return
  loaded = true
  let j = readJsonFile(storeFile())
  if j == nil or not isKind(j{"sites"}, JObject): return
  for origin, perms in j["sites"]:
    if perms.kind != JObject: continue
    var list: seq[(string, Setting)]
    for name, v in perms:
      let s = v.getStr
      if s == "allow": list.add (name, allow)
      elif s == "block": list.add (name, blocked)
    if list.len > 0: sites.add (origin, list)

proc save() =
  # An incognito window starts from the profile's answers but keeps its own changes to itself.
  if incognito: return
  var root = newJObject()
  for (origin, list) in sites:
    var o = newJObject()
    for (name, s) in list: o[name] = %($s)
    root[origin] = o
  try: writeJsonFile(storeFile(), %*{"version": 1, "sites": root}, pretty = true)
  except CatchableError as e: stderr.writeLine "webby: could not save ", storeFile(), ": ", e.msg

proc changed() =
  save()
  for h in storeListeners: h()

proc get*(origin, permission: string): Setting =
  load()
  for (o, list) in sites:
    if o == origin:
      for (name, s) in list:
        if name == permission: return s
  ask

proc set*(origin, permission: string, setting: Setting) =
  load()
  if get(origin, permission) == setting: return
  var i = 0
  while i < sites.len and sites[i][0] != origin: inc i
  if i == sites.len: sites.add (origin, newSeq[(string, Setting)]())
  var list = sites[i][1]
  var j = 0
  while j < list.len and list[j][0] != permission: inc j
  if setting == ask:
    if j < list.len: list.delete(j)
  elif j < list.len: list[j][1] = setting
  else: list.add (permission, setting)
  if list.len == 0: sites.delete(i) else: sites[i][1] = list
  changed()

proc reset*(origin: string) =
  ## Forgets every answer `origin` got.
  load()
  for i, (o, _) in sites:
    if o == origin:
      sites.delete(i)
      changed()
      return

proc hasSettings*(origin: string): bool =
  load()
  for (o, list) in sites:
    if o == origin: return list.len > 0

# ---------------------------------------------------------------------------------------------------------------
# "Allow this time" answers last as long as the tab: kept in its props as "origin permission" lines.

proc allowedOnce(t: Tab): seq[string] = t.props.getOrDefault("site.once").splitLines

proc allowOnce(t: Tab, origin, permission: string) =
  t.props["site.once"] = (allowedOnce(t) & @[origin & " " & permission]).join("\n")

proc forgetOnce*(t: Tab, origin: string) =
  ## Forgets the tab's "allow this time" answers for `origin`.
  var kept: seq[string]
  for l in allowedOnce(t):
    if l.len > 0 and not l.startsWith(origin & " "): kept.add l
  t.props["site.once"] = kept.join("\n")

proc permissionFor*(t: Tab, origin, permission: string): Setting =
  ## What `origin` may do with `permission` in `t`: a remembered answer, or allow after "Allow this time".
  if origin & " " & permission in allowedOnce(t): allow else: get(origin, permission)

# ---------------------------------------------------------------------------------------------------------------
# Requests waiting for the user, and the bar that asks.

type Ask = ref object
  tab: Tab
  engineId: int64      ## the engine's request id, or -1 for one from a page script
  permission, origin: string
  done: seq[proc (allowed: bool)]

var
  asks: seq[Ask]
  bar, barIcon, barLabel: Widget
  shownAsk: Ask

{.push cdecl, importc.}
proc gtk_info_bar_new(): Widget
proc gtk_info_bar_get_content_area(b: Widget): Widget
proc gtk_info_bar_add_button(b: Widget, text: cstring, response: cint): Widget
proc gtk_info_bar_set_show_close_button(b: Widget, on: gboolean)
proc gtk_info_bar_set_message_type(b: Widget, kind: cint)
{.pop.}

const
  answerRemember = 1.cint
  answerOnce = 2.cint
  answerNever = 3.cint

proc refreshBar() =
  if bar == nil: return
  let t = currentTab()
  shownAsk = nil
  for a in asks:
    if a.tab == t:
      shownAsk = a
      break
  if shownAsk == nil:
    gtk_widget_hide(bar)
    return
  let k = kinds[kindNamed(shownAsk.permission)]
  setIcon(barIcon, k.icon)
  gtk_label_set_markup(barLabel, cstring("<b>" & escapeMarkup(siteName(shownAsk.origin)) & " wants to</b>  " &
    escapeMarkup(k.request)))
  reveal(bar)

proc finish(a: Ask, allowed, remember: bool) =
  let i = asks.find(a)
  if i < 0: return
  asks.delete(i)
  if remember: set(a.origin, a.permission, if allowed: allow else: blocked)
  elif allowed: allowOnce(a.tab, a.origin, a.permission)
  if a.engineId >= 0:
    if not a.tab.closed: webby_view_permission_respond(a.tab.view, uint64(a.engineId), allowed.cint)
    wake()
  for d in a.done: d(allowed)
  refreshBar()

proc onBarResponse(b: Widget, response: cint, data: pointer) {.cdecl.} =
  let a = shownAsk
  if a == nil: return
  case response
  of answerRemember: finish(a, true, true)
  of answerOnce: finish(a, true, false)
  of answerNever: finish(a, false, true)
  else: finish(a, false, false)   # closing it is a "no" for now, asked again next time

proc enqueue(a: Ask) =
  asks.add a
  if a.tab == currentTab(): refreshBar()

proc askPermission*(t: Tab, origin, permission: string, done: proc (allowed: bool)) =
  ## Asks the user, like the engine's own requests, whether `origin` may use `permission` (for features the
  ## browser's page scripts provide). Calls `done` at once when the site was answered before.
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
  var dropped = false
  while i < asks.len:
    if asks[i].tab == t and asks[i].engineId >= 0:
      asks.delete(i)
      dropped = true
    else: inc i
  if dropped: refreshBar()

proc onEngineRequest(t: Tab, j: JsonNode) =
  dropEngineAsks(t)
  let id = j{"id"}.getBiggestInt
  let permission = j{"permission"}.getStr
  let origin = j{"origin"}.getStr
  let s = permissionFor(t, origin, permission)
  # Permissions this browser doesn't know how to ask about are refused.
  if s == ask and kindNamed(permission) >= 0:
    enqueue(Ask(tab: t, engineId: id, origin: origin, permission: permission))
  else:
    webby_view_permission_respond(t.view, uint64(id), (s == allow).cint)
    wake()

proc onTabState(t: Tab) =
  # A request the page dropped (it navigated away) stops waiting; script asks end with their page's origin.
  if str(webby_view_permission_request(t.view)).len == 0: dropEngineAsks(t)
  var i = 0
  while i < asks.len:
    let a = asks[i]
    if a.tab == t and a.engineId < 0 and secureOrigin(t.url) != a.origin:
      asks.delete(i)
      for d in a.done: d(false)
    else: inc i
  refreshBar()

proc onTabClosed(t: Tab) =
  var i = 0
  while i < asks.len:
    if asks[i].tab == t: asks.delete(i) else: inc i
  refreshBar()

proc buildBar() =
  bar = gtk_info_bar_new()
  gtk_info_bar_set_message_type(bar, GTK_MESSAGE_QUESTION)
  gtk_info_bar_set_show_close_button(bar, 1)
  let content = gtk_info_bar_get_content_area(bar)
  barIcon = icon("help_outline", 18)
  barLabel = gtk_label_new("")
  gtk_label_set_xalign(barLabel, 0)
  gtk_label_set_ellipsize(barLabel, PANGO_ELLIPSIZE_END)
  gtk_box_pack_start(content, barIcon, 0, 0, 0)
  gtk_box_pack_start(content, barLabel, 1, 1, 4)
  discard gtk_info_bar_add_button(bar, "Allow while visiting the site", answerRemember)
  discard gtk_info_bar_add_button(bar, "Allow this time", answerOnce)
  discard gtk_info_bar_add_button(bar, "Never allow", answerNever)
  connect(bar, "response", onBarResponse)
  gtk_widget_set_no_show_all(bar, 1)
  gtk_box_pack_start(barSlot, bar, 0, 0, 0)

proc install*() =
  windowHooks.add buildBar
  permissionHandler = onEngineRequest
  tabStateHooks.add onTabState
  tabClosedHooks.add onTabClosed
  activeTabHooks.add proc (t: Tab) = refreshBar()
