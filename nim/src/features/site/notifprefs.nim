## ⋮ > Settings > Notifications: every site that may show notifications or has asked to, in a side panel, for
## the sites you aren't on (the site settings popover only covers the page in front of you). Each can be switched
## to Ask, Allow or Block, or removed; blocking also drops its web push subscription (features/site/push.nim).
## A switch at the top mutes every site's notifications without forgetting their answers.

import std/algorithm
import ../../browser
from nimkit/core as kit import nil
import permissions
when not defined(android): import push

var
  panelOpen = false
  list: kit.Widget   ## the panel's site rows, rebuilt by refresh

type Site = tuple[origin: string, setting: Setting, subscribed, worker: bool]

proc sites(): seq[Site] =
  for (origin, s) in sitesWith("notifications"): result.add (origin, s, false, false)
  when not defined(android):
    for p in pushSites():
      var known = false
      for s in result.mitems:
        if s.origin == p.origin:
          s.subscribed = p.subscribed
          s.worker = true
          known = true
      if not known: result.add (p.origin, ask, p.subscribed, true)
  result.sort(proc (a, b: Site): int = cmp(siteName(a.origin), siteName(b.origin)))

proc forgetOnceEverywhere(origin: string) =
  for t in tabs: forgetOnce(t, origin)

proc later(action: proc ()) = discard after(0, action)

proc remove(origin: string) =
  forgetOnceEverywhere(origin)
  set(origin, "notifications", ask)
  when not defined(android): forgetPushSite(origin)

proc siteRow(s: Site): kit.Widget =
  let origin = s.origin
  let text = kit.column(kit.addClass(kit.label(siteName(origin)), "bold"))
  text.spacing = 0
  var note = case s.setting
    of allow: "Allowed"
    of blocked: "Blocked"
    of ask: "Asks first"
  if s.subscribed: note.add " · subscribed to push"
  kit.add(text, kit.addClass(kit.label(note), "small"))
  let choice = kit.dropdown(@["Ask", "Allow", "Block"], s.setting.ord, proc (i: int) =
    let setting = Setting(i)
    if setting != allow: forgetOnceEverywhere(origin)
    later(proc () = set(origin, "notifications", setting)))
  kit.`tooltip=`(choice, "Whether " & siteName(origin) & " may show notifications")
  let forget = kit.iconButton("delete_outline", "Remove (it can ask again)", proc () = later(proc () = remove(origin)), 16)
  result = kit.row(kit.icon("notifications_outlined", 18), kit.expand(text), choice, forget)
  result.spacing = 8

proc refresh() =
  if not panelOpen or list == nil: return
  kit.clear(list)
  let all = sites()
  if all.len == 0:
    kit.add(list, kit.addClass(kit.label("No site has asked to show notifications yet."), "dim"))
    return
  for s in all: kit.add(list, siteRow(s))

proc showPanel() =
  let root = kit.addClass(kit.column(), "webby-notif-prefs")
  root.spacing = 8
  kit.add(root, kit.check("Mute all notifications", notificationsMuted(), proc (on: bool) =
    later(proc () = setNotificationsMuted(on))))
  kit.add(root, kit.addClass(kit.label("Sites keep their settings while muted; nothing is shown until you turn " &
    "this off."), "small"))
  kit.add(root, kit.separator())
  kit.add(root, kit.addClass(kit.label("Sites"), "dim"))
  list = kit.column()
  list.spacing = 8
  kit.add(root, kit.expand(kit.scroll(list)))
  kit.add(root, kit.addClass(kit.label("Blocking a site also cancels its push subscription. Each notification " &
    "has \"Turn off for this site\" too."), "small"))
  showSidePanel("Notifications", root, 400, proc () =
    panelOpen = false
    list = nil)
  panelOpen = true
  refresh()

proc toggleNotificationSettings*() =
  if panelOpen: closeSidePanel() else: showPanel()

proc install*() =
  storeListeners.add refresh
  when not defined(android): pushListeners.add refresh
  windowHooks.add proc () =
    loadCss(".webby-notif-prefs { padding: 12px; }")
    addMenuItem("Notifications", toggleNotificationSettings, group = mgSettings)
