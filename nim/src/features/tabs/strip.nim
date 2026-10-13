## The tab strip: pinned tabs (pinned_tabs.json), vertical tabs (tabs.json), the tab right-click menu, reopening
## closed tabs, unloaded tabs and discarding long-hidden ones (main.dart, tab_strip.dart, web_view.dart).

import std/[os, strutils, times]
from std/unicode import toRunes, `$`
import ../../browser
import store, common

proc gtk_accel_label_set_accel(label: Widget, key, mods: cuint) {.importc, cdecl.}

var
  closedTabs*: seq[DeviceTab]   ## most recent last, for Ctrl+Shift+T and "Recently closed"
  vertical = false
  lastActive: Tab
  fixingOrder = false

# ---------------------------------------------------------------------------------------------------------------
# Unloaded tabs: a view that shows a URL and title but loads nothing until the tab is first shown.

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

proc newHiddenView(): View =
  result = webby_view_create(1280, 720, 1.0)
  webby_view_set_visible(result, 0)

proc openUnloadedTab*(url, title: string, index = -1): Tab =
  ## A background tab that loads `url` once it's selected.
  result = adoptView(newHiddenView(), focus = false, index = index)
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
  let old = t.view
  t.view = newHiddenView()
  webby_view_set_message_prefix(t.view, t.messagePrefix.cstring)
  webby_view_destroy(old)
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
# Pinned tabs: small tiles at the start of the strip that survive "Close other tabs" and come back at the next start.

proc pinnedCount*(): int =
  for t in tabs:
    if not t.pinned: break
    inc result

proc styleTab(t: Tab) =
  let close = cast[Widget](g_object_get_data(t.button, "webby-close"))
  if close != nil: gtk_widget_set_visible(close, (not t.pinned).gboolean)
  if t.pinned: addClass(t.button, "webby-pinned-tab") else: removeClass(t.button, "webby-pinned-tab")
  # A 40 px tile with the icon in the middle, like tab_strip.dart's.
  gtk_widget_set_size_request(t.button, (if t.pinned and not vertical: 40 else: -1), -1)
  gtk_widget_set_halign(gtk_bin_get_child(t.button), if t.pinned and not vertical: GTK_ALIGN_CENTER else: GTK_ALIGN_FILL)
  updateTabButton(t)

proc savePinned() =
  if incognito or appUrl.len > 0: return
  var pinned: seq[DeviceTab]
  for t in tabs:
    if t.pinned: pinned.add DeviceTab(title: t.title, url: t.url)
  writePinnedTabs(pinned)

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
  let scroller = gtk_widget_get_parent(gtk_widget_get_parent(tabStrip))
  let parent = gtk_widget_get_parent(tabStripBox)
  discard g_object_ref(tabStripBox)
  if parent != nil: gtk_container_remove(parent, tabStripBox)
  if on:
    gtk_orientable_set_orientation(tabStripBox, GTK_ORIENTATION_VERTICAL)
    gtk_orientable_set_orientation(tabStrip, GTK_ORIENTATION_VERTICAL)
    gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_widget_set_size_request(tabStripBox, 220, -1)
    addClass(tabStripBox, "webby-vertical-tabs")
    gtk_box_pack_start(pageBox, tabStripBox, 0, 0, 0)
    gtk_box_reorder_child(pageBox, tabStripBox, 0)
  else:
    gtk_orientable_set_orientation(tabStripBox, GTK_ORIENTATION_HORIZONTAL)
    gtk_orientable_set_orientation(tabStrip, GTK_ORIENTATION_HORIZONTAL)
    gtk_scrolled_window_set_policy(scroller, GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
    gtk_widget_set_size_request(tabStripBox, -1, -1)
    removeClass(tabStripBox, "webby-vertical-tabs")
    gtk_box_pack_start(mainBox, tabStripBox, 0, 0, 0)
    gtk_box_reorder_child(mainBox, tabStripBox, 0)
  g_object_unref(tabStripBox)
  gtk_widget_show_all(tabStripBox)
  for t in tabs: styleTab(t)

# ---------------------------------------------------------------------------------------------------------------
# Commands

proc newTab*() = discard openTab("")

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

proc shortcutHint*(item: Widget, key: uint32, mods: uint32) =
  ## Shows a key next to a menu item's label.
  gtk_accel_label_set_accel(gtk_bin_get_child(item), key.cuint, mods.cuint)

proc addRecentlyClosed*(menu: Widget, at = -1): seq[Widget] {.discardable.} =
  ## "Recently closed" and the last ten closed tabs, newest first, appended (or inserted at `at`).
  if closedTabs.len == 0: return
  var pos = at
  var added: seq[Widget]
  proc put(item: Widget) =
    added.add item
    if pos >= 0:
      discard g_object_ref(item)
      gtk_container_remove(menu, item)
      gtk_menu_shell_insert(menu, item, pos.cint)
      g_object_unref(item)
      inc pos
  let sep = gtk_separator_menu_item_new()
  gtk_menu_shell_append(menu, sep)
  gtk_widget_show(sep)
  put(sep)
  let header = menuItem(menu, "Recently closed", proc () = discard)
  gtk_widget_set_sensitive(header, 0)
  put(header)
  proc closedItem(c: DeviceTab): Widget =
    menuItem(menu, "   " & shorten(c.title, 50), proc () =
      let j = closedTabs.find(c)
      if j >= 0: closedTabs.delete(j)
      discard openTab(c.url, index = activeIndex + 1))
  for i in countdown(closedTabs.high, max(closedTabs.len - 10, 0)): put(closedItem(closedTabs[i]))
  added

proc disabled(w: Widget, off: bool) = gtk_widget_set_sensitive(w, (not off).gboolean)

proc fillTabMenu*(t: Tab, menu: Widget) =
  ## The strip's right-click menu, for `t` or for no tab (nil) on the strip's empty space.
  shortcutHint(menuItem(menu, "New tab", newTab), 0x74, 4)
  if t != nil:
    let i = tabs.find(t)
    menuSeparator(menu)
    menuItem(menu, "Reload", proc () = (if t.isUnloaded: loadPending(t) else: webby_view_reload(t.view)); wake())
    menuItem(menu, "Duplicate", proc () = duplicateTab(t))
    menuItem(menu, if t.pinned: "Unpin tab" else: "Pin tab", proc () = togglePinned(t))
    menuSeparator(menu)
    let close = menuItem(menu, "Close", proc () = closeTab(t))
    if t == currentTab(): shortcutHint(close, 0x77, 4)
    var others, right = false
    for j, x in tabs:
      if x != t and not x.pinned:
        others = true
        if j > i: right = true
    disabled(menuItem(menu, "Close other tabs", proc () = closeOtherTabs(t)), not others)
    disabled(menuItem(menu, if vertical: "Close tabs below" else: "Close tabs to the right",
      proc () = closeOtherTabs(t, toTheRight = true)), not right)
  menuSeparator(menu)
  let reopen = menuItem(menu, "Reopen closed tab", reopenClosedTab)
  shortcutHint(reopen, 0x74, 5)
  disabled(reopen, closedTabs.len == 0)
  addRecentlyClosed(menu)
  menuSeparator(menu)
  let v = gtk_check_menu_item_new_with_label("Vertical tabs")
  gtk_check_menu_item_set_active(v, vertical.gboolean)
  connectAction(v, "activate", proc () = setVertical(not vertical))
  gtk_menu_shell_append(menu, v)
  gtk_widget_show(v)

proc onStripPress(w: Widget, e: GEvent, d: pointer): gboolean {.cdecl.} =
  var b: cuint
  discard gdk_event_get_button(e, addr b)
  # Double-clicking the strip's empty space opens a new tab, as in tab_strip.dart. Tabs keep their own clicks.
  if gdk_event_get_event_type(e) == GDK_2BUTTON_PRESS and b == 1:
    newTab()
    return 1
  if gdk_event_get_event_type(e) != GDK_BUTTON_PRESS or b != 3: return 0
  let menu = gtk_menu_new()
  fillTabMenu(nil, menu)
  gtk_widget_show_all(menu)
  gtk_menu_popup_at_pointer(menu, e)
  1

# ---------------------------------------------------------------------------------------------------------------

var recentAnchor: Widget   # the ⋮ menu's "New incognito window" item

proc onMoreMenuShow(w: Widget, d: pointer) {.cdecl.} =
  # The recently closed tabs, rebuilt each time the menu opens, go before "New incognito window".
  for c in children(moreMenu):
    if g_object_get_data(c, "webby-recent") != nil: gtk_widget_destroy(c)
  let at = children(moreMenu).find(recentAnchor) - 1
  for item in addRecentlyClosed(moreMenu, at): g_object_set_data(item, "webby-recent", cast[pointer](1))

proc startTabs(urls: seq[string]): bool =
  ## Desktop doesn't keep the open tabs, but pinned ones come back (unloaded until selected), ahead of the start page.
  if incognito: return false
  let saved = readTabsFile(pinnedTabsFile())
  if saved.tabs.len == 0: return false
  for d in saved.tabs:
    let t = openUnloadedTab(d.url, d.title)
    t.pinned = true
    styleTab(t)
  let first = openTab(if urls.len > 0: urls[0] else: homePage)
  for u in urls[min(1, urls.len) .. ^1]: discard openTab(u, focus = false)
  activateTab(first)
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
  tabStateHooks.add proc (t: Tab) =
    if t.isUnloaded: showPending(t)   # a fresh view reports an empty page; keep showing what it will load
    if t.pinned:
      styleTab(t)
      savePinned()
  tabStripHooks.add proc () =
    fixOrder()
    savePinned()
  tabMenuHooks.add fillTabMenu
  windowHooks.add proc () =
    loadCss("""
.webby-pinned-tab { padding: 4px 0; }
.webby-vertical-tabs { border-right: 1px solid alpha(currentColor, 0.15); }
.webby-vertical-tabs .webby-tab { border-radius: 6px; margin: 1px 4px; }
.webby-vertical-tabs .webby-tab > box { margin: 4px 0 4px 6px; }
.webby-toast { background-color: #323232; color: #f0f0f0; }
""")
    let viewport = gtk_widget_get_parent(tabStrip)   # right-clicks on the strip's empty space
    gtk_widget_add_events(viewport, GDK_BUTTON_PRESS_MASK)
    connect(viewport, "button-press-event", onStripPress)
    if readVerticalTabs(): setVertical(true, save = false)
    addMenuSeparator()
    recentAnchor = addMenuItem("New incognito window", proc () = openIncognitoWindow())
    shortcutHint(recentAnchor, 0x6e, 5)
    connect(moreMenu, "show", onMoreMenuShow)
  addShortcut(modCtrl or modShift, 0x74, reopenClosedTab)                     # Ctrl+Shift+T
  addShortcut(modCtrl or modShift, 0x6e, proc () = openIncognitoWindow())     # Ctrl+Shift+N
  discard g_timeout_add(60_000, discardIdleTabs, nil)
