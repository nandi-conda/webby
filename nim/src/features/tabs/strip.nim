## The tab strip: the open tabs coming back at the next start (open_tabs.json), pinned tabs, vertical tabs
## (tabs.json), the tab right-click menu, reopening closed tabs, unloaded tabs and discarding long-hidden ones
## (main.dart, tab_strip.dart, web_view.dart).

import std/[os, strutils, times]
from std/unicode import toRunes, `$`
import ../../browser
from nimkit/core as kit import nil
import store, common


var
  closedTabs*: seq[DeviceTab]   ## most recent last, for Ctrl+Shift+T and "Recently closed"
  vertical = false
  lastActive: Tab
  fixingOrder = false

# ---------------------------------------------------------------------------------------------------------------
# Unloaded tabs: a sleeping tab (no view, no WebContent process) that shows a URL and title but loads nothing until
# it's first shown.

proc isUnloaded*(t: Tab): bool = "pendingUrl" in t.props

proc showPending(t: Tab) =
  t.url = t.props["pendingUrl"]
  t.title = t.props.getOrDefault("pendingTitle")
  updateTabButton(t)

proc makeUnloaded(t: Tab, url, title: string) =
  t.props["pendingUrl"] = url
  t.props["pendingTitle"] = title
  t.loading = false
  t.canBack = false
  t.canForward = false
  showPending(t)

proc openUnloadedTab*(url, title: string, index = -1): Tab =
  ## A background tab that loads `url` once it's selected.
  result = adoptView(nil, focus = false, index = index)
  makeUnloaded(result, url, title)

proc loadPending(t: Tab) =
  if not t.isUnloaded: return
  let url = t.props["pendingUrl"]
  t.props.del("pendingUrl")
  t.props.del("pendingTitle")
  t.loadUrl(url)

proc discardTab(t: Tab) =
  ## Throws away a hidden tab's page and WebContent process, keeping its URL and title; selecting it loads the URL
  ## afresh (scroll position, form contents and back/forward history are lost).
  let url = t.url
  let title = t.title
  sleepTab(t)
  makeUnloaded(t, url, title)

proc discardMinutes(): int =
  ## WEBBY_DISCARD_MINUTES, else 30; 0 never discards on age (low memory still does).
  try: parseInt(getEnv("WEBBY_DISCARD_MINUTES", "30")) except ValueError: 30

proc lowOnMemory(): bool =
  ## Whether less than a tenth of RAM is available (/proc/meminfo).
  var total, available = -1
  try:
    for line in lines("/proc/meminfo"):
      let f = line.splitWhitespace
      if f.len < 2: continue
      if f[0] == "MemTotal:": total = parseInt(f[1])
      elif f[0] == "MemAvailable:": available = parseInt(f[1])
  except CatchableError: return false
  total > 0 and available >= 0 and available * 10 < total

proc discardIdleTabs(d: pointer): gboolean {.cdecl.} =
  ## Every minute: background tabs hidden for discardMinutes, or for a minute when memory is low, lose their page.
  let after = discardMinutes()
  let low = lowOnMemory()
  let now = epochTime()
  for t in tabs:
    if t == currentTab() or t.pinned or t.isUnloaded or "hiddenSince" notin t.props: continue
    if "webauthn" in t.props or "filepicker" in t.props or "permission" in t.props: continue
    let hidden = now - parseFloat(t.props["hiddenSince"])
    if (after > 0 and hidden >= float(after * 60)) or (low and hidden >= 60): discardTab(t)
  1

# ---------------------------------------------------------------------------------------------------------------
# Pinned tabs: small tiles at the start of the strip that survive "Close other tabs".

proc pinnedCount*(): int =
  for t in tabs:
    if not t.pinned: break
    inc result

proc styleTab(t: Tab) =
  kit.`visible=`(t.closeButton, not t.pinned)
  kit.setClass(t.button, "webby-pinned-tab", t.pinned)
  # A 40 px tile with the icon in the middle, like tab_strip.dart's.
  discard kit.sized(t.button, (if t.pinned and not vertical: 40 else: 0))
  updateTabButton(t)

# ---------------------------------------------------------------------------------------------------------------
# The open tabs, kept in open_tabs.json as they change (a second after, so a burst of changes is one write) and
# opened again, asleep, at the next start.

var
  saveSource: cuint
  restoring = false

proc keepsTabs(): bool = not incognito and appUrl.len == 0

proc saveOpenTabsNow() =
  if saveSource != 0:
    discard g_source_remove(saveSource)
    saveSource = 0
  # Closing the last tab quits; what was saved before it stays for the next start.
  if not keepsTabs() or restoring or tabs.len == 0: return
  var list: seq[DeviceTab]
  for t in tabs: list.add DeviceTab(title: t.title, url: t.url)
  writeOpenTabs(list, activeIndex, pinnedCount())

proc onSaveTimer(d: pointer): gboolean {.cdecl.} =
  saveSource = 0
  saveOpenTabsNow()
  0

proc saveOpenTabsSoon() =
  if keepsTabs() and not restoring and saveSource == 0: saveSource = g_timeout_add(1000, onSaveTimer, nil)

proc fixOrder() =
  ## Pinned tabs stay together at the start; a tab opened among them moves just after them.
  if fixingOrder: return
  fixingOrder = true
  var moved = true
  while moved:
    moved = false
    for i in 1 ..< tabs.len:
      if tabs[i].pinned and not tabs[i - 1].pinned:
        moveTab(tabs[i], pinnedCount())   # the pinned one rejoins the run at the start
        moved = true
        break
  fixingOrder = false

proc togglePinned*(t: Tab) =
  ## Pins `t` (moving it to the end of the pinned tabs) or unpins it (moving it just after them).
  if t notin tabs: return
  t.pinned = not t.pinned
  styleTab(t)
  var dest = 0
  for x in tabs:
    if x != t and x.pinned: inc dest
  moveTab(t, dest)
  notifyTabStrip()

# ---------------------------------------------------------------------------------------------------------------
# Vertical tabs: the strip becomes a column left of the page.

proc setVertical*(on: bool, save = true) =
  vertical = on
  if save: writeVerticalTabs(on)
  if appUrl.len > 0: return
  let old = tabStripRoot
  buildTabStrip(on)   # moves the tabs over to a new strip
  if old != nil and old.parent != nil: kit.remove(old.parent, old)
  if on:
    discard kit.sized(tabStripRoot, 220)
    kit.addClass(tabStripRoot, "webby-vertical-tabs")
    kit.insert(pageRow, tabStripRoot, 0)
  else:
    kit.insert(rootColumn, tabStripRoot, 0)
  for t in tabs: styleTab(t)

# ---------------------------------------------------------------------------------------------------------------
# Commands

proc newTab*() = discard openTab(homePage)

proc reopenClosedTab*() =
  if closedTabs.len > 0:
    let c = closedTabs.pop
    discard openTab(c.url, index = activeIndex + 1)

proc duplicateTab*(t: Tab) =
  let i = tabs.find(t)
  if i < 0: return
  discard openTab(if t.url.len == 0: "about:blank" else: t.url, index = i + 1)

proc closeOtherTabs*(keep: Tab, toTheRight = false) =
  ## Closes every unpinned tab but `keep` (or only those after it).
  let index = tabs.find(keep)
  if index < 0: return
  for i in countdown(tabs.high, 0):
    if i < tabs.len and tabs[i] != keep and not tabs[i].pinned and (not toTheRight or i > index): closeTab(tabs[i])
  activateTab(keep)

proc shorten(s: string, n: int): string =
  let r = s.toRunes
  if r.len > n: $r[0 ..< n - 1] & "…" else: s

proc addRecentlyClosed*(items: var seq[kit.MenuItem]) =
  ## "Recently closed" and the last ten closed tabs, newest first.
  if closedTabs.len == 0: return
  items.add kit.menuSeparator()
  items.add kit.menuItem("Recently closed", nil, enabled = false)
  proc closedItem(c: DeviceTab): kit.MenuItem =
    kit.menuItem("   " & shorten(c.title, 50), proc () =
      let j = closedTabs.find(c)
      if j >= 0: closedTabs.delete(j)
      discard openTab(c.url, index = activeIndex + 1))
  for i in countdown(closedTabs.high, max(closedTabs.len - 10, 0)): items.add closedItem(closedTabs[i])

proc fillTabMenu*(t: Tab, items: var seq[kit.MenuItem]) =
  ## The strip's right-click menu, for `t` or for no tab (nil) on the strip's empty space.
  items.add kit.menuItem("New tab", newTab, shortcut = "Ctrl+T")
  if t != nil:
    let i = tabs.find(t)
    items.add kit.menuSeparator()
    items.add kit.menuItem("Reload", proc () = (if t.isUnloaded: loadPending(t) else: webby_view_reload(t.view)); wake())
    items.add kit.menuItem("Duplicate", proc () = duplicateTab(t))
    items.add kit.menuItem(if t.pinned: "Unpin tab" else: "Pin tab", proc () = togglePinned(t))
    items.add kit.menuSeparator()
    items.add kit.menuItem("Close", proc () = closeTab(t), shortcut = if t == currentTab(): "Ctrl+W" else: "")
    var others, right = false
    for j, x in tabs:
      if x != t and not x.pinned:
        others = true
        if j > i: right = true
    items.add kit.menuItem("Close other tabs", proc () = closeOtherTabs(t), enabled = others)
    items.add kit.menuItem(if vertical: "Close tabs below" else: "Close tabs to the right",
      proc () = closeOtherTabs(t, toTheRight = true), enabled = right)
  items.add kit.menuSeparator()
  items.add kit.menuItem("Reopen closed tab", reopenClosedTab, enabled = closedTabs.len > 0, shortcut = "Ctrl+Shift+T")
  addRecentlyClosed(items)
  items.add kit.menuSeparator()
  items.add kit.checkItem("Vertical tabs", vertical, proc () = setVertical(not vertical))

# ---------------------------------------------------------------------------------------------------------------

proc startTabs(urls: seq[string]): bool =
  ## The last run's tabs come back. Only the front one loads; the others sleep until they're selected. Addresses on
  ## the command line open as new tabs after them, the first in front.
  if not keepsTabs(): return false
  var saved = readTabsFile(openTabsFile())
  if saved.tabs.len == 0: saved = readTabsFile(pinnedTabsFile())   # from before open_tabs.json was kept
  if saved.tabs.len == 0: return false
  restoring = true
  # The front tab goes first (the first tab is always selected) and the sleeping ones are put around it.
  let front = if urls.len > 0: openTab(urls[0]) else: openTab(saved.tabs[saved.active].url)
  for i, d in saved.tabs:
    if urls.len == 0 and i == saved.active:
      front.pinned = i < saved.pinned
      styleTab(front)
      continue
    let t = openUnloadedTab(d.url, d.title, index = i)
    t.pinned = i < saved.pinned
    styleTab(t)
  for u in urls[min(1, urls.len) .. ^1]: discard openTab(u, focus = false)
  activateTab(front)
  restoring = false
  fixOrder()
  saveOpenTabsSoon()
  true

proc install*() =
  initialTabsHooks.add startTabs
  tabCreatedHooks.add proc (t: Tab) =
    if t != currentTab(): t.props["hiddenSince"] = $epochTime()
  tabClosedHooks.add proc (t: Tab) =
    if lastActive == t: lastActive = nil
    if isSessionUrl(t.url):
      closedTabs.add DeviceTab(title: tabTitle(t.title, t.url), url: t.url)
      if closedTabs.len > 25: closedTabs.delete(0)
  activeTabHooks.add proc (t: Tab) =
    if lastActive != nil and lastActive != t and not lastActive.closed:
      lastActive.props["hiddenSince"] = $epochTime()  # when it went into the background
    t.props.del("hiddenSince")
    lastActive = t
    loadPending(t)
    saveOpenTabsSoon()
  tabStateHooks.add proc (t: Tab) =
    if t.isUnloaded: showPending(t)   # a fresh view reports an empty page; keep showing what it will load
    if t.pinned: styleTab(t)
    saveOpenTabsSoon()
  tabStripHooks.add proc () =
    fixOrder()
    saveOpenTabsSoon()
  shutdownHooks.add saveOpenTabsNow
  tabMenuHooks.add fillTabMenu
  windowHooks.add proc () =
    loadCss("""
button.webby-pinned-tab { padding: 4px 0; }
.webby-vertical-tabs { border-right: 1px solid alpha(currentColor, 0.15); }
.webby-vertical-tabs button.webby-tab { border-radius: 6px; margin: 1px 4px; }
.webby-strip-space, .webby-strip-space:hover { background: none; box-shadow: none; border: none; }
""")
    # The strip's empty space: a right-click opens the strip's menu, a double click a new tab (tab_strip.dart).
    tabStripSpace.onContext = proc () =
      var items: seq[kit.MenuItem]
      fillTabMenu(nil, items)
      kit.popupMenu(items)
    tabStripSpace.onDoubleClick = newTab
    if readVerticalTabs(): setVertical(true, save = false)
    moreMenuHooks.add addRecentlyClosed   # rebuilt each time the menu opens
    addMenuSeparator()
    addMenuItem("New incognito window", proc () = openIncognitoWindow(), "Ctrl+Shift+N")
  addShortcut(modCtrl or modShift, 0x74, reopenClosedTab)                     # Ctrl+Shift+T
  addShortcut(modCtrl or modShift, 0x6e, proc () = openIncognitoWindow())     # Ctrl+Shift+N
  discard g_timeout_add(60_000, discardIdleTabs, nil)
