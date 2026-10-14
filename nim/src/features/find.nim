## Find in page: Ctrl+F (or ⋮ > Find in page) opens a bar under the page with the query, "n of m", previous/next
## and close. Enter / F3 / Ctrl+G go to the next match, Shift with them to the previous one, Esc closes the bar.
## Ladybird does the search when the runtime has webby_view_find (every match highlighted); older runtimes get
## the page script in app/lib/src/find_in_page.dart, shared with the Flutter app.

import std/strutils
import ../browser

const findScript = block:
  let dart = staticRead("../../../app/lib/src/find_in_page.dart")
  let start = dart.find("r'''") + 4
  dart[start ..< dart.find("'''", start)]

var
  bar, entry, countLabel, caseButton: Widget
  shownFor: Tab          ## the tab the bar searches (nil while it is hidden)
  scriptCurrent, scriptTotal: int  ## the page script's last report
  scriptDefinedFor: string  ## url the page script was last defined in

proc js(s: string): string = $(%s)

proc query(): string = $gtk_entry_get_text(entry)
proc caseSensitive(): bool = gtk_toggle_button_get_active(caseButton) != 0

proc showCount(current, total: int) =
  let q = query()
  gtk_label_set_text(countLabel, (if q.len == 0: "" elif total == 0: "No matches" else: $current & " of " & $total).cstring)
  if q.len > 0 and total == 0: addClass(entry, "error") else: removeClass(entry, "error")

proc ensureScript(t: Tab) =
  if scriptDefinedFor != t.url:
    t.runJs(findScript.replace("__WEBBY_FIND_PREFIX__", js(t.messagePrefix)))
    scriptDefinedFor = t.url

proc search(t: Tab) =
  if t == nil: return
  let q = query()
  if hasNativeFind():
    webby_view_find(t.view, q.cstring, caseSensitive().cint)
  else:
    ensureScript(t)
    t.runJs("window.__webbyFind && window.__webbyFind.find(" & js(q) & ", " & $caseSensitive() & ");")
  if q.len == 0: showCount(0, 0)
  wake()

proc step(forward: bool) =
  let t = shownFor
  if t == nil: return
  if hasNativeFind():
    if forward: webby_view_find_next(t.view) else: webby_view_find_previous(t.view)
  else:
    ensureScript(t)
    t.runJs("window.__webbyFind && window.__webbyFind." & (if forward: "next" else: "previous") & "();")
  wake()

proc endFind(t: Tab) =
  if t == nil or t.closed: return
  if hasNativeFind(): webby_view_find_end(t.view)
  else: t.runJs("window.__webbyFind && window.__webbyFind.end();")
  wake()

proc closeBar*() =
  if shownFor == nil: return
  endFind(shownFor)
  shownFor = nil
  gtk_widget_hide(bar)
  focusPage()

proc openBar*() =
  let t = currentTab()
  if t == nil: return
  if shownFor != t:
    if shownFor != nil: endFind(shownFor)
    shownFor = t
    scriptDefinedFor = ""
    # show_all skips a no_show_all widget (the bar is one, so the window's show_all leaves it hidden).
    gtk_widget_set_no_show_all(bar, 0)
    gtk_widget_show_all(bar)
    gtk_widget_set_no_show_all(bar, 1)
    if query().len > 0: search(t)
  gtk_widget_grab_focus(entry)
  gtk_editable_select_region(entry, 0, -1)

proc nextOrOpen(forward: bool) =
  if shownFor == nil or shownFor != currentTab():
    openBar()
  else: step(forward)

proc onChanged(e: Widget, data: pointer) {.cdecl.} = search(shownFor)

proc onEntryKey(e: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  var keyval: cuint
  discard gdk_event_get_keyval(ev, addr keyval)
  let shift = (modifiers(eventState(ev)) and modShift) != 0
  case keyval
  of 0xff0d, 0xff8d:                       # Enter, Shift+Enter
    step(not shift)
    1
  of 0xff1b:                               # Esc
    closeBar()
    1
  else: 0

proc onCaseToggled(b: Widget, data: pointer) {.cdecl.} = search(shownFor)

proc buildBar() =
  bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  addClass(bar, "webby-find-bar")
  entry = gtk_search_entry_new()
  gtk_entry_set_placeholder_text(entry, "Find in page")
  gtk_entry_set_width_chars(entry, 28)
  connect(entry, "changed", onChanged)
  connect(entry, "key-press-event", onEntryKey)
  gtk_box_pack_start(bar, entry, 0, 0, 4)
  countLabel = gtk_label_new("")
  gtk_label_set_width_chars(countLabel, 10)
  gtk_label_set_xalign(countLabel, 0)
  gtk_box_pack_start(bar, countLabel, 0, 0, 4)
  for (label, tip, forward) in [("↑", "Previous match (Shift+Enter)", false), ("↓", "Next match (Enter)", true)]:
    let b = gtk_button_new_with_label(label.cstring)
    gtk_button_set_relief(b, GTK_RELIEF_NONE)
    gtk_widget_set_tooltip_text(b, tip.cstring)
    let f = forward
    let cb = new(proc ())
    cb[] = proc () = step(f)
    GC_ref(cb)
    connect(b, "clicked", proc (w: Widget, d: pointer) {.cdecl.} = cast[ref proc ()](d)[](), cast[pointer](cb))
    gtk_box_pack_start(bar, b, 0, 0, 0)
  caseButton = gtk_toggle_button_new_with_label("Aa")
  gtk_button_set_relief(caseButton, GTK_RELIEF_NONE)
  gtk_widget_set_tooltip_text(caseButton, "Match case")
  connect(caseButton, "toggled", onCaseToggled)
  gtk_box_pack_start(bar, caseButton, 0, 0, 0)
  gtk_box_pack_end(bar, iconButton("close", "Close (Esc)", closeBar, 16), 0, 0, 0)
  gtk_widget_set_no_show_all(bar, 1)
  gtk_box_pack_start(findSlot, bar, 0, 0, 2)

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"find\""): return false
  let j = try: parseJson(text) except CatchableError: return true
  scriptCurrent = j{"current"}.getInt
  scriptTotal = j{"total"}.getInt
  if t == shownFor: showCount(scriptCurrent, scriptTotal)
  true

proc install*() =
  windowHooks.add proc () =
    buildBar()
    loadCss(".webby-find-bar { border-top: 1px solid alpha(currentColor, 0.15); }")
    addMenuItem("Find in page…", openBar)
  addShortcut(modCtrl, 0x66, openBar)                            # Ctrl+F
  addShortcut(0, 0xffc0, proc () = nextOrOpen(true))             # F3
  addShortcut(modShift, 0xffc0, proc () = nextOrOpen(false))     # Shift+F3
  addShortcut(modCtrl, 0x67, proc () = nextOrOpen(true))         # Ctrl+G
  addShortcut(modCtrl or modShift, 0x67, proc () = nextOrOpen(false))  # Ctrl+Shift+G
  addKeyHandler(0, 0xff1b, proc (): bool =                       # Esc (page focused) closes the bar
    result = shownFor != nil
    if result: closeBar())
  findHooks.add proc (t: Tab) =
    if t == shownFor: showCount(t.findCurrent, t.findTotal)
  pageMessageHooks.add onMessage
  activeTabHooks.add proc (t: Tab) =
    if shownFor != nil and shownFor != t: closeBar()
  tabClosedHooks.add proc (t: Tab) =
    if t == shownFor:
      shownFor = nil
      gtk_widget_hide(bar)
  navigationHooks.add proc (t: Tab) =
    # A new page: search it again so the count and highlights match what shows.
    if t == shownFor:
      scriptDefinedFor = ""
      if query().len > 0: search(t)
