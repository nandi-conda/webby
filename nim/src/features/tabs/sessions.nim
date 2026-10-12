## Saved sessions (sessions_page.dart): the Sessions side panel, the quit prompt that offers to save the open tabs,
## and "Close all tabs and save as session". The store is store.nim. Incognito windows have none of it.

import ../../browser
import store, common, strip

var
  panelShowing = false
  panelBox: Widget                                  # the panel's content, rebuilt on every change
  undo: tuple[message: string, action: proc ()]     # the last delete, offered back until the next one
  lastTabs: seq[DeviceTab]                          # the last tab closed with the window, for the quit prompt
  lastActive: int

proc openTabsAsSession(): seq[DeviceTab] =
  for t in tabs: result.add DeviceTab(title: t.title, url: t.url)

proc sessionTabCount(list: seq[DeviceTab]): int =
  for t in list:
    if isSessionUrl(t.url): inc result

proc plural(n: int, word: string): string = $n & " " & word & (if n == 1: "" else: "s")

proc nameDialog(title, message, initial, action: string): (bool, string) =
  ## Asks for a session name, prefilled and selected.
  let d = gtk_dialog_new_with_buttons(title.cstring, window, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL,
    action.cstring, GTK_RESPONSE_OK, nil)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  let box = gtk_dialog_get_content_area(d)
  gtk_container_set_border_width(box, 12)
  if message.len > 0:
    let l = gtk_label_new(message.cstring)
    gtk_label_set_xalign(l, 0)
    gtk_label_set_line_wrap(l, 1)
    gtk_box_pack_start(box, l, 0, 0, 4)
  let n = gtk_label_new("Name")
  gtk_label_set_xalign(n, 0)
  gtk_box_pack_start(box, n, 0, 0, 2)
  let e = gtk_entry_new()
  gtk_entry_set_text(e, initial.cstring)
  gtk_entry_set_activates_default(e, 1)
  gtk_entry_set_width_chars(e, 36)
  gtk_box_pack_start(box, e, 0, 0, 2)
  gtk_widget_show_all(d)
  let ok = gtk_dialog_run(d) == GTK_RESPONSE_OK
  result = (ok, $gtk_entry_get_text(e))
  gtk_widget_destroy(d)

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
  let (ok, name) = nameDialog(
    if closeAll: "Close all tabs and save as session" else: "Save open tabs as session",
    "The " & plural(count, "open tab") & " can be restored later from Sessions.", defaultSessionName(),
    if closeAll: "Save and close tabs" else: "_Save")
  if not ok: return
  let s = saveSession(list, name, activeIndex)
  if s == nil: return
  if closeAll: closeAllTabs()
  toast("Saved session \"" & s.name & "\"")

# ---------------------------------------------------------------------------------------------------------------
# The panel

proc rebuildPanel()

proc linkButton(label: string, action: proc ()): Widget =
  result = gtk_button_new_with_label(label.cstring)
  gtk_button_set_relief(result, GTK_RELIEF_NONE)
  addClass(result, "webby-link")
  connectAction(result, "clicked", action)

proc smallIconButton(icon, tooltip: string, action: proc ()): Widget =
  result = gtk_button_new_from_icon_name(icon.cstring, GTK_ICON_SIZE_MENU)
  gtk_button_set_relief(result, GTK_RELIEF_NONE)
  gtk_widget_set_tooltip_text(result, tooltip.cstring)
  connectAction(result, "clicked", action)

proc dimLabel(text: string, small = false): Widget =
  result = gtk_label_new(text.cstring)
  gtk_label_set_xalign(result, 0)
  gtk_label_set_line_wrap(result, 1)
  addClass(result, "dim-label")
  if small: addClass(result, "webby-small")

proc setUndo(message: string, action: proc ()) =
  undo = (message, action)
  rebuildPanel()

proc tabRow(s: SavedSession, index: int, t: DeviceTab): Widget =
  ## A saved tab: remove button and title, which opens it.
  result = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  gtk_box_pack_start(result, smallIconButton("window-close-symbolic", "Remove from session", proc () =
    let (ok, removed) = removeSessionTab(s, index)
    if ok:
      let label = if removed.title.len == 0: removed.url else: removed.title
      setUndo("Removed \"" & label & "\"", proc () = restoreSessionTab(s, removed, index))), 0, 0, 0)
  let host = hostOf(t.url)
  let open = gtk_button_new_with_label(cstring(if t.title.len > 0: t.title elif host.len > 0: host else: t.url))
  gtk_button_set_relief(open, GTK_RELIEF_NONE)
  gtk_widget_set_tooltip_text(open, t.url.cstring)
  let l = gtk_bin_get_child(open)
  gtk_label_set_xalign(l, 0)
  gtk_label_set_ellipsize(l, PANGO_ELLIPSIZE_END)
  connectAction(open, "clicked", proc () = restoreSession(@[t.url]))
  gtk_box_pack_start(result, open, 1, 1, 0)

proc sessionGroup(s: SavedSession): Widget =
  ## One session the way OneTab shows a tab group: size and date, the actions, then every tab.
  let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)
  addClass(box, "webby-session")
  let head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)
  let count = gtk_label_new("")
  gtk_label_set_markup(count, cstring("<span size='x-large' weight='light'>" & plural(s.tabs.len, "tab") & "</span>"))
  addClass(count, "dim-label")
  gtk_box_pack_start(head, count, 0, 0, 0)
  let names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  let name = gtk_label_new("")
  gtk_label_set_markup(name, cstring("<b>" & escapeMarkup(s.name) & "</b>"))
  gtk_label_set_xalign(name, 0)
  gtk_label_set_ellipsize(name, PANGO_ELLIPSIZE_END)
  gtk_box_pack_start(names, name, 0, 0, 0)
  gtk_box_pack_start(names, dimLabel(sessionCreated(s.savedAt), small = true), 0, 0, 0)
  gtk_box_pack_start(head, names, 1, 1, 0)
  gtk_box_pack_start(box, head, 0, 0, 0)
  let links = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  gtk_box_pack_start(links, linkButton("Restore all", proc () =
    var urls: seq[string]
    for t in s.tabs: urls.add t.url
    restoreSession(urls, s.active)), 0, 0, 0)
  gtk_box_pack_start(links, linkButton("Delete", proc () =
    deleteSession(s)
    setUndo("Deleted \"" & s.name & "\"", proc () = restoreDeletedSession(s))), 0, 0, 0)
  gtk_box_pack_start(links, linkButton("Rename", proc () =
    let (ok, n) = nameDialog("Rename session", "", s.name, "_Rename")
    if ok: renameSession(s, n)), 0, 0, 0)
  gtk_box_pack_start(box, links, 0, 0, 0)
  for i, tab in s.tabs: gtk_box_pack_start(box, tabRow(s, i, tab), 0, 0, 0)
  box

proc fillPanel(box: Widget) =
  let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  gtk_widget_set_margin_start(actions, 8)
  gtk_box_pack_start(actions, smallIconButton("list-add-symbolic", "Save open tabs as session",
    proc () = saveOpenTabs()), 0, 0, 0)
  gtk_box_pack_start(actions, smallIconButton("document-save-symbolic", "Close all tabs and save as session",
    proc () = saveOpenTabs(closeAll = true)), 0, 0, 0)
  let list = sessions()
  if list.len > 0:
    gtk_box_pack_start(actions, smallIconButton("edit-delete-symbolic", "Delete all sessions", proc () =
      let n = sessions().len
      if confirm("Delete all sessions?", "All " & plural(n, "saved session") & " will be deleted. This can't be undone."):
        deleteAllSessions()
        undo = ("", nil)
        rebuildPanel()), 0, 0, 0)
  gtk_box_pack_start(box, actions, 0, 0, 0)
  if sessionLoadError.len > 0:
    let e = gtk_label_new(sessionLoadError.cstring)
    gtk_label_set_line_wrap(e, 1)
    addClass(e, "webby-error")
    gtk_box_pack_start(box, e, 0, 0, 4)
  if undo.action != nil:
    let strip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
    addClass(strip, "webby-undo")
    let m = gtk_label_new(undo.message.cstring)
    gtk_label_set_xalign(m, 0)
    gtk_label_set_ellipsize(m, PANGO_ELLIPSIZE_END)
    gtk_box_pack_start(strip, m, 1, 1, 0)
    let b = gtk_button_new_with_label("Undo")
    connectAction(b, "clicked", proc () =
      let a = undo.action
      undo = ("", nil)
      a()
      rebuildPanel())
    gtk_box_pack_start(strip, b, 0, 0, 0)
    gtk_box_pack_start(strip, smallIconButton("window-close-symbolic", "Dismiss", proc () =
      undo = ("", nil)
      rebuildPanel()), 0, 0, 0)
    gtk_box_pack_start(box, strip, 0, 0, 0)
  let scroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  let body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_container_set_border_width(body, 8)
  if list.len == 0:
    gtk_box_pack_start(body, dimLabel("No saved sessions. Save your open tabs with the + above, with \"Close all " &
      "tabs and save as session\", or when you close the window."), 0, 0, 8)
  else:
    var total = 0
    for s in list: total += s.tabs.len
    gtk_box_pack_start(body, dimLabel("Total: " & plural(total, "tab") & " in " & plural(list.len, "session"),
      small = true), 0, 0, 2)
  for s in list: gtk_box_pack_start(body, sessionGroup(s), 0, 0, 0)
  let ask = gtk_check_button_new_with_label("Ask to save open tabs when closing the window")
  gtk_toggle_button_set_active(ask, askOnQuit().gboolean)
  connectAction(ask, "toggled", proc () = setAskOnQuit(gtk_toggle_button_get_active(ask) != 0))
  gtk_widget_set_margin_top(ask, 14)
  gtk_box_pack_start(body, ask, 0, 0, 0)
  gtk_container_add(scroller, body)
  gtk_box_pack_start(box, scroller, 1, 1, 0)

proc rebuildPanel() =
  if not panelShowing or panelBox == nil: return
  clearChildren(panelBox)
  fillPanel(panelBox)
  gtk_widget_show_all(panelBox)

proc toggleSessionsPanel*() =
  if panelShowing:
    closeSidePanel()
    return
  panelBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  panelShowing = true
  fillPanel(panelBox)
  showSidePanel("Sessions", panelBox, 360, proc () =
    panelShowing = false
    panelBox = nil
    undo = ("", nil))

# ---------------------------------------------------------------------------------------------------------------
# Quitting

proc askSaveOnQuit(): bool =
  ## Closing the window asks whether to keep its tabs as a session. false = Cancel (stay open).
  let list = if tabs.len > 0: openTabsAsSession() else: lastTabs
  let active = if tabs.len > 0: activeIndex else: lastActive
  let count = sessionTabCount(list)
  if incognito or appUrl.len > 0 or not askOnQuit() or count == 0: return true
  let d = gtk_dialog_new_with_buttons("Save open tabs as a session?", window, GTK_DIALOG_MODAL,
    "_Cancel", GTK_RESPONSE_CANCEL, "Don't save", GTK_RESPONSE_NO, "Save and close", GTK_RESPONSE_OK, nil)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  let box = gtk_dialog_get_content_area(d)
  gtk_container_set_border_width(box, 12)
  let m = gtk_label_new(cstring("You can restore the " & plural(count, "tab") & " later from Sessions."))
  gtk_label_set_xalign(m, 0)
  gtk_box_pack_start(box, m, 0, 0, 4)
  let n = gtk_label_new("Name")
  gtk_label_set_xalign(n, 0)
  gtk_box_pack_start(box, n, 0, 0, 2)
  let e = gtk_entry_new()
  gtk_entry_set_text(e, defaultSessionName().cstring)
  gtk_entry_set_activates_default(e, 1)
  gtk_box_pack_start(box, e, 0, 0, 2)
  let dontAsk = gtk_check_button_new_with_label("Don't ask again")
  gtk_box_pack_start(box, dontAsk, 0, 0, 4)
  gtk_widget_show_all(d)
  let r = gtk_dialog_run(d)
  let name = $gtk_entry_get_text(e)
  let stop = gtk_toggle_button_get_active(dontAsk) != 0
  gtk_widget_destroy(d)
  # Closing the dialog or Escape keeps the window open.
  if r != GTK_RESPONSE_OK and r != GTK_RESPONSE_NO:
    # Closing the last tab closed the window; staying open brings that tab back.
    if tabs.len == 0:
      for t in lastTabs:
        if closedTabs.len > 0 and closedTabs[^1].url == t.url: discard closedTabs.pop
        discard openTab(t.url, focus = false)
      if tabs.len == 0: discard openTab("")
      activateTab(clamp(lastActive, 0, tabs.high))
    return false
  if stop: setAskOnQuit(false)
  if r == GTK_RESPONSE_OK: discard saveSession(list, name, active)
  true

proc install*() =
  # `incognito` is only known once the window starts, after install().
  tabClosedHooks.add proc (t: Tab) =
    if not incognito and tabs.len == 1 and tabs[0] == t:
      lastTabs = openTabsAsSession()
      lastActive = 0
  quitHooks.add askSaveOnQuit
  sessionListeners.add rebuildPanel
  windowHooks.add proc () =
    if appUrl.len > 0 or incognito: return
    loadCss("""
.webby-link { color: @theme_selected_bg_color; padding: 2px 4px; }
.webby-small { font-size: smaller; }
.webby-session { border-top: 1px solid alpha(currentColor, 0.15); padding-top: 8px; margin-top: 8px; }
.webby-undo { padding: 4px 8px; background-color: alpha(currentColor, 0.06); }
.webby-error { color: #e5484d; padding: 4px 8px; }
""")
    discard addToolbarButton("view-paged-symbolic", "Sessions", toggleSessionsPanel)
