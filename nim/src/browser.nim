## The browser core of webby-nim: window, tabs, page view, input, the Ladybird pump, and the hooks features plug
## into. Features live in src/features/*.nim; each has an `install()` that only appends to the hook lists below
## (UI pieces go in `windowHooks`, which run once the window exists). Nothing here knows about a feature.

import std/[json, monotimes, os, random, strutils, tables, times]
import gtk, ffi, icons
export gtk, ffi, icons, json, tables

# The Flutter app's page shims (lib/src/page_compat.dart), read at compile time so both front ends run the same JS.
const pageCompatScript* = block:
  let dart = staticRead("../../app/lib/src/page_compat.dart")
  let start = dart.find("r'''") + 4
  dart[start ..< dart.rfind("'''")]

const homePage* = "https://ladybird.org"

# Ladybird modifier bits (Web::UIEvents::KeyModifier), used by shortcuts too.
const modAlt* = 1
const modCtrl* = 2
const modShift* = 4
const modSuper* = 8

type
  Tab* = ref object
    view*: View
    button*: Widget          ## the tab's widget in the tab strip
    label*: Widget           ## the label inside it
    icon*: Widget            ## a GtkImage before the label (features may set a favicon)
    url*, title*, hovered*: string
    loading*, canBack*, canForward*: bool
    cursor*: int
    pinned*: bool
    messagePrefix*: string   ## page scripts send messages with prompt(messagePrefix + text)
    props*: Table[string, string]  ## per-tab scratch space for features
    frameSerial, stateSerial: uint64
    lastCompat: MonoTime
    answering: bool
    closed*: bool

  Suggestion* = object
    title*, url*, kind*: string    ## kind: "history", "bookmark", "tab", "search"...

var
  # Command line
  appUrl*: string              ## --app=<url>: an installed web app's own window (no tab strip, no URL bar)
  incognito*: bool             ## --incognito: this process keeps nothing (see app/lib/src/incognito.dart)
  commandLineUrls*: seq[string]

  # Widgets
  window*, mainBox*, tabStrip*, tabStripBox*, toolbar*, toolbarEnd*, urlEntry*, area*, status*: Widget
  barSlot*: Widget             ## a box under the toolbar (the bookmark bar goes here)
  pagePane*: Widget            ## GtkPaned: the page on the left, the side panel on the right
  pageBox*: Widget             ## holds the vertical tab list (if any) and the page area
  sidePanel*: Widget           ## the side panel's box (hidden when nothing shows)
  sidePanelTitle*: Widget
  sidePanelBody*: Widget
  starSlot*: Widget            ## a box inside the URL bar row, right of the entry (the bookmark star goes here)
  backButton*, forwardButton*, reloadButton*, moreButton*, moreMenu*: Widget

  tabs*: seq[Tab]
  activeIndex* = -1

  # Hooks
  startupHooks*: seq[proc ()]                     ## before Ladybird starts
  windowHooks*: seq[proc ()]                      ## once the window and its boxes exist
  initialTabsHooks*: seq[proc (urls: seq[string]): bool]  ## first one returning true opened the start tabs
  tabCreatedHooks*: seq[proc (t: Tab)]
  tabClosedHooks*: seq[proc (t: Tab)]             ## before the view is destroyed
  activeTabHooks*: seq[proc (t: Tab)]
  tabStateHooks*: seq[proc (t: Tab)]              ## url, title, loading or history changed
  navigationHooks*: seq[proc (t: Tab)]            ## a page finished loading (url + title final)
  pageMessageHooks*: seq[proc (t: Tab, msg: string): bool]  ## true = handled
  pageScriptHooks*: seq[proc (t: Tab): string]    ## JS run with the compat shims on every page
  quitHooks*: seq[proc (): bool]                  ## false cancels quitting
  shutdownHooks*: seq[proc ()]                    ## quitting for real
  tabStripHooks*: seq[proc ()]                    ## tabs added, removed, moved or pinned
  suggestionProviders*: seq[proc (text: string): seq[Suggestion]]
  tabMenuHooks*: seq[proc (t: Tab, menu: Widget)]  ## right-click on a tab: append items to the GtkMenu
  pageContextMenuHook*: proc (t: Tab, info: JsonNode, event: GEvent) ## replaces the built-in page menu if set

  # Device-only secrets kept in the password vault (e.g. the DeepSeek key), set by the passwords feature.
  # nil until it installs; getSecret returns "" when there is none.
  getSecret*: proc (name: string): string
  setSecret*: proc (name, value: string)

  # Requests from pages. nil = declined by the core.
  webauthnHandler*: proc (t: Tab, request: JsonNode)
  filePickerHandler*: proc (t: Tab, request: JsonNode)
  permissionHandler*: proc (t: Tab, request: JsonNode)

  viewW, viewH, viewScale = 0
  pumpSource: cuint
  pumpDelay = 0
  quietTicks = 0
  pumping = false
  wokeInPump = false
  clipboardSerial: uint64
  cursors: Table[int, pointer]
  lastClick: tuple[time: uint32, x, y: float, button: cuint, count: int]
  shortcuts: seq[tuple[mods: int, keyval: uint32, action: proc (): bool]]
  quitting = false
  # Wheel coalescing: while a sent wheel event hasn't produced a new frame yet, later ones add up here and go out
  # as one event with the next frame (or after wheelHoldMs), so a fast touchpad can't queue work in the engine.
  wheelQ: tuple[t: Tab, x, y: cint, dx, dy: float, precise, mods: cint, pending: bool]
  wheelInFlight = false
  wheelSentAt: MonoTime
  # WEBBY_TRACE counters
  trace = getEnv("WEBBY_TRACE") == "1"
  pumps, frames, draws: int
  nativeUs, drawUs, maxTickUs: int64
  wheelSent: MonoTime
  wheelPending = false
  wheelFrames: int
  wheelUs, maxWheelUs: int64

proc us(d: Duration): int64 = d.inMicroseconds

const wheelHoldMs = 50

proc flushWheel() =
  if not wheelQ.pending: return
  wheelQ.pending = false
  wheelInFlight = true
  wheelSentAt = getMonoTime()
  let q = wheelQ
  if not q.t.closed:
    webby_view_wheel_event(q.t.view, q.x, q.y, q.dx, q.dy, q.precise, q.mods)

# ---------------------------------------------------------------------------------------------------------------
# Files: the same places the Flutter app keeps its data, so both front ends share a profile.

proc dataHome*(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  if xdg.len > 0: xdg else: getHomeDir() / ".local" / "share"

proc profileName*(): string =
  let p = getEnv("WEBBY_PROFILE")
  if p.len > 0: p else: "default"

proc profileDir*(): string = dataHome() / "webby" / "profiles" / profileName()

proc profileFile*(name: string): string = profileDir() / name

proc readJsonFile*(path: string): JsonNode =
  ## The file's JSON, or nil if it's missing or unreadable.
  try: parseJson(readFile(path)) except CatchableError: nil

proc writeFileAtomic*(path, content: string) =
  createDir(path.parentDir)
  let tmp = path & ".tmp"
  writeFile(tmp, content)
  moveFile(tmp, path)

proc writeJsonFile*(path: string, node: JsonNode, pretty = false) =
  writeFileAtomic(path, if pretty: node.pretty else: $node)

# ---------------------------------------------------------------------------------------------------------------
# Tabs

proc wake*()
proc schedule(ms: int)

proc currentTab*(): Tab = (if activeIndex in 0 ..< tabs.len: tabs[activeIndex] else: nil)

proc tabLabel*(t: Tab): string =
  if t.title.len > 0: t.title elif t.url.len > 0: t.url else: "New tab"

proc runJs*(t: Tab, source: string) =
  if t != nil and not t.closed: webby_view_run_javascript(t.view, source.cstring)

proc refreshChrome*() =
  let t = currentTab()
  if t == nil: return
  let name = if incognito: "Webby (Incognito)" else: "Webby"
  # An installed web app's window is titled by the app alone.
  let title = if appUrl.len > 0 and t.title.len > 0: t.title
              elif t.title.len > 0: t.title & " - " & name else: name
  gtk_window_set_title(window, title.cstring)
  if gtk_widget_has_focus(urlEntry) == 0: gtk_entry_set_text(urlEntry, t.url.cstring)
  gtk_widget_set_sensitive(backButton, t.canBack.gboolean)
  gtk_widget_set_sensitive(forwardButton, t.canForward.gboolean)
  setIcon(gtk_button_get_image(reloadButton), if t.loading: "close" else: "refresh")
  gtk_label_set_text(status, t.hovered.cstring)
  gtk_widget_set_visible(status, (t.hovered.len > 0).gboolean)
  let win = gtk_widget_get_window(area)
  if win != nil:
    const names = {1: "none", 2: "default", 3: "crosshair", 4: "text", 5: "ew-resize", 6: "ns-resize",
      7: "nwse-resize", 8: "nesw-resize", 9: "col-resize", 10: "row-resize", 11: "pointer", 12: "help", 13: "grab",
      14: "grabbing", 15: "copy", 16: "move", 17: "wait", 18: "not-allowed", 19: "crosshair", 20: "zoom-in"}.toTable
    let id = if t.cursor in names: t.cursor else: 2
    if id notin cursors: cursors[id] = gdk_cursor_new_from_name(gtk_widget_get_display(area), names[id].cstring)
    gdk_window_set_cursor(win, cursors[id])

proc updateTabButton*(t: Tab) =
  ## Label, tooltip and pinned look of the tab's strip widget.
  var s = tabLabel(t)
  gtk_label_set_text(t.label, (if t.pinned: "" else: s).cstring)
  gtk_widget_set_visible(t.label, (not t.pinned).gboolean)
  gtk_widget_set_tooltip_text(t.button, s.cstring)

proc notifyTabStrip*() =
  for h in tabStripHooks: h()

proc resizeView(t: Tab) =
  if viewW > 0: webby_view_resize(t.view, cint(viewW * viewScale), cint(viewH * viewScale), viewScale.cdouble)

proc activateTab*(i: int) =
  if i notin 0 ..< tabs.len: return
  if activeIndex in 0 ..< tabs.len and activeIndex != i:
    webby_view_set_visible(tabs[activeIndex].view, 0)
    removeClass(tabs[activeIndex].button, "webby-active-tab")
  activeIndex = i
  let t = tabs[i]
  webby_view_set_visible(t.view, 1)
  resizeView(t)
  addClass(t.button, "webby-active-tab")
  refreshChrome()
  gtk_widget_queue_draw(area)
  for h in activeTabHooks: h(t)
  wake()

proc activateTab*(t: Tab) = activateTab(tabs.find(t))

proc closeTab*(t: Tab)

proc onTabClicked(button: Widget, event: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = cast[Tab](data)
  var b: cuint
  discard gdk_event_get_button(event, addr b)
  if gdk_event_get_event_type(event) != GDK_BUTTON_PRESS: return 1
  case b
  of 1: activateTab(t)
  of 2: closeTab(t)
  of 3:
    let menu = gtk_menu_new()
    for h in tabMenuHooks: h(t, menu)
    if children(menu).len == 0:
      let item = gtk_menu_item_new_with_label("Close tab")
      connect(item, "activate", proc (w: Widget, d: pointer) {.cdecl.} = closeTab(cast[Tab](d)), data)
      gtk_menu_shell_append(menu, item)
    gtk_widget_show_all(menu)
    gtk_menu_popup_at_pointer(menu, event)
  else: discard
  1

proc onTabClose(button: Widget, data: pointer) {.cdecl.} = closeTab(cast[Tab](data))

proc randomPrefix(): string =
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  result = "webby-msg-"
  for _ in 0 ..< 16: result.add chars[rand(chars.high)]
  result.add ':'

proc newViewSized(): View =
  let s = max(viewScale, 1)
  webby_view_create(cint(max(viewW, 1280) * s), cint(max(viewH, 720) * s), s.cdouble)

proc adoptView*(view: View, focus = true, index = -1): Tab =
  ## Adds a tab around an existing view (one a page opened, or one made by newViewSized).
  let t = Tab(view: view, lastCompat: getMonoTime(), messagePrefix: randomPrefix())
  GC_ref(t)
  webby_view_set_message_prefix(view, t.messagePrefix.cstring)
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
  t.icon = icon("public", 14)
  t.label = gtk_label_new("New tab")
  gtk_label_set_ellipsize(t.label, PANGO_ELLIPSIZE_END)
  gtk_label_set_width_chars(t.label, 14)
  gtk_label_set_max_width_chars(t.label, 22)
  gtk_label_set_xalign(t.label, 0)
  let close = gtk_button_new()
  iconButtonImage(close, "close", 14)
  gtk_button_set_relief(close, GTK_RELIEF_NONE)
  addClass(close, "webby-tab-close")
  connect(close, "clicked", onTabClose, cast[pointer](t))
  gtk_box_pack_start(box, t.icon, 0, 0, 0)
  gtk_box_pack_start(box, t.label, 1, 1, 0)
  gtk_box_pack_end(box, close, 0, 0, 0)
  t.button = gtk_event_box_new()
  addClass(t.button, "webby-tab")
  gtk_container_add(t.button, box)
  g_object_set_data(t.button, "webby-close", close)
  connect(t.button, "button-press-event", onTabClicked, cast[pointer](t))
  gtk_box_pack_start(tabStrip, t.button, 0, 0, 0)
  gtk_widget_show_all(t.button)
  let at = if index in 0 .. tabs.len: index else: tabs.len
  tabs.insert(t, at)
  gtk_box_reorder_child(tabStrip, t.button, at.cint)
  if at <= activeIndex: inc activeIndex
  for h in tabCreatedHooks: h(t)
  if focus or activeIndex < 0: activateTab(at)
  else: webby_view_set_visible(view, 0)
  notifyTabStrip()
  t

proc loadUrl*(t: Tab, text: string) =
  if t == nil: return
  webby_view_load(t.view, text.cstring)
  wake()

proc openTab*(url: string, focus = true, index = -1): Tab =
  let t = adoptView(newViewSized(), focus, index)
  if url.len > 0: t.loadUrl(url)
  elif focus:
    gtk_entry_set_text(urlEntry, "")
    gtk_widget_grab_focus(urlEntry)
  t

proc moveTab*(t: Tab, index: int) =
  let i = tabs.find(t)
  if i < 0 or index notin 0 ..< tabs.len or index == i: return
  let cur = currentTab()
  tabs.delete(i)
  tabs.insert(t, index)
  gtk_box_reorder_child(tabStrip, t.button, index.cint)
  activeIndex = tabs.find(cur)
  notifyTabStrip()

proc quit*()

proc closeTab*(t: Tab) =
  let i = tabs.find(t)
  if i < 0: return
  for h in tabClosedHooks: h(t)
  tabs.delete(i)
  t.closed = true
  gtk_widget_destroy(t.button)
  webby_view_destroy(t.view)
  GC_unref(t)
  if tabs.len == 0:
    quit()
    return
  if i == activeIndex or activeIndex >= tabs.len:
    activeIndex = -1
    activateTab(min(i, tabs.high))
  elif i < activeIndex:
    dec activeIndex
  notifyTabStrip()

# ---------------------------------------------------------------------------------------------------------------
# Chrome helpers for features

proc iconButton*(icon, tooltip: string, action: proc () {.closure.}, size = 18): Widget =
  ## A flat toolbar button with one of the Flutter app's icons (an Icons.* name, see icons.nim).
  result = gtk_button_new()
  if icon.len > 0: iconButtonImage(result, icon, size)
  gtk_button_set_relief(result, GTK_RELIEF_NONE)
  gtk_widget_set_tooltip_text(result, tooltip.cstring)
  let cb = new(proc ())
  cb[] = action
  GC_ref(cb)
  connect(result, "clicked", proc (w: Widget, d: pointer) {.cdecl.} = cast[ref proc ()](d)[](), cast[pointer](cb))

var panelButtons: seq[tuple[button: Widget, icon, openIcon, panel: string]]
var openPanel: string   ## the side panel's title while it shows

proc refreshPanelButtons() =
  for b in panelButtons:
    setIcon(gtk_button_get_image(b.button), if b.panel == openPanel: b.openIcon else: b.icon)

proc addToolbarButton*(icon, tooltip: string, action: proc () {.closure.}, openIcon = "", panel = ""): Widget =
  ## A button right of the URL bar, before the ⋮ menu. A button that toggles a side panel names it (its title) and
  ## the icon to show while it is open, as the Flutter app swaps Icons.key_outlined for Icons.key.
  result = iconButton(icon, tooltip, action)
  gtk_box_pack_start(toolbarEnd, result, 0, 0, 0)
  gtk_widget_show_all(result)
  if openIcon.len > 0: panelButtons.add (result, icon, openIcon, panel)

proc menuItem*(menu: Widget, label: string, action: proc () {.closure.}): Widget {.discardable.} =
  result = gtk_menu_item_new_with_label(label.cstring)
  let cb = new(proc ())
  cb[] = action
  GC_ref(cb)
  connect(result, "activate", proc (w: Widget, d: pointer) {.cdecl.} = cast[ref proc ()](d)[](), cast[pointer](cb))
  gtk_menu_shell_append(menu, result)
  gtk_widget_show(result)

proc menuSeparator*(menu: Widget) =
  let s = gtk_separator_menu_item_new()
  gtk_menu_shell_append(menu, s)
  gtk_widget_show(s)

proc addMenuItem*(label: string, action: proc () {.closure.}): Widget {.discardable.} =
  ## An item in the ⋮ (More) menu.
  menuItem(moreMenu, label, action)

proc addMenuSeparator*() = menuSeparator(moreMenu)

proc addShortcut*(mods: int, keyval: uint32, action: proc () {.closure.}) =
  ## A window-wide key (mods are modCtrl etc., keyval a GDK keyval in lower case for letters).
  shortcuts.add((mods, keyval, proc (): bool = (action(); true)))

proc addKeyHandler*(mods: int, keyval: uint32, action: proc (): bool {.closure.}) =
  ## Like addShortcut, but the key goes on to the focused widget (the page, the URL bar) when `action` returns false.
  shortcuts.add((mods, keyval, action))

var sidePanelCloseHook: proc ()

proc closeSidePanel*() =
  if sidePanelCloseHook != nil:
    let h = sidePanelCloseHook
    sidePanelCloseHook = nil
    h()
  clearChildren(sidePanelBody)
  gtk_widget_hide(sidePanel)
  if openPanel.len > 0:
    openPanel = ""
    refreshPanelButtons()

proc showSidePanel*(title: string, content: Widget, width = 360, onClose: proc () = nil) =
  ## Shows `content` in the sidebar right of the page, replacing what was there.
  closeSidePanel()
  sidePanelCloseHook = onClose
  gtk_label_set_text(sidePanelTitle, title.cstring)
  openPanel = title
  refreshPanelButtons()
  gtk_box_pack_start(sidePanelBody, content, 1, 1, 0)
  # The panel is no_show_all (so show_all on the window leaves it hidden): show its parts, then itself.
  for c in children(sidePanel): gtk_widget_show_all(c)
  gtk_widget_show(sidePanel)
  let total = gtk_widget_get_allocated_width(pagePane)
  if total > width: gtk_paned_set_position(pagePane, cint(total - width))

proc sidePanelShowing*(): bool = gtk_widget_get_visible(sidePanel) != 0

proc alert*(text: string, secondary = "") =
  let d = gtk_message_dialog_new(window, GTK_DIALOG_MODAL, GTK_MESSAGE_INFO, GTK_BUTTONS_OK, "%s", text.cstring)
  if secondary.len > 0: gtk_message_dialog_format_secondary_text(d, "%s", secondary.cstring)
  discard gtk_dialog_run(d)
  gtk_widget_destroy(d)

proc confirm*(text: string, secondary = ""): bool =
  let d = gtk_message_dialog_new(window, GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION, GTK_BUTTONS_OK_CANCEL, "%s",
    text.cstring)
  if secondary.len > 0: gtk_message_dialog_format_secondary_text(d, "%s", secondary.cstring)
  result = gtk_dialog_run(d) == GTK_RESPONSE_OK
  gtk_widget_destroy(d)

proc askText*(title, prompt: string, initial = "", password = false): (bool, string) =
  ## A small modal dialog with one text field.
  let d = gtk_dialog_new_with_buttons(title.cstring, window, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL,
    "_OK", GTK_RESPONSE_OK, nil)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  let box = gtk_dialog_get_content_area(d)
  gtk_container_set_border_width(box, 12)
  gtk_box_pack_start(box, gtk_label_new(prompt.cstring), 0, 0, 4)
  let e = gtk_entry_new()
  gtk_entry_set_text(e, initial.cstring)
  gtk_entry_set_visibility(e, (not password).gboolean)
  gtk_entry_set_activates_default(e, 1)
  gtk_box_pack_start(box, e, 0, 0, 4)
  gtk_widget_show_all(d)
  let ok = gtk_dialog_run(d) == GTK_RESPONSE_OK
  result = (ok, $gtk_entry_get_text(e))
  gtk_widget_destroy(d)

# ---------------------------------------------------------------------------------------------------------------
# Page requests

proc runDialog(data: pointer): gboolean {.cdecl.} =
  let t = cast[Tab](data)
  if t.closed: return 0
  let raw = str(webby_view_dialog(t.view))
  if raw.len == 0:
    t.answering = false
    return 0
  let j = parseJson(raw)
  let kind = j{"type"}.getStr
  var ok: bool
  var text = j{"default"}.getStr
  if kind == "prompt":
    (ok, text) = askText("Webby", j{"message"}.getStr, text)
  elif kind == "alert":
    alert(j{"message"}.getStr)
    ok = true
  else:
    ok = confirm(j{"message"}.getStr)
  if not t.closed: webby_view_dialog_respond(t.view, uint64(j{"id"}.getBiggestInt), ok.cint, text.cstring)
  t.answering = false
  wake()
  0

proc answerRequests(t: Tab) =
  if not t.answering and str(webby_view_dialog(t.view)).len > 0:
    t.answering = true
    discard g_idle_add(runDialog, cast[pointer](t))
  let wa = str(webby_view_webauthn_prompt(t.view))
  if wa.len > 0 and t.props.getOrDefault("webauthn") != wa:
    t.props["webauthn"] = wa
    if webauthnHandler != nil: webauthnHandler(t, parseJson(wa))
    else: webby_view_webauthn_respond(t.view, 0, 0)
  elif wa.len == 0: t.props.del("webauthn")
  let fp = str(webby_view_file_picker_request(t.view))
  if fp.len > 0 and t.props.getOrDefault("filepicker") != fp:
    t.props["filepicker"] = fp
    if filePickerHandler != nil: filePickerHandler(t, parseJson(fp))
    else: webby_view_file_picker_respond(t.view, "[]")
  elif fp.len == 0: t.props.del("filepicker")
  let perm = str(webby_view_permission_request(t.view))
  if perm.len > 0 and t.props.getOrDefault("permission") != perm:
    t.props["permission"] = perm
    let j = parseJson(perm)
    if permissionHandler != nil: permissionHandler(t, j)
    else: webby_view_permission_respond(t.view, uint64(j{"id"}.getBiggestInt), 0)
  elif perm.len == 0: t.props.del("permission")

# ---------------------------------------------------------------------------------------------------------------
# The pump: Ladybird's event loop runs on this (the GTK) thread. 4 ms while anything happens, backing off to 100 ms
# when idle, the same schedule as the Flutter app's web_view.dart.

proc runPageScripts(t: Tab) =
  t.lastCompat = getMonoTime()
  t.runJs(pageCompatScript)
  for h in pageScriptHooks:
    let js = h(t)
    if js.len > 0: t.runJs(js)

proc pumpTab(t: Tab, isActive: bool): bool =
  var busy = t.loading
  let ss = webby_view_state_serial(t.view)
  if ss != t.stateSerial:
    busy = true
    t.stateSerial = ss
    let before = (t.url, t.title, t.loading)
    t.url = str(webby_view_url(t.view))
    t.title = str(webby_view_title(t.view))
    t.hovered = str(webby_view_hovered_link(t.view))
    t.loading = webby_view_is_loading(t.view) != 0
    t.canBack = webby_view_can_go_back(t.view) != 0
    t.canForward = webby_view_can_go_forward(t.view) != 0
    t.cursor = webby_view_cursor(t.view)
    let changed = (t.url, t.title, t.loading) != before
    if changed: runPageScripts(t)
    updateTabButton(t)
    answerRequests(t)
    while true:
      let v = webby_view_take_new_view(t.view)
      if v == nil: break
      let i = tabs.find(t)
      discard adoptView(v, true, if i >= 0: i + 1 else: -1)
    if webby_view_close_requested(t.view) != 0:
      closeTab(t)
      return true
    if changed:
      for h in tabStateHooks: h(t)
      if before[2] and not t.loading or (not t.loading and t.url != before[0]):
        for h in navigationHooks: h(t)
    if isActive: refreshChrome()
  if t.loading and getMonoTime() - t.lastCompat >= initDuration(milliseconds = 100):
    runPageScripts(t)
  while true:
    let m = str(webby_view_next_message(t.view))
    if m.len == 0: break
    busy = true
    for h in pageMessageHooks:
      if h(t, m): break
  let fs = webby_view_frame_serial(t.view)
  if fs != t.frameSerial:
    t.frameSerial = fs
    busy = true
    if isActive:
      inc frames
      if wheelInFlight:
        wheelInFlight = false
        flushWheel()
      if trace and wheelPending:
        let d = us(getMonoTime() - wheelSent)
        wheelPending = false
        inc wheelFrames
        wheelUs += d
        maxWheelUs = max(maxWheelUs, d)
      gtk_widget_queue_draw(area)
  busy

proc pumpAll(data: pointer): gboolean {.cdecl.} =
  inc pumps
  pumping = true
  wokeInPump = false
  let t0 = getMonoTime()
  let events = webby_pump() > 0
  let t1 = getMonoTime()
  var busy = false
  let cs = webby_clipboard_serial()
  if cs != clipboardSerial:
    clipboardSerial = cs
    gtk_clipboard_set_text(systemClipboard(), webby_clipboard_text(), -1)
  var snapshot = tabs   # a copy: pumpTab may add or close tabs
  for t in snapshot:
    if not t.closed and pumpTab(t, t == currentTab()): busy = true
  if trace:
    nativeUs += us(t1 - t0)
    maxTickUs = max(maxTickUs, us(getMonoTime() - t0))
  if wheelInFlight and getMonoTime() - wheelSentAt >= initDuration(milliseconds = wheelHoldMs):
    wheelInFlight = false
    flushWheel()
  if wheelQ.pending: busy = true
  pumping = false
  quietTicks =
    if busy or wokeInPump: 0
    elif events: (if quietTicks >= 80: 40 else: min(quietTicks + 1, 79))
    else: quietTicks + 1
  let delay = if quietTicks < 60: 4 elif quietTicks < 80: 16 elif quietTicks < 100: 50 else: 100
  if delay == pumpDelay: return 1
  schedule(delay)
  0

proc schedule(ms: int) =
  pumpDelay = ms
  pumpSource = g_timeout_add(ms.cuint, pumpAll, nil)

proc wake*() =
  quietTicks = 0
  if pumping:
    wokeInPump = true
    return
  if pumpDelay <= 4 and pumpSource != 0: return
  if pumpSource != 0: discard g_source_remove(pumpSource)
  schedule(4)

proc traceTick(data: pointer): gboolean {.cdecl.} =
  stderr.writeLine "webby-trace pumps=", pumps, " frames=", frames, " draws=", draws, " delay=", pumpDelay,
    "ms nativeMs=", nativeUs div 1000, " drawMs=", drawUs div 1000,
    " maxTickMs=", formatFloat(maxTickUs.float / 1000, ffDecimal, 1), " wheels=", wheelFrames,
    " wheelMs=", (if wheelFrames == 0: "0" else: formatFloat(wheelUs.float / wheelFrames.float / 1000, ffDecimal, 1)),
    " maxWheelMs=", formatFloat(maxWheelUs.float / 1000, ffDecimal, 1), " tabs=", tabs.len
  pumps = 0; frames = 0; draws = 0; nativeUs = 0; drawUs = 0; maxTickUs = 0
  wheelFrames = 0; wheelUs = 0; maxWheelUs = 0
  1

# ---------------------------------------------------------------------------------------------------------------
# Drawing and input on the page area

proc onDraw(w: Widget, cr: Cairo, data: pointer): gboolean {.cdecl.} =
  let t0 = getMonoTime()
  let t = currentTab()
  cairo_set_source_rgb(cr, 1, 1, 1)
  cairo_paint(cr)
  if t != nil:
    let fw = webby_view_frame_width(t.view)
    let fh = webby_view_frame_height(t.view)
    let px = webby_view_frame_pixels(t.view)
    if fw > 0 and fh > 0 and px != nil:
      # Ladybird's frame is premultiplied BGRA, which is cairo's ARGB32 on little-endian: drawn in place.
      let surface = cairo_image_surface_create_for_data(px, CAIRO_FORMAT_ARGB32, fw, fh, fw * 4)
      let s = 1.0 / max(viewScale, 1).float
      cairo_scale(cr, s, s)
      cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
      cairo_set_source_surface(cr, surface, 0, 0)
      cairo_paint(cr)
      cairo_surface_destroy(surface)
  if trace:
    inc draws
    drawUs += us(getMonoTime() - t0)
  0

proc onSizeAllocate(w: Widget, alloc: pointer, data: pointer) {.cdecl.} =
  let nw = gtk_widget_get_allocated_width(area).int
  let nh = gtk_widget_get_allocated_height(area).int
  let ns = max(gtk_widget_get_scale_factor(area).int, 1)
  if (nw, nh, ns) == (viewW, viewH, viewScale): return
  viewW = nw; viewH = nh; viewScale = ns
  let t = currentTab()
  if t != nil:
    resizeView(t)
    wake()

proc modifiers*(state: uint32): int =
  if (state and GDK_MOD1_MASK) != 0: result = result or modAlt
  if (state and GDK_CONTROL_MASK) != 0: result = result or modCtrl
  if (state and GDK_SHIFT_MASK) != 0: result = result or modShift
  if (state and GDK_SUPER_MASK) != 0: result = result or modSuper

proc heldButtons(state: uint32): cint =
  if (state and GDK_BUTTON1_MASK) != 0: result = result or 1
  if (state and GDK_BUTTON3_MASK) != 0: result = result or 2
  if (state and GDK_BUTTON2_MASK) != 0: result = result or 4

proc ladybirdButton(b: cuint): cint =
  case b
  of 1: 1
  of 2: 4
  of 3: 2
  of 8: 8
  of 9: 16
  else: 0

proc eventPos(e: GEvent): (cint, cint, float, float) =
  var x, y: cdouble
  discard gdk_event_get_coords(e, addr x, addr y)
  let s = max(viewScale, 1).float
  (cint(x * s), cint(y * s), x.float, y.float)

proc eventState*(e: GEvent): uint32 =
  discard gdk_event_get_state(e, addr result)

var lastButtonEvent*: GEvent  ## the press that may open a page context menu (valid during the press only)

proc onButton(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = currentTab()
  if t == nil: return 0
  # GTK 3 also sends 2BUTTON/3BUTTON events after the presses; the click count is worked out here instead.
  let kind = gdk_event_get_event_type(e)
  if kind == GDK_2BUTTON_PRESS or kind == GDK_3BUTTON_PRESS: return 1
  let down = kind == GDK_BUTTON_PRESS
  var b: cuint
  discard gdk_event_get_button(e, addr b)
  let (x, y, lx, ly) = eventPos(e)
  let state = eventState(e)
  let button = ladybirdButton(b)
  if down:
    gtk_widget_grab_focus(area)
    let now = gdk_event_get_time(e)
    if b == lastClick.button and now - lastClick.time < 400 and abs(lx - lastClick.x) < 5 and abs(ly - lastClick.y) < 5:
      inc lastClick.count
    else:
      lastClick.count = 1
    lastClick = (now, lx, ly, b, lastClick.count)
    if b == 8: webby_view_go_back(t.view); wake(); return 1
    if b == 9: webby_view_go_forward(t.view); wake(); return 1
  let held = if down: heldButtons(state) or button else: heldButtons(state) and not button
  webby_view_mouse_event(t.view, cint(if down: mouseDown else: mouseUp), x, y, button, held,
    modifiers(state).cint, lastClick.count.cint)
  wake()
  1

proc onMotion(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = currentTab()
  if t == nil: return 0
  let (x, y, _, _) = eventPos(e)
  let state = eventState(e)
  webby_view_mouse_event(t.view, mouseMove, x, y, 0, heldButtons(state), modifiers(state).cint, 0)
  wake()
  1

proc onLeave(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = currentTab()
  if t != nil: webby_view_mouse_event(t.view, mouseLeave, 0, 0, 0, 0, 0, 0)
  0

proc onScroll(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = currentTab()
  if t == nil: return 0
  let (x, y, _, _) = eventPos(e)
  var dx, dy: cdouble
  var dir: cint
  var precise = 0.cint
  if gdk_event_get_scroll_deltas(e, addr dx, addr dy) != 0:
    precise = 1
  elif gdk_event_get_scroll_direction(e, addr dir) != 0:
    case dir
    of GDK_SCROLL_UP: dy = -1
    of GDK_SCROLL_DOWN: dy = 1
    of GDK_SCROLL_LEFT: dx = -1
    of GDK_SCROLL_RIGHT: dx = 1
    else: discard
  # 53 logical pixels per wheel step, as Flutter's Linux embedder scrolls.
  let s = 53.0 * max(viewScale, 1).float
  if trace and not wheelPending:
    wheelSent = getMonoTime()
    wheelPending = true
  # A wheel notch arrives as a smooth delta of 1.0 under XInput 2; it's still a mouse wheel, not a touchpad.
  if precise == 1 and (abs(dx) == 1 or abs(dy) == 1) and (dx == 0 or dy == 0): precise = 0
  let mods = modifiers(eventState(e)).cint
  if wheelQ.pending and (wheelQ.t != t or wheelQ.precise != precise or wheelQ.mods != mods): flushWheel()
  if wheelQ.pending:
    wheelQ.x = x; wheelQ.y = y; wheelQ.dx += dx * s; wheelQ.dy += dy * s
  else:
    wheelQ = (t, x, y, dx * s, dy * s, precise, mods, true)
  if not wheelInFlight or getMonoTime() - wheelSentAt >= initDuration(milliseconds = wheelHoldMs): flushWheel()
  wake()
  1

const specialKeys = {
  0xff08: 0x08, 0xff09: 0x09, 0xfe20: 0x09, 0xff0d: 0x0D, 0xff8d: 0x0D, 0xffe1: 0x10, 0xffe2: 0xB0,
  0xffe3: 0x11, 0xffe4: 0xB1, 0xffe9: 0x12, 0xffea: 0xB2, 0xffe5: 0x14, 0xff1b: 0x1B, 0x20: 0x20,
  0xff55: 0x21, 0xff56: 0x22, 0xff57: 0x23, 0xff50: 0x24, 0xff51: 0x25, 0xff52: 0x26, 0xff53: 0x27,
  0xff54: 0x28, 0xffff: 0x2E, 0xff63: 0x7E, 0xffeb: 0x92, 0xffec: 0xAC}.toTable

const punctuation = {
  ')': 0x60, '!': 0x61, '@': 0x62, '#': 0x63, '$': 0x64, '%': 0x65, '^': 0x66, '&': 0x67, '*': 0x68,
  '(': 0x69, '+': 0x6A, '-': 0x6B, '/': 0x6C, ',': 0x6D, '.': 0x6E, ':': 0x6F, '"': 0x7C, '\'': 0x7D,
  ';': 0x7F, '<': 0x80, '=': 0x81, '>': 0x82, '?': 0x83, '[': 0x84, ']': 0x85, '\\': 0x86, '_': 0x87,
  '{': 0x88, '}': 0x89, '|': 0x8A, '~': 0x8B, '`': 0x8C}.toTable

proc ladybirdKey(keyval: cuint): int =
  let k = keyval.int
  if k in specialKeys: return specialKeys[k]
  if k in 0xffbe .. 0xffc9: return 0x70 + (k - 0xffbe)            # F1..F12
  if k in 0x61 .. 0x7a: return k - 0x20                            # a..z
  if k in 0x41 .. 0x5a or k in 0x30 .. 0x39: return k
  if k < 0x80 and k.char in punctuation: return punctuation[k.char]
  0

proc onKey(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = currentTab()
  if t == nil: return 0
  let down = cast[int](data) == 1
  var keyval: cuint
  discard gdk_event_get_keyval(e, addr keyval)
  let mods = modifiers(eventState(e))
  var cp = gdk_keyval_to_unicode(keyval)
  if cp < 0x20 or cp == 0x7f or (mods and (modCtrl or modAlt)) != 0: cp = 0
  let code = ladybirdKey(keyval)
  if code == 0x0D: cp = (if down: 0x0A'u32 else: 0)
  if code == 0 and cp == 0: return 0
  if down and (mods and modCtrl) != 0 and code == 0x56:   # Ctrl+V: hand the page the system clipboard first
    let text = gtk_clipboard_wait_for_text(systemClipboard())
    if text != nil:
      webby_clipboard_set_text(text)
      g_free(text)
  webby_view_key_event(t.view, down.cint, code.cint, mods.cint, cp, 0)
  wake()
  1

proc onFocus(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = currentTab()
  if t != nil: webby_view_set_focus(t.view, cast[int](data).cint)
  0

# ---------------------------------------------------------------------------------------------------------------
# Chrome: toolbar, URL bar, shortcuts

proc onUrlActivate(e: Widget, data: pointer) {.cdecl.} =
  let text = ($gtk_entry_get_text(urlEntry)).strip
  if text.len == 0: return
  let t = currentTab()
  if t == nil: discard openTab(text)
  else:
    t.loadUrl(text)
    gtk_widget_grab_focus(area)

proc onUrlFocusIn(e: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} =
    gtk_editable_select_region(urlEntry, 0, -1)
    0, nil)
  0

proc focusPage*() = gtk_widget_grab_focus(area)

proc goBack*() = (let t = currentTab(); if t != nil: webby_view_go_back(t.view); wake())
proc goForward*() = (let t = currentTab(); if t != nil: webby_view_go_forward(t.view); wake())
proc reloadOrStop*() =
  let t = currentTab()
  if t == nil: return
  if t.loading: webby_view_stop(t.view) else: webby_view_reload(t.view)
  wake()

proc onWindowKey(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  var keyval: cuint
  discard gdk_event_get_keyval(e, addr keyval)
  let mods = modifiers(eventState(e))
  let k = if keyval in 0x41'u32 .. 0x5a'u32: keyval + 0x20 else: keyval
  for s in shortcuts:
    if s.mods == mods and s.keyval == k and s.action():
      return 1
  0

proc quit*() =
  ## Asks the quit hooks (any may cancel), then shuts down.
  if quitting: return
  for h in quitHooks:
    if not h(): return
  quitting = true
  for h in shutdownHooks: h()
  gtk_main_quit()

proc onDelete(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  quit()
  1

proc defaultShortcuts() =
  addShortcut(modCtrl, 0x74, proc () = discard openTab(""))                       # Ctrl+T
  addShortcut(modCtrl, 0x77, proc () = (let t = currentTab(); if t != nil: closeTab(t)))  # Ctrl+W
  addShortcut(modCtrl, 0x6c, proc () = gtk_widget_grab_focus(urlEntry))          # Ctrl+L
  addShortcut(0, 0xffc6, proc () = gtk_widget_grab_focus(urlEntry))              # F6
  addShortcut(modCtrl, 0x72, proc () = (let t = currentTab(); if t != nil: webby_view_reload(t.view); wake()))
  addShortcut(0, 0xffc2, proc () = (let t = currentTab(); if t != nil: webby_view_reload(t.view); wake()))  # F5
  addShortcut(modCtrl, 0xff09, proc () = (if tabs.len > 0: activateTab((activeIndex + 1) mod tabs.len)))
  addShortcut(modCtrl or modShift, 0xfe20,
    proc () = (if tabs.len > 0: activateTab((activeIndex + tabs.len - 1) mod tabs.len)))
  addShortcut(modCtrl, 0xff56, proc () = (if tabs.len > 0: activateTab((activeIndex + 1) mod tabs.len)))  # Ctrl+PgDn
  addShortcut(modCtrl, 0xff55,
    proc () = (if tabs.len > 0: activateTab((activeIndex + tabs.len - 1) mod tabs.len)))           # Ctrl+PgUp
  for i in 1 .. 8:
    let n = i
    addShortcut(modCtrl, uint32(0x30 + n), proc () = activateTab(min(n - 1, tabs.high)))
  addShortcut(modCtrl, 0x39, proc () = activateTab(tabs.high))
  addShortcut(modAlt, 0xff51, goBack)
  addShortcut(modAlt, 0xff53, goForward)
  addShortcut(modCtrl, 0x71, quit)                                               # Ctrl+Q
  addKeyHandler(0, 0xff1b, proc (): bool =                                      # Esc closes the sidebar
    result = sidePanelShowing()
    if result: closeSidePanel())

const css = """
.webby-tab { padding: 4px 6px 4px 10px; border-radius: 6px 6px 0 0; }
.webby-active-tab { background-color: alpha(@theme_selected_bg_color, 0.18); }
.webby-tab-close { padding: 0; min-height: 16px; min-width: 16px; }
.webby-side-panel { border-left: 1px solid alpha(currentColor, 0.15); }
"""

proc buildWindow() =
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
  gtk_window_set_default_size(window, 1280, 800)
  gtk_window_set_title(window, if incognito: "Webby (Incognito)" else: "Webby")
  setAppIcon(window)
  connect(window, "delete-event", onDelete)
  connect(window, "key-press-event", onWindowKey)
  loadCss(css)

  mainBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_container_add(window, mainBox)

  tabStripBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  let scroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(scroller, GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
  tabStrip = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  gtk_container_add(scroller, tabStrip)
  gtk_box_pack_start(tabStripBox, scroller, 1, 1, 0)
  gtk_box_pack_start(tabStripBox, iconButton("add", "New tab (Ctrl+T)", proc () = discard openTab("")),
    0, 0, 0)
  gtk_box_pack_start(mainBox, tabStripBox, 0, 0, 0)

  toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  backButton = iconButton("arrow_back", "Back (Alt+Left)", goBack)
  forwardButton = iconButton("arrow_forward", "Forward (Alt+Right)", goForward)
  reloadButton = iconButton("refresh", "Reload (Ctrl+R)", reloadOrStop)
  urlEntry = gtk_entry_new()
  gtk_entry_set_placeholder_text(urlEntry, "Search or enter address")
  connect(urlEntry, "activate", onUrlActivate)
  connect(urlEntry, "focus-in-event", onUrlFocusIn)
  for b in [backButton, forwardButton, reloadButton]: gtk_box_pack_start(toolbar, b, 0, 0, 0)
  gtk_box_pack_start(toolbar, urlEntry, 1, 1, 4)
  starSlot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  gtk_box_pack_start(toolbar, starSlot, 0, 0, 0)
  toolbarEnd = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  gtk_box_pack_start(toolbar, toolbarEnd, 0, 0, 0)
  moreMenu = gtk_menu_new()
  moreButton = gtk_menu_button_new()
  gtk_button_set_relief(moreButton, GTK_RELIEF_NONE)
  iconButtonImage(moreButton, "more_vert", 18)
  gtk_widget_set_tooltip_text(moreButton, "More")
  gtk_menu_button_set_popup(moreButton, moreMenu)
  gtk_box_pack_start(toolbar, moreButton, 0, 0, 0)
  gtk_box_pack_start(mainBox, toolbar, 0, 0, 2)

  barSlot = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_box_pack_start(mainBox, barSlot, 0, 0, 0)

  pagePane = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)
  pageBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  let pageColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  area = gtk_drawing_area_new()
  gtk_widget_set_can_focus(area, 1)
  gtk_widget_add_events(area, GDK_POINTER_MOTION_MASK or GDK_BUTTON_PRESS_MASK or GDK_BUTTON_RELEASE_MASK or
    GDK_KEY_PRESS_MASK or GDK_KEY_RELEASE_MASK or GDK_LEAVE_NOTIFY_MASK or GDK_FOCUS_CHANGE_MASK or
    GDK_SCROLL_MASK or GDK_SMOOTH_SCROLL_MASK)
  connect(area, "draw", onDraw)
  connect(area, "size-allocate", onSizeAllocate)
  connect(area, "button-press-event", onButton)
  connect(area, "button-release-event", onButton)
  connect(area, "motion-notify-event", onMotion)
  connect(area, "leave-notify-event", onLeave)
  connect(area, "scroll-event", onScroll)
  connect(area, "key-press-event", onKey, cast[pointer](1))
  connect(area, "key-release-event", onKey, cast[pointer](0))
  connect(area, "focus-in-event", onFocus, cast[pointer](1))
  connect(area, "focus-out-event", onFocus, cast[pointer](0))
  gtk_box_pack_start(pageColumn, area, 1, 1, 0)
  status = gtk_label_new("")
  gtk_label_set_xalign(status, 0)
  gtk_label_set_ellipsize(status, PANGO_ELLIPSIZE_END)
  gtk_widget_set_no_show_all(status, 1)
  gtk_box_pack_start(pageColumn, status, 0, 0, 2)
  gtk_box_pack_end(pageBox, pageColumn, 1, 1, 0)
  gtk_paned_pack1(pagePane, pageBox, 1, 0)

  sidePanel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  addClass(sidePanel, "webby-side-panel")
  let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
  sidePanelTitle = gtk_label_new("")
  gtk_label_set_xalign(sidePanelTitle, 0)
  gtk_widget_set_margin_start(sidePanelTitle, 8)
  addClass(sidePanelTitle, "title")
  gtk_box_pack_start(header, sidePanelTitle, 1, 1, 0)
  gtk_box_pack_end(header, iconButton("close", "Close (Esc)", closeSidePanel, 16), 0, 0, 0)
  gtk_box_pack_start(sidePanel, header, 0, 0, 2)
  sidePanelBody = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_box_pack_start(sidePanel, sidePanelBody, 1, 1, 0)
  gtk_widget_set_no_show_all(sidePanel, 1)
  gtk_paned_pack2(pagePane, sidePanel, 0, 0)
  gtk_box_pack_start(mainBox, pagePane, 1, 1, 0)

  if appUrl.len > 0:
    gtk_widget_set_no_show_all(tabStripBox, 1)
    gtk_widget_set_no_show_all(toolbar, 1)

proc parseCommandLine() =
  for a in commandLineParams():
    if a.startsWith("--app="): appUrl = a[6 .. ^1]
    elif a == "--incognito": incognito = true
    elif not a.startsWith("--"): commandLineUrls.add a
  if appUrl.len > 0: incognito = false
  if incognito:
    # Ladybird flags for an engine that forgets everything when the window closes (Incognito.engineFlags).
    var kept: seq[string]
    let words = getEnv("WEBBY_LADYBIRD_ARGS").splitWhitespace
    var i = 0
    while i < words.len:
      let w = words[i]
      if w in ["--profile", "--profile-path"]: inc i
      elif not (w.startsWith("--profile=") or w.startsWith("--profile-path=") or w == "--force-new-process"):
        kept.add w
      inc i
    putEnv("WEBBY_LADYBIRD_ARGS", (kept & @["--temporary-profile", "--disable-sql-database",
      "--disable-http-disk-cache"]).join(" "))

proc run*() =
  randomize()
  parseCommandLine()
  gtk_init(nil, nil)
  if incognito:
    g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", 1.cint, nil)
  for h in startupHooks: h()
  let prefix = ladybirdPrefix()
  loadWebby(prefix)
  if webby_init(prefix.cstring) != 0: quit "webby_init failed for " & prefix
  defaultShortcuts()
  buildWindow()
  for h in windowHooks: h()
  gtk_widget_show_all(window)

  let urls = if appUrl.len > 0: @[appUrl] else: commandLineUrls
  var opened = false
  if appUrl.len == 0:
    for h in initialTabsHooks:
      if h(urls):
        opened = true
        break
  if not opened:
    let first = if urls.len > 0: urls[0] elif incognito: "about:blank" else: homePage
    discard openTab(first)
    for u in urls[min(1, urls.len) .. ^1]: discard openTab(u, focus = false)
    activateTab(0)
  focusPage()
  if trace: discard g_timeout_add(5000, traceTick, nil)
  wake()
  gtk_main()
  for t in tabs: webby_view_destroy(t.view)
