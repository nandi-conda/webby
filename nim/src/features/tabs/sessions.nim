## Saved sessions (sessions_page.dart): the Sessions side panel, the quit prompt that offers to save the open tabs,
## and "Close all tabs and save as session". The store is store.nim. Incognito windows have none of it.

import ../../browser
import store, common
from nimkit/core as kit import nil

var
  panelShowing = false
  panelBox: kit.Widget                              # the panel's content, rebuilt on every change
  undo: tuple[message: string, action: proc ()]     # the last delete, offered back until the next one
  lastTabs: seq[DeviceTab]                          # the last tab closed with the window, for the quit prompt
  lastActive: int

proc openTabsAsSession(): seq[DeviceTab] =
  for t in tabs: result.add DeviceTab(title: t.title, url: t.url)

proc sessionTabCount(list: seq[DeviceTab]): int =
  for t in list:
    if isSessionUrl(t.url): inc result

proc plural(n: int, word: string): string = $n & " " & word & (if n == 1: "" else: "s")

proc nameDialog(title, message, initial, action: string, onName: proc (name: string)) =
  ## Asks for a session name, prefilled and selected.
  kit.prompt(title, (if message.len > 0: message & "\n\nName" else: "Name"), initial,
    proc (ok: bool, value: string) = (if ok: onName(value)), ok = action)

proc restoreSession*(urls: seq[string], active = 0) =
  ## Opens a saved session's tabs next to the current one: a blank current tab takes the first page, the rest open in
  ## the background, and the session's front tab is shown.
  if urls.len == 0: return
  let cur = currentTab()
  let blank = cur.isBlank
  var at = if blank: activeIndex else: activeIndex + 1
  var front: Tab
  for i, url in urls:
    var t: Tab
    if i == 0 and blank and cur != nil:
      t = cur
      t.loadUrl(url)
    else:
      t = openTab(url, focus = false, index = at)
    at = tabs.find(t) + 1   # pinned tabs may have pushed it further along
    if i == active: front = t
  activateTab(if front != nil: front else: currentTab())
  focusPage()

proc closeAllTabs() =
  ## Closes every tab but the pinned ones, leaving one blank tab after them.
  var old: seq[Tab]
  for t in tabs:
    if not t.pinned: old.add t
  discard openTab("about:blank", index = tabs.len)
  for t in old: closeTab(t)

proc saveOpenTabs(closeAll = false) =
  ## Asks for a name and saves the open tabs as a session.
  if incognito: return
  let list = openTabsAsSession()
  let count = sessionTabCount(list)
  if count == 0:
    toast("There are no open pages to save")
    return
  nameDialog(
    if closeAll: "Close all tabs and save as session" else: "Save open tabs as session",
    "The " & plural(count, "open tab") & " can be restored later from Sessions.", defaultSessionName(),
    if closeAll: "Save and close tabs" else: "Save", proc (name: string) =
      let s = saveSession(list, name, activeIndex)
      if s == nil: return
      if closeAll: closeAllTabs()
      toast("Saved session \"" & s.name & "\""))

# ---------------------------------------------------------------------------------------------------------------
# The panel

proc rebuildPanel()

proc linkButton(label: string, action: proc ()): kit.Widget =
  kit.addClass(kit.addClass(kit.button(label, action), "flat"), "webby-link")

proc dimLabel(text: string, small = false): kit.Widget =
  result = kit.addClass(kit.label(text), "dim")
  if small: kit.addClass(result, "small")

proc oneLine(text: string): kit.Widget =
  result = kit.label(text)
  kit.`maxChars=`(result, 200)

proc setUndo(message: string, action: proc ()) =
  undo = (message, action)
  rebuildPanel()

proc tabRow(s: SavedSession, index: int, t: DeviceTab): kit.Widget =
  ## A saved tab: remove button and title, which opens it.
  let host = hostOf(t.url)
  let open = kit.item(oneLine(if t.title.len > 0: t.title elif host.len > 0: host else: t.url),
    onClick = proc () = restoreSession(@[t.url]))
  kit.`tooltip=`(open, t.url)
  result = kit.row(kit.iconButton("close", "Remove from session", size = 14, onClick = proc () =
    let (ok, removed) = removeSessionTab(s, index)
    if ok:
      let label = if removed.title.len == 0: removed.url else: removed.title
      setUndo("Removed \"" & label & "\"", proc () = restoreSessionTab(s, removed, index))), kit.expand(open))
  result.spacing = 2

proc sessionGroup(s: SavedSession): kit.Widget =
  ## One session the way OneTab shows a tab group: size and date, the actions, then every tab.
  let box = kit.addClass(kit.column(), "webby-session")
  box.spacing = 2
  let names = kit.column(kit.addClass(oneLine(s.name), "bold"), dimLabel(sessionCreated(s.savedAt), small = true))
  let head = kit.row(kit.addClass(dimLabel(plural(s.tabs.len, "tab")), "webby-session-count"), kit.expand(names))
  head.spacing = 12
  kit.add(box, head)
  let links = kit.row(
    linkButton("Restore all", proc () =
      var urls: seq[string]
      for t in s.tabs: urls.add t.url
      restoreSession(urls, s.active)),
    linkButton("Delete", proc () =
      deleteSession(s)
      setUndo("Deleted \"" & s.name & "\"", proc () = restoreDeletedSession(s))),
    linkButton("Rename", proc () =
      nameDialog("Rename session", "", s.name, "Rename", proc (n: string) = renameSession(s, n))))
  links.spacing = 6
  kit.add(box, links)
  for i, tab in s.tabs: kit.add(box, tabRow(s, i, tab))
  box

proc fillPanel(box: kit.Widget) =
  let actions = kit.addClass(kit.row(
    kit.iconButton("add", "Save open tabs as session", proc () = saveOpenTabs(), 16),
    kit.iconButton("move_to_inbox_outlined", "Close all tabs and save as session",
      proc () = saveOpenTabs(closeAll = true), 16)), "webby-panel-actions")
  actions.spacing = 2
  let list = sessions()
  if list.len > 0:
    kit.add(actions, kit.iconButton("delete_sweep_outlined", "Delete all sessions", size = 16, onClick = proc () =
      let n = sessions().len
      kit.confirm("Delete all sessions?", "All " & plural(n, "saved session") & " will be deleted. This can't be undone.",
        "Delete", destructive = true, onResult = proc (ok: bool) =
          if not ok: return
          deleteAllSessions()
          undo = ("", nil)
          rebuildPanel())))
  kit.add(box, actions)
  if sessionLoadError.len > 0:
    kit.add(box, kit.addClass(kit.label(sessionLoadError), "webby-error"))
  if undo.action != nil:
    let strip = kit.addClass(kit.row(kit.expand(oneLine(undo.message)),
      kit.button("Undo", proc () =
        let a = undo.action
        undo = ("", nil)
        a()
        rebuildPanel()),
      kit.iconButton("close", "Dismiss", size = 18, onClick = proc () =
        undo = ("", nil)
        rebuildPanel())), "webby-undo")
    strip.spacing = 4
    kit.add(box, strip)
  let body = kit.addClass(kit.column(), "webby-panel-body")
  if list.len == 0:
    kit.add(body, dimLabel("No saved sessions. Save your open tabs with the + above, with \"Close all " &
      "tabs and save as session\". Closing the window saves its tabs here too."))
  else:
    var total = 0
    for s in list: total += s.tabs.len
    kit.add(body, dimLabel("Total: " & plural(total, "tab") & " in " & plural(list.len, "session"), small = true))
  for s in list: kit.add(body, sessionGroup(s))
  kit.add(box, kit.expand(kit.scroll(body)))

proc rebuildPanel() =
  if not panelShowing or panelBox == nil: return
  kit.clear(panelBox)
  fillPanel(panelBox)

proc toggleSessionsPanel*() =
  if panelShowing:
    closeSidePanel()
    return
  panelBox = kit.column()
  panelShowing = true
  fillPanel(panelBox)
  showSidePanel("Sessions", panelBox, 360, proc () =
    panelShowing = false
    panelBox = nil
    undo = ("", nil))

# ---------------------------------------------------------------------------------------------------------------
# Quitting

proc saveOnQuit(): bool =
  ## Closing the window keeps its tabs as a session, without asking. Incognito and app windows never save one, and
  ## a window with only blank tabs saves nothing (saveSession skips those).
  if incognito or appUrl.len > 0: return true
  let list = if tabs.len > 0: openTabsAsSession() else: lastTabs
  let active = if tabs.len > 0: activeIndex else: lastActive
  discard saveSession(list, "", active)
  true

proc install*() =
  # `incognito` is only known once the window starts, after install().
  tabClosedHooks.add proc (t: Tab) =
    if not incognito and tabs.len == 1 and tabs[0] == t:
      lastTabs = openTabsAsSession()
      lastActive = 0
  quitHooks.add saveOnQuit
  sessionListeners.add rebuildPanel
  windowHooks.add proc () =
    if appUrl.len > 0 or incognito: return
    loadCss("""
.webby-link { color: @theme_selected_bg_color; padding: 2px 4px; }
.webby-session { border-top: 1px solid alpha(currentColor, 0.15); padding-top: 8px; margin-top: 8px; }
.webby-undo { padding: 4px 8px; background-color: alpha(currentColor, 0.06); }
.webby-session-count { font-size: x-large; font-weight: 300; }
.webby-panel-actions { margin-left: 8px; }
.webby-panel-body { padding: 8px; }
.webby-error { color: #e5484d; padding: 4px 8px; }
""")
    discard addToolbarButton("layers_outlined", "Sessions", toggleSessionsPanel, "layers", "Sessions")
