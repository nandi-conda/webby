## Per-site permissions (app/lib/src/site_permissions.dart): each origin is asked once whether it may use a feature
## such as the location, and the answer is remembered in the profile's site_permissions.json until changed in the
## site settings popover. Requests come from the engine (permissionHandler) and from the browser's own page scripts
## (askPermission, for notifications); both wait in a bar under the toolbar for the user's answer.

import std/strutils
import ../../browser
from nimkit/core as kit import nil
import permstore
export permstore

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
  bar, barIcon, barLabel: kit.Widget
  shownAsk: Ask

proc refreshBar() =
  if bar == nil: return
  let t = currentTab()
  shownAsk = nil
  for a in asks:
    if a.tab == t:
      shownAsk = a
      break
  if shownAsk == nil:
    kit.`visible=`(bar, false)
    return
  let k = kinds[kindNamed(shownAsk.permission)]
  kit.`iconName=`(barIcon, k.icon)
  kit.`text=`(barLabel, "<b>" & kit.escapeRich(siteName(shownAsk.origin)) & " wants to</b>  " &
    kit.escapeRich(k.request))
  kit.`visible=`(bar, true)

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

proc answer(allowed, remember: bool) =
  ## The shown request's answer from the bar; closing it is a "no" for now, asked again next time.
  let a = shownAsk
  if a != nil: finish(a, allowed, remember)

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
  barIcon = kit.icon("help_outline", 18)
  barLabel = kit.richLabel("")
  kit.`maxChars=`(barLabel, 200)
  bar = kit.row(barIcon, kit.expand(barLabel),
    kit.button("Allow while visiting the site", proc () = answer(true, true)),
    kit.button("Allow this time", proc () = answer(true, false)),
    kit.button("Never allow", proc () = answer(false, true)),
    kit.iconButton("close", "Close", proc () = answer(false, false), 16))
  bar.spacing = 6
  kit.addClass(bar, "webby-info-bar")
  kit.`visible=`(bar, false)
  kit.add(barSlot, bar)

proc install*() =
  windowHooks.add buildBar
  permissionHandler = onEngineRequest
  tabStateHooks.add onTabState
  tabClosedHooks.add onTabClosed
  activeTabHooks.add proc (t: Tab) = refreshBar()
