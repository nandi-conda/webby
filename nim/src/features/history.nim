## History (app/lib/src/history): every page a tab shows is a visit in history.jsonl; the History sidebar (Ctrl+H)
## lists them by day with search and delete; "Clear browsing data…" (Ctrl+Shift+Del) clears the engine's data and
## the history; the address bar gets the most visited matches. Incognito records nothing.

import std/[strutils, tables, times, uri]
import ../browser
import history/store
import summarize/cache

{.push cdecl, importc.}
proc gtk_combo_box_text_new(): Widget
proc gtk_combo_box_text_append_text(c: Widget, text: cstring)
proc gtk_combo_box_set_active(c: Widget, i: cint)
proc gtk_combo_box_get_active(c: Widget): cint
proc gtk_list_box_get_row_at_y(l: Widget, y: cint): Widget
proc gtk_list_box_row_set_activatable(r: Widget, on: gboolean)
proc gtk_list_box_row_set_selectable(r: Widget, on: gboolean)
proc gtk_accel_label_set_accel(l: Widget, key: cuint, mods: cuint)
proc gtk_box_set_spacing(b: Widget, s: cint)
proc gtk_dialog_get_widget_for_response(d: Widget, r: cint): Widget
{.pop.}

const
  ranges = [("Last hour", 3600'i64), ("Last 24 hours", 86400'i64), ("Last 7 days", 7 * 86400'i64),
    ("Last 4 weeks", 28 * 86400'i64), ("All time", 0'i64)]
  maxRows = 400
  months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
    "November", "December"]
  weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

var
  visits: Table[pointer, tuple[url: string, visit: HistoryEntry]]  ## per tab: the address last recorded
  panelOpen = false
  panelList, panelSearch: Widget
  rowGroups: seq[seq[HistoryEntry]]   ## per list row: the visits it stands for (empty for day headings)
  refreshQueued = false

# ---------------------------------------------------------------------------------------------------------------
# Recording

proc recordVisit(t: Tab) =
  ## Each new page address a tab shows is a visit; its title is filled in when it arrives.
  if t.url.len == 0: return
  let key = cast[pointer](t)
  let last = visits.getOrDefault(key)
  if t.url != last.url:
    visits[key] = (t.url, record(t.url, t.title))
  elif last.visit != nil and t.title.len > 0:
    setTitle(last.visit, t.title)

# ---------------------------------------------------------------------------------------------------------------
# Opening pages from the history

proc isBlank(t: Tab): bool = t == nil or t.url.len == 0 or t.url == "about:blank"

proc openUrl(url: string) =
  ## History opens pages in a new tab, reusing a blank one.
  let t = currentTab()
  if isBlank(t):
    if t == nil: discard openTab(url) else: t.loadUrl(url)
  else: discard openTab(url)

proc openInBackground(url: string) =
  if tabs.len > 0: discard openTab(url, focus = false, index = activeIndex + 1)

# ---------------------------------------------------------------------------------------------------------------
# Dialogs

proc rangeCombo(): Widget =
  result = gtk_combo_box_text_new()
  for r in ranges: gtk_combo_box_text_append_text(result, r[0].cstring)
  gtk_combo_box_set_active(result, ranges.high.cint)

proc sinceMs(combo: Widget): int64 =
  ## When clearing starts from, or 0 for all time.
  let secs = ranges[clamp(gtk_combo_box_get_active(combo).int, 0, ranges.high)][1]
  if secs == 0: 0'i64 else: nowMs() - secs * 1000

proc dimLabel(text: string): Widget =
  result = gtk_label_new(text.cstring)
  gtk_label_set_xalign(result, 0)
  gtk_label_set_line_wrap(result, 1)
  addClass(result, "dim-label")

proc clearHistoryDialog() =
  ## Asks how much history to delete and deletes it.
  let d = gtk_dialog_new_with_buttons("Clear history", window, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL,
    "C_lear", GTK_RESPONSE_OK, nil)
  let box = gtk_dialog_get_content_area(d)
  gtk_container_set_border_width(box, 12)
  gtk_box_set_spacing(box, 8)
  let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)
  gtk_box_pack_start(row, gtk_label_new("Time range"), 0, 0, 0)
  let combo = rangeCombo()
  gtk_box_pack_end(row, combo, 0, 0, 0)
  gtk_box_pack_start(box, row, 0, 0, 0)
  gtk_box_pack_start(box, dimLabel("The pages you visited in this time are deleted from this device."), 0, 0, 0)
  addClass(gtk_dialog_get_widget_for_response(d, GTK_RESPONSE_OK), "destructive-action")
  gtk_widget_show_all(d)
  if gtk_dialog_run(d) == GTK_RESPONSE_OK: clear(sinceMs(combo))
  gtk_widget_destroy(d)

proc clearBrowsingData*() =
  ## Chrome's "Clear browsing data" dialog (app/lib/src/site_data.dart).
  let d = gtk_dialog_new_with_buttons("Clear browsing data", window, GTK_DIALOG_MODAL, "_Cancel",
    GTK_RESPONSE_CANCEL, "C_lear data", GTK_RESPONSE_OK, nil)
  gtk_window_set_default_size(d, 420, -1)
  let box = gtk_dialog_get_content_area(d)
  gtk_container_set_border_width(box, 12)
  gtk_box_set_spacing(box, 6)
  let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)
  gtk_box_pack_start(row, gtk_label_new("Time range"), 0, 0, 0)
  let combo = rangeCombo()
  gtk_box_pack_end(row, combo, 0, 0, 0)
  gtk_box_pack_start(box, row, 0, 0, 4)
  proc option(label, detail: string): Widget =
    result = gtk_check_button_new_with_label(label.cstring)
    gtk_toggle_button_set_active(result, 1)
    gtk_box_pack_start(box, result, 0, 0, 0)
    let l = dimLabel(detail)
    gtk_widget_set_margin_start(l, 26)
    gtk_box_pack_start(box, l, 0, 0, 0)
  let cookies = option("Cookies and other site data", "Signs you out of most sites.")
  let cached = option("Cached images and files", "Pages may load more slowly next time.")
  let history = option("Browsing history", "Clears the pages on the History page and in address bar suggestions.")
  addClass(gtk_dialog_get_widget_for_response(d, GTK_RESPONSE_OK), "suggested-action")
  gtk_widget_show_all(d)
  if gtk_dialog_run(d) == GTK_RESPONSE_OK:
    let since = sinceMs(combo)
    var what = 0
    if gtk_toggle_button_get_active(cookies) != 0: what = what or browsingDataSiteData
    if gtk_toggle_button_get_active(cached) != 0: what = what or browsingDataCache
    if gtk_toggle_button_get_active(history) != 0: what = what or browsingDataHistory
    if what != 0:
      webby_clear_browsing_data(since, what.cint)
      if (what and browsingDataHistory) != 0:
        clear(since)
        clearSummaries(since)
  gtk_widget_destroy(d)

# ---------------------------------------------------------------------------------------------------------------
# The History sidebar

proc dayLabel(t: DateTime, now: DateTime): string =
  ## "Today - Monday, October 12, 2026", "Yesterday - …", or the date.
  let date = weekdays[t.weekday.ord] & ", " & months[t.month.ord - 1] & " " & $t.monthday & ", " & $t.year
  let today = dateTime(now.year, now.month, now.monthday, zone = local())
  let that = dateTime(t.year, t.month, t.monthday, zone = local())
  let daysAgo = (today - that).inHours div 24
  if daysAgo == 0: "Today - " & date elif daysAgo == 1: "Yesterday - " & date else: date

proc localTime(ms: int64): DateTime = fromUnix(ms div 1000).local

proc site(url: string): string =
  try:
    result = parseUri(url).hostname
    if result.startsWith("www."): result = result[4 .. ^1]
  except CatchableError: discard

proc onRemoveClicked(b: Widget, data: pointer) {.cdecl.} =
  let i = cast[int](data)
  if i in 0 ..< rowGroups.len and rowGroups[i].len > 0: remove(rowGroups[i])

proc entryRow(group: seq[HistoryEntry], index: int): Widget =
  let e = group[0]
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
  gtk_widget_set_margin_start(box, 10)
  gtk_widget_set_margin_end(box, 4)
  let t = localTime(e.time)
  let clock = dimLabel(align($t.hour, 2, '0') & ":" & align($t.minute, 2, '0'))
  gtk_label_set_line_wrap(clock, 0)
  gtk_label_set_width_chars(clock, 5)
  gtk_box_pack_start(box, clock, 0, 0, 0)
  gtk_box_pack_start(box, gtk_image_new_from_icon_name("text-html-symbolic", GTK_ICON_SIZE_MENU), 0, 0, 0)
  let title = gtk_label_new(e.label.cstring)
  gtk_label_set_ellipsize(title, PANGO_ELLIPSIZE_END)
  gtk_label_set_xalign(title, 0)
  gtk_box_pack_start(box, title, 0, 1, 0)
  if group.len > 1:
    let n = dimLabel("×" & $group.len)
    gtk_label_set_line_wrap(n, 0)
    gtk_box_pack_start(box, n, 0, 0, 0)
  let s = site(e.url)
  if s.len > 0 and e.title.len > 0:
    let l = dimLabel(s)
    gtk_label_set_line_wrap(l, 0)
    gtk_label_set_ellipsize(l, PANGO_ELLIPSIZE_END)
    gtk_box_pack_start(box, l, 1, 1, 0)
  else:
    gtk_box_pack_start(box, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0), 1, 1, 0)
  let remove = gtk_button_new_from_icon_name("window-close-symbolic", GTK_ICON_SIZE_MENU)
  gtk_button_set_relief(remove, GTK_RELIEF_NONE)
  gtk_widget_set_tooltip_text(remove, "Remove from history")
  connect(remove, "clicked", onRemoveClicked, cast[pointer](index))
  gtk_box_pack_end(box, remove, 0, 0, 0)
  gtk_widget_set_tooltip_text(box, e.url.cstring)
  box

proc fillPanel() =
  if panelList == nil: return
  clearChildren(panelList)
  rowGroups.setLen 0
  let query = $gtk_entry_get_text(panelSearch)
  let found = search(query)
  proc addRow(child: Widget, group: seq[HistoryEntry]) =
    let row = gtk_list_box_row_new()
    gtk_container_add(row, child)
    if group.len == 0:
      gtk_list_box_row_set_activatable(row, 0)
      gtk_list_box_row_set_selectable(row, 0)
    gtk_container_add(panelList, row)
    rowGroups.add group
  if found.len == 0:
    let l = dimLabel(if query.strip.len == 0: "Pages you visit will show up here." else: "No history matches.")
    gtk_widget_set_margin_top(l, 24)
    gtk_label_set_xalign(l, 0.5)
    addRow(l, @[])
  # Split into days, and each day into rows: back-to-back visits to the same page are one row.
  let now = now()
  var day = ""
  var groups = 0
  var i = 0
  while i < found.len and groups < maxRows:
    let e = found[i]
    let label = dayLabel(localTime(e.time), now)
    if label != day:
      day = label
      let h = gtk_label_new(nil)
      gtk_label_set_markup(h, cstring("<b>" & escapeMarkup(label) & "</b>"))
      gtk_label_set_xalign(h, 0)
      gtk_widget_set_margin_start(h, 10)
      gtk_widget_set_margin_top(h, 12)
      gtk_widget_set_margin_bottom(h, 4)
      addRow(h, @[])
    var group = @[e]
    inc i
    while i < found.len and samePage(found[i].url, e.url) and dayLabel(localTime(found[i].time), now) == day:
      group.add found[i]
      inc i
    addRow(entryRow(group, rowGroups.len), group)
    inc groups
  if i < found.len:
    let more = dimLabel("Older visits aren't listed; search to find them.")
    gtk_widget_set_margin_top(more, 12)
    gtk_label_set_xalign(more, 0.5)
    addRow(more, @[])
  gtk_widget_show_all(panelList)

proc onPanelRow(l: Widget, row: Widget, data: pointer) {.cdecl.} =
  let i = gtk_list_box_row_get_index(row)
  if i in 0 ..< rowGroups.len and rowGroups[i].len > 0: openUrl(rowGroups[i][0].url)

proc onPanelButton(l: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  ## Middle-click opens a visit in a background tab; right-click offers that and removing it.
  var b: cuint
  discard gdk_event_get_button(ev, addr b)
  if b != 2 and b != 3 or gdk_event_get_event_type(ev) != GDK_BUTTON_PRESS: return 0
  var x, y: cdouble
  discard gdk_event_get_coords(ev, addr x, addr y)
  let row = gtk_list_box_get_row_at_y(panelList, y.cint)
  if row == nil: return 0
  let i = gtk_list_box_row_get_index(row)
  if i notin 0 ..< rowGroups.len or rowGroups[i].len == 0: return 0
  let group = rowGroups[i]
  if b == 2:
    openInBackground(group[0].url)
    return 1
  let menu = gtk_menu_new()
  menuItem(menu, "Open in new tab", proc () = openInBackground(group[0].url))
  menuItem(menu, "Remove from history", proc () = remove(group))
  gtk_menu_attach_to_widget(menu, panelList, nil)
  gtk_widget_show_all(menu)
  gtk_menu_popup_at_pointer(menu, ev)
  1

proc onSearchChanged(e: Widget, data: pointer) {.cdecl.} = fillPanel()

proc queueRefresh() =
  if not panelOpen or refreshQueued: return
  refreshQueued = true
  discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} =
    refreshQueued = false
    if panelOpen: fillPanel()
    0, nil)

proc showHistory*() =
  closeSidePanel()
  # Other windows may have added visits since this one last read the file.
  reload()
  let body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
  let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
  gtk_widget_set_margin_start(top, 8)
  gtk_widget_set_margin_end(top, 4)
  panelSearch = gtk_search_entry_new()
  gtk_entry_set_placeholder_text(panelSearch, "Search history")
  connect(panelSearch, "search-changed", onSearchChanged)
  gtk_box_pack_start(top, panelSearch, 1, 1, 0)
  gtk_box_pack_start(top, iconButton("edit-clear-all-symbolic", "Clear history", clearHistoryDialog), 0, 0, 0)
  gtk_box_pack_start(body, top, 0, 0, 0)
  let scroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  panelList = gtk_list_box_new()
  gtk_list_box_set_selection_mode(panelList, GTK_SELECTION_NONE)
  connect(panelList, "row-activated", onPanelRow)
  connect(panelList, "button-press-event", onPanelButton)
  gtk_container_add(scroller, panelList)
  gtk_box_pack_start(body, scroller, 1, 1, 0)
  panelOpen = true
  showSidePanel("History", body, 400, proc () =
    panelOpen = false
    panelList = nil
    panelSearch = nil)
  fillPanel()
  gtk_widget_grab_focus(panelSearch)

# ---------------------------------------------------------------------------------------------------------------

proc historySuggestions(text: string): seq[Suggestion] =
  for s in suggest(text):
    result.add Suggestion(title: s.title, url: s.url, kind: "history")

proc menuWithAccel(label: string, key: uint32, mods: uint32, action: proc ()) =
  let item = addMenuItem(label, action)
  gtk_accel_label_set_accel(gtk_bin_get_child(item), key.cuint, mods.cuint)

proc install*() =
  tabStateHooks.add recordVisit
  tabClosedHooks.add proc (t: Tab) = visits.del cast[pointer](t)
  suggestionProviders.add historySuggestions
  changeHooks.add queueRefresh
  addShortcut(modCtrl, 0x68, showHistory)                                    # Ctrl+H
  addShortcut(modCtrl or modShift, 0xffff, clearBrowsingData)                # Ctrl+Shift+Delete
  windowHooks.add proc () =
    if appUrl.len > 0: return
    menuWithAccel("History", 0x68, GDK_CONTROL_MASK, showHistory)
    addMenuSeparator()
    menuWithAccel("Clear browsing data…", 0xffff, GDK_CONTROL_MASK or GDK_SHIFT_MASK, clearBrowsingData)
