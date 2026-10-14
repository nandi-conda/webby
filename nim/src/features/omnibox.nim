## The address bar's suggestions (app/lib/src/omnibox.dart): while the URL bar is edited, a popup under it lists
## what `suggestionProviders` offer for the text (history and bookmarks add theirs; open tabs come from here).
## Up/Down pick one, Enter opens it (or the typed text, made an address or a search by `addressToUrl`), Esc closes.

import std/strutils
import ../browser
import omnibox/address
export address

{.push cdecl, importc.}
proc gtk_window_move(w: Widget, x, y: cint)
proc gtk_window_resize(w: Widget, width, height: cint)
proc gdk_window_get_origin(w: pointer, x, y: ptr cint): cint
proc gtk_list_box_unselect_all(l: Widget)
proc gtk_list_box_get_row_at_y(l: Widget, y: cint): Widget
{.pop.}

const
  GTK_WINDOW_POPUP = 1.cint
  maxSuggestions = 8

var
  popup, list: Widget
  shown: seq[Suggestion]
  selected = -1               ## -1 is the typed text itself
  changedHandler: culong

proc go*(input: string) =
  ## Loads what was typed (or picked) in the current tab, as the Flutter app's _go does.
  let text = input.strip
  if text.len == 0: return
  let t = currentTab()
  if t == nil: discard openTab(addressToUrl(text))
  else:
    t.loadUrl(addressToUrl(text))
    focusPage()

# ---------------------------------------------------------------------------------------------------------------
# The popup

proc hidePopup() =
  if popup != nil and gtk_widget_get_visible(popup) != 0: gtk_widget_hide(popup)
  shown.setLen 0
  selected = -1

proc popupShowing(): bool = popup != nil and gtk_widget_get_visible(popup) != 0

proc place() =
  var ox, oy, ex, ey: cint
  discard gdk_window_get_origin(gtk_widget_get_window(window), addr ox, addr oy)
  discard gtk_widget_translate_coordinates(urlEntry, window, 0, 0, addr ex, addr ey)
  gtk_window_move(popup, ox + ex, oy + ey + gtk_widget_get_allocated_height(urlEntry) + 4)
  gtk_window_resize(popup, gtk_widget_get_allocated_width(urlEntry), 1)

proc open(s: Suggestion) =
  hidePopup()
  if s.kind == "tab":
    for t in tabs:
      if t.url == s.url and t != currentTab():
        activateTab(t)
        focusPage()
        return
  go(s.url)

proc onPopupPress(l: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  ## Opens on the press: the entry may lose focus to the popup before a release would arrive.
  var x, y: cdouble
  discard gdk_event_get_coords(ev, addr x, addr y)
  let row = gtk_list_box_get_row_at_y(list, y.cint)
  if row == nil: return 0
  let i = gtk_list_box_row_get_index(row)
  if i in 0 ..< shown.len: open(shown[i])
  1

proc kindIcon(kind: string): string =
  case kind
  of "bookmark": "star_border"
  of "tab": "tab"
  of "search": "search"
  else: "history"

proc row(s: Suggestion): Widget =
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)
  gtk_widget_set_margin_start(box, 12)
  gtk_widget_set_margin_end(box, 12)
  gtk_widget_set_size_request(box, -1, 30)
  gtk_box_pack_start(box, icon(kindIcon(s.kind)), 0, 0, 0)
  if s.title.len > 0:
    let title = gtk_label_new(s.title.cstring)
    gtk_label_set_ellipsize(title, PANGO_ELLIPSIZE_END)
    gtk_label_set_xalign(title, 0)
    gtk_box_pack_start(box, title, 0, 1, 0)
    let dash = gtk_label_new("-")
    addClass(dash, "dim-label")
    gtk_box_pack_start(box, dash, 0, 0, 0)
  let url = gtk_label_new(cstring(if s.kind == "tab": s.url & "  (switch to tab)" else: s.url))
  gtk_label_set_ellipsize(url, PANGO_ELLIPSIZE_END)
  gtk_label_set_xalign(url, 0)
  addClass(url, "webby-omnibox-url")
  gtk_box_pack_start(box, url, 1, 1, 0)
  box

proc suggestionsFor(text: string): seq[Suggestion] =
  var seen: seq[string]
  for p in suggestionProviders:
    for s in p(text):
      # An open tab doesn't hide the page in history: one switches to the tab, the other loads it here.
      let key = if s.kind == "tab": "tab " & s.url else: s.url
      if key in seen: continue
      seen.add key
      result.add s
      if result.len >= maxSuggestions: return

proc update() =
  let text = $gtk_entry_get_text(urlEntry)
  let found = if gtk_widget_has_focus(urlEntry) != 0 and text.strip.len > 0: suggestionsFor(text) else: @[]
  if found.len == 0:
    hidePopup()
    return
  shown = found
  selected = -1
  clearChildren(list)
  for s in found: gtk_container_add(list, row(s))
  gtk_list_box_unselect_all(list)
  place()
  gtk_widget_show_all(popup)

proc select(i: int) =
  selected = i
  if i < 0: gtk_list_box_unselect_all(list)
  else: gtk_list_box_select_row(list, gtk_list_box_get_row_at_index(list, i.cint))

proc onChanged(e: Widget, data: pointer) {.cdecl.} = update()

proc onEntryKey(e: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  var keyval: cuint
  discard gdk_event_get_keyval(ev, addr keyval)
  case keyval
  of 0xff54, 0xff99, 0xff52, 0xff97:          # Down, Up
    if not popupShowing(): return 0
    let step = if keyval in [0xff54'u32, 0xff99]: 1 else: -1
    select((selected + 1 + step + shown.len + 1) mod (shown.len + 1) - 1)
    1
  of 0xff0d, 0xff8d:                          # Enter
    let picked = if selected in 0 ..< shown.len: shown[selected] else: Suggestion()
    let text = $gtk_entry_get_text(urlEntry)
    hidePopup()
    if picked.url.len > 0: open(picked) else: go(text)
    1
  else: 0

proc onEntryFocusOut(e: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  # A moment later, so a click on the popup (which can take the focus away first) still lands.
  discard g_timeout_add(150, proc (d: pointer): gboolean {.cdecl.} =
    if gtk_widget_has_focus(urlEntry) != 0: return 0
    hidePopup()
    let t = currentTab()
    if t != nil and t.url.len > 0:
      g_signal_handler_block(urlEntry, changedHandler)
      gtk_entry_set_text(urlEntry, (if t.url == "about:blank": "" else: t.url).cstring)
      g_signal_handler_unblock(urlEntry, changedHandler)
    0, nil)
  0

proc onWindowMoved(w: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  hidePopup()
  0

proc tabSuggestions(text: string): seq[Suggestion] =
  ## Open tabs (other than this one) whose title or address contain every typed word.
  let words = text.toLowerAscii.splitWhitespace
  for t in tabs:
    if t == currentTab() or t.url.len == 0: continue
    let hay = t.url.toLowerAscii & " " & t.title.toLowerAscii
    var all = true
    for w in words:
      if w notin hay: all = false
    if all and words.len > 0:
      result.add Suggestion(title: t.title, url: t.url, kind: "tab")
      if result.len >= 2: return

proc buildPopup() =
  if appUrl.len > 0: return
  loadCss(".webby-omnibox { border: 1px solid alpha(currentColor, 0.2); }\n" &
    ".webby-omnibox-url { color: @theme_selected_bg_color; }\n" &
    ".webby-omnibox row:selected .webby-omnibox-url { color: @theme_selected_fg_color; }")
  popup = gtk_window_new(GTK_WINDOW_POPUP)
  gtk_window_set_transient_for(popup, window)
  addClass(popup, "webby-omnibox")
  list = gtk_list_box_new()
  gtk_list_box_set_selection_mode(list, GTK_SELECTION_SINGLE)
  connect(list, "button-press-event", onPopupPress)
  gtk_container_add(popup, list)
  changedHandler = connect(urlEntry, "changed", onChanged)
  connect(urlEntry, "key-press-event", onEntryKey)
  connect(urlEntry, "focus-out-event", onEntryFocusOut)
  connect(window, "configure-event", onWindowMoved)

proc install*() =
  # Before the core's Esc (close the sidebar), which it still does when there are no suggestions to close.
  # Esc that closes nothing goes on to the page.
  addKeyHandler(0, 0xff1b, proc (): bool =
    result = true
    if popupShowing(): hidePopup()
    elif sidePanelShowing(): closeSidePanel()
    elif gtk_widget_has_focus(urlEntry) != 0:
      let t = currentTab()
      if t != nil: gtk_entry_set_text(urlEntry, (if t.url == "about:blank": "" else: t.url).cstring)
      gtk_editable_select_region(urlEntry, 0, -1)
    else: result = false)
  suggestionProviders.insert(tabSuggestions, 0)
  windowHooks.add buildPopup
