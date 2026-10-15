## History (app/lib/src/history): every page a tab shows is a visit in history.jsonl; the History sidebar (Ctrl+H)
## lists them by day with search and delete; "Clear browsing data…" (Ctrl+Shift+Del) clears the engine's data and
## the history; the address bar gets the most visited matches. Incognito records nothing.

import std/[strutils, tables, times, uri]
import ../browser
from nimkit/core as kit import nil
import history/store
import summarize/cache

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
  panelList, panelSearch: kit.Widget
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

proc rangeCombo(): kit.Widget =
  var names: seq[string]
  for r in ranges: names.add r[0]
  kit.dropdown(names, ranges.high)

proc sinceMs(combo: kit.Widget): int64 =
  ## When clearing starts from, or 0 for all time.
  let secs = ranges[clamp(kit.selected(combo), 0, ranges.high)][1]
  if secs == 0: 0'i64 else: nowMs() - secs * 1000

proc dimLabel(text: string): kit.Widget = kit.addClass(kit.label(text), "dim")

proc oneLine(text: string): kit.Widget =
  result = kit.label(text)
  kit.`maxChars=`(result, 200)

proc rangeRow(combo: kit.Widget): kit.Widget =
  result = kit.row(kit.expand(kit.label("Time range")), combo)
  result.spacing = 12

proc clearHistoryDialog() =
  ## Asks how much history to delete and deletes it.
  let combo = rangeCombo()
  let content = kit.column(rangeRow(combo),
    dimLabel("The pages you visited in this time are deleted from this device."))
  content.spacing = 8
  discard kit.dialog("Clear history", content, @["Cancel", "Clear"], destructive = 1, onResult = proc (i: int) =
    if i == 1: clear(sinceMs(combo)))

proc clearBrowsingData*() =
  ## Chrome's "Clear browsing data" dialog (app/lib/src/site_data.dart).
  let combo = rangeCombo()
  let content = kit.column(rangeRow(combo))
  content.spacing = 6
  discard kit.sized(content, 400)
  proc option(label, detail: string): kit.Widget =
    result = kit.check(label, true)
    kit.add(content, result)
    kit.add(content, kit.addClass(dimLabel(detail), "webby-check-detail"))
  let cookies = option("Cookies and other site data", "Signs you out of most sites.")
  let cached = option("Cached images and files", "Pages may load more slowly next time.")
  let history = option("Browsing history", "Clears the pages on the History page and in address bar suggestions.")
  discard kit.dialog("Clear browsing data", content, @["Cancel", "Clear data"], proc (i: int) =
    if i != 1: return
    let since = sinceMs(combo)
    var what = 0
    if kit.checked(cookies): what = what or browsingDataSiteData
    if kit.checked(cached): what = what or browsingDataCache
    if kit.checked(history): what = what or browsingDataHistory
    if what != 0:
      webby_clear_browsing_data(since, what.cint)
      if (what and browsingDataHistory) != 0:
        clear(since)
        clearSummaries(since))

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

proc entryRow(group: seq[HistoryEntry]): kit.Widget =
  ## A visit (or back-to-back visits to one page): click opens it, middle-click opens it in a background tab,
  ## right-click offers that and removing it.
  let e = group[0]
  let t = localTime(e.time)
  let clock = dimLabel(align($t.hour, 2, '0') & ":" & align($t.minute, 2, '0'))
  discard kit.sized(clock, 40)
  let row = kit.item(clock, kit.icon("public"), oneLine(e.label), onClick = proc () = openUrl(e.url))
  if group.len > 1: kit.add(row, dimLabel("×" & $group.len))
  let s = site(e.url)
  kit.add(row, kit.expand(if s.len > 0 and e.title.len > 0: kit.addClass(oneLine(s), "dim") else: kit.spacer()))
  kit.add(row, kit.iconButton("close", "Remove from history", proc () = remove(group), 14))
  row.spacing = 8
  kit.`tooltip=`(row, e.url)
  kit.addClass(row, "webby-history-row")
  row.onMiddle = proc () = openInBackground(e.url)
  row.onContext = proc () =
    kit.popupMenu(@[kit.menuItem("Open in new tab", proc () = openInBackground(e.url)),
                    kit.menuItem("Remove from history", proc () = remove(group))])
  row

proc fillPanel() =
  if panelList == nil: return
  kit.clear(panelList)
  let query = kit.text(panelSearch)
  let found = search(query)
  if found.len == 0:
    kit.add(panelList, kit.addClass(dimLabel(if query.strip.len == 0: "Pages you visit will show up here."
                                             else: "No history matches."), "webby-history-note"))
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
      kit.add(panelList, kit.addClass(kit.addClass(kit.label(label), "bold"), "webby-history-day"))
    var group = @[e]
    inc i
    while i < found.len and samePage(found[i].url, e.url) and dayLabel(localTime(found[i].time), now) == day:
      group.add found[i]
      inc i
    kit.add(panelList, entryRow(group))
    inc groups
  if i < found.len:
    kit.add(panelList, kit.addClass(dimLabel("Older visits aren't listed; search to find them."), "webby-history-note"))

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
  panelSearch = kit.entry("Search history", onChange = proc (s: string) = fillPanel())
  let top = kit.addClass(kit.row(kit.expand(panelSearch),
    kit.iconButton("delete_sweep_outlined", "Clear history", clearHistoryDialog)), "webby-panel-top")
  top.spacing = 4
  panelList = kit.column()
  let body = kit.column(top, kit.expand(kit.scroll(panelList)))
  body.spacing = 4
  panelOpen = true
  showSidePanel("History", body, 400, proc () =
    panelOpen = false
    panelList = nil
    panelSearch = nil)
  fillPanel()
  kit.focus(panelSearch)

# ---------------------------------------------------------------------------------------------------------------

proc historySuggestions(text: string): seq[Suggestion] =
  for s in suggest(text):
    result.add Suggestion(title: s.title, url: s.url, kind: "history")

proc menuWithAccel(label: string, key: uint32, mods: int, action: proc ()) =
  addMenuItem(label, action, shortcutText(mods, key))

proc install*() =
  tabStateHooks.add recordVisit
  tabClosedHooks.add proc (t: Tab) = visits.del cast[pointer](t)
  suggestionProviders.add historySuggestions
  changeHooks.add queueRefresh
  addShortcut(modCtrl, 0x68, showHistory)                                    # Ctrl+H
  addShortcut(modCtrl or modShift, 0xffff, clearBrowsingData)                # Ctrl+Shift+Delete
  windowHooks.add proc () =
    if appUrl.len > 0: return
    loadCss("""
button.webby-history-row { padding: 0 4px 0 10px; min-height: 0; }
.webby-history-row button { padding: 2px; min-height: 0; }
.webby-history-day { margin: 12px 0 4px 10px; }
.webby-history-note { margin-top: 24px; }
.webby-panel-top { margin: 0 4px 0 8px; }
.webby-check-detail { margin-left: 26px; }
""")
    menuWithAccel("History", 0x68, modCtrl, showHistory)
    addMenuSeparator()
    menuWithAccel("Clear browsing data…", 0xffff, modCtrl or modShift, clearBrowsingData)
