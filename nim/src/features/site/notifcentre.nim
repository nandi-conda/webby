## The notification centre: every notification a site shows (pages' and web push's, features/site/notifications.nim)
## is kept in the profile's notification_centre.json, newest first, so it can be read again after the desktop's
## popup is gone. A bell right of the URL bar (once there is one) opens them in a side panel, with how many came
## since it was last opened; clicking one does what clicking the popup does while that's still up, else goes to the
## site's open tab or opens the page it came from. Each can be removed, or all cleared; the gear opens
## ⋮ > Settings > Notifications (notifprefs.nim). Incognito keeps nothing.

import std/[os, strutils, times]
import ../../browser
from nimkit/core as kit import nil
import icons, notifications, notifprefs, permissions

const
  keep = 300                    ## notifications kept; older ones are dropped
  title = "Notification centre"

type Entry = object
  id, origin, tag, title, body, url: string
  time: int64                   ## milliseconds since the epoch
  systemId: uint32              ## while this process shows it (not saved)

var
  entries: seq[Entry]           ## newest first
  seen: int64                   ## when the panel was last open; later ones count as new
  serial = 0
  panelOpen = false
  panelList: kit.Widget
  button, count: kit.Widget

proc nowMs(): int64 = (epochTime() * 1000).int64

proc file(): string =
  let override = getEnv("WEBBY_NOTIFICATION_CENTRE_FILE")
  if override.len > 0: override else: profileFile("notification_centre.json")

proc load() =
  ## Reads the file again: other windows of the profile (and the one that owns web push) add to it too.
  var shown: seq[(string, uint32)]
  for e in entries:
    if e.systemId != 0: shown.add (e.id, e.systemId)
  entries = @[]
  seen = 0
  if incognito: return
  let j = try: parseFile(file()) except CatchableError: return
  seen = j{"seen"}.getBiggestInt
  for n in j{"items"}.getElems:
    var e = Entry(id: n{"id"}.getStr, origin: n{"origin"}.getStr, tag: n{"tag"}.getStr, title: n{"title"}.getStr,
      body: n{"body"}.getStr, url: n{"url"}.getStr, time: n{"t"}.getBiggestInt)
    for (id, sys) in shown:
      if id == e.id: e.systemId = sys
    if e.id.len > 0 and e.origin.len > 0: entries.add e

proc save() =
  if incognito: return
  var items = newJArray()
  for e in entries:
    items.add %*{"id": e.id, "origin": e.origin, "tag": e.tag, "title": e.title, "body": e.body, "url": e.url,
      "t": e.time}
  try:
    createDir(file().parentDir)
    writeFileAtomic(file(), $(%*{"seen": seen, "items": items}))
  except CatchableError as err: stderr.writeLine "webby: could not write ", file(), ": ", err.msg

proc unread(): int =
  for e in entries:
    if e.time > seen: inc result

# ---------------------------------------------------------------------------------------------------------------
# The side panel

proc ago(ms: int64): string =
  let secs = (nowMs() - ms) div 1000
  if secs < 60: return "now"
  if secs < 3600: return $(secs div 60) & " min ago"
  if secs < 86400: return $(secs div 3600) & " h ago"
  let t = fromUnix(ms div 1000).local
  if secs < 7 * 86400: return t.format("ddd HH:mm")
  t.format("MMM d")

proc refresh()

proc remove(id: string) =
  load()
  for i, e in entries:
    if e.id == id:
      entries.delete i
      break
  save()
  refresh()

proc clearAll() =
  load()
  entries = @[]
  save()
  refresh()

proc openEntry(e: Entry) =
  ## Like clicking the popup while it's up (a push notification's worker may open its own page), else the site's
  ## tab, else the page it came from.
  if e.systemId != 0 and activate(e.systemId): return
  for t in tabs:
    if not t.closed and originOf(t.url) == e.origin:
      activateTab(t)
      return
  discard openTab(if e.url.len > 0: e.url else: e.origin & "/")

proc entryRow(e: Entry, fresh: bool): kit.Widget =
  let icon = kit.icon("public", 20)
  let saved = savedIcon(e.origin)
  if saved.len > 0: kit.`image=`(icon, saved)
  let head = kit.label(if e.title.len > 0: e.title else: siteName(e.origin))
  kit.addClass(head, "bold")
  kit.`maxChars=`(head, 200)
  let text = kit.column(head)
  text.spacing = 2
  if e.body.len > 0:
    let body = kit.label(e.body)
    kit.addClass(body, "webby-notif-body")
    kit.add(text, body)
  kit.add(text, kit.addClass(kit.addClass(kit.label(siteName(e.origin) & " · " & ago(e.time)), "dim"), "small"))
  let id = e.id
  # The remove button sits beside the row's button: inside it, clicking it opened the notification instead.
  let item = kit.item(icon, kit.expand(text), onClick = proc () = openEntry(e))
  item.spacing = 10
  kit.`tooltip=`(item, if e.url.len > 0: e.url else: e.origin)
  kit.addClass(item, "webby-notif-item")
  let close = kit.addClass(kit.iconButton("close", "Remove", proc () = remove(id), 14), "webby-notif-remove")
  let row = kit.row(kit.expand(item), close)
  kit.addClass(row, "webby-notif-row")
  if fresh: kit.addClass(row, "webby-notif-new")
  item.onContext = proc () =
    kit.popupMenu(@[kit.menuItem("Open", proc () = openEntry(e)),
                    kit.menuItem("Remove", proc () = remove(id)),
                    kit.menuItem("Turn off notifications from " & siteName(e.origin), proc () =
                      for t in tabs: forgetOnce(t, e.origin)
                      set(e.origin, "notifications", blocked)
                      kit.toast("Notifications from " & siteName(e.origin) & " are off"))])
  row

proc fillPanel(newSince: int64) =
  if panelList == nil: return
  kit.clear(panelList)
  if entries.len == 0:
    let l = kit.addClass(kit.addClass(kit.label("Notifications from sites show up here."), "dim"), "webby-notif-empty")
    kit.add(panelList, l)
  for e in entries: kit.add(panelList, entryRow(e, e.time > newSince))

var panelSince: int64   ## the panel's "new" mark: what was unread when it opened

proc refreshButton() =
  if button == nil: return
  let n = unread()
  kit.`visible=`(button, entries.len > 0 or panelOpen)
  kit.`tooltip=`(button, if n == 0: title else: title & " (" & $n & " new)")
  if count != nil:
    kit.`text=`(count, if n > 99: "99+" else: $n)
    kit.`visible=`(count, n > 0 and not panelOpen and kit.visible(button))

proc refresh() =
  if panelOpen:
    seen = nowMs()
    fillPanel(panelSince)
  refreshButton()

proc toggleNotificationCentre*() =
  if panelOpen:
    closeSidePanel()
    return
  load()
  panelSince = seen
  seen = nowMs()
  save()
  panelList = kit.column()
  panelList.spacing = 0
  let top = kit.addClass(kit.row(kit.expand(kit.spacer()),
    kit.iconButton("tune", "Notification settings", toggleNotificationSettings),
    kit.iconButton("delete_sweep_outlined", "Clear all", clearAll)), "webby-panel-top")
  top.spacing = 4
  let body = kit.column(top, kit.expand(kit.scroll(panelList)))
  body.spacing = 4
  panelOpen = true
  showSidePanel(title, body, 380, proc () =
    panelOpen = false
    panelList = nil
    refreshButton())
  fillPanel(panelSince)
  refreshButton()

# ---------------------------------------------------------------------------------------------------------------

proc onShown(n: ShownNotification) =
  if incognito or n.tag == "\x01webby-backlog": return   # the "N more you missed" line: they're listed one by one
  load()
  # One with the same tag replaces the earlier one, as on the desktop.
  if n.tag.len > 0:
    for i in countdown(entries.high, 0):
      if entries[i].origin == n.origin and entries[i].tag == n.tag: entries.delete i
  inc serial
  entries.insert(Entry(id: $nowMs() & "-" & $getCurrentProcessId() & "-" & $serial, origin: n.origin, tag: n.tag,
    title: n.title, body: n.body, url: n.url, time: nowMs(), systemId: n.id), 0)
  if entries.len > keep: entries.setLen keep
  if panelOpen: seen = nowMs()
  save()
  refresh()

proc install*() =
  shownHooks.add onShown
  windowHooks.add proc () =
    if appUrl.len > 0 or incognito: return
    load()
    addMenuItem(title, toggleNotificationCentre, group = mgHistory)
    loadCss("button.webby-notif-item { padding: 8px 4px 8px 10px; }\n" &
      "button.webby-notif-remove { padding: 2px; min-height: 0; margin: 18px 6px; }\n" &
      ".webby-notif-new { background-color: alpha(@theme_selected_bg_color, 0.12); }\n" &
      ".webby-notif-empty { margin-top: 24px; }\n" &
      ".webby-notif-count { margin: 12px 4px 12px -8px; font-size: 0.75em; font-weight: bold; padding: 0 5px; " &
      "border-radius: 8px; background-color: @theme_selected_bg_color; color: @theme_selected_fg_color; }")
    button = addToolbarButton("notifications_outlined", title, toggleNotificationCentre, "notifications_outlined",
      title)
    when not defined(android):
      count = kit.addClass(kit.label(""), "webby-notif-count")
      kit.add(toolbarEndRow, count)
    refreshButton()
