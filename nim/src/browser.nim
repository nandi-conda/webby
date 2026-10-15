## The browser core of webby-nim: window, tabs, page view, input, the Ladybird pump, and the hooks features plug
## into. Features live in src/features/*.nim; each has an `install()` that only appends to the hook lists below
## (UI pieces go in `windowHooks`, which run once the window exists). Nothing here knows about a feature.

import std/[algorithm, json, math, monotimes, os, random, strutils, tables, times]
import base, gtk, ffi, icons
from icondata as idata import nil
import nimkit/services
from nimkit/core as kit import nil
from nimkit/backend/gtk as nkgtk import nil   # nimkit on GTK; also fills in its services (timers, HTTP, storage)

appName = "webby"
userAgent = "webby"
export base, gtk, ffi, icons, json, tables

# The Flutter app's page shims (lib/src/page_compat.dart), read at compile time so both front ends run the same JS.
const pageCompatScript* = block:
  let dart = staticRead("../../app/lib/src/page_compat.dart")
  let start = dart.find("r'''") + 4
  dart[start ..< dart.rfind("'''")]

# Blank tabs and startup show the start page (features/home.nim draws it into about:blank).
const homePage* = "about:blank"

# Ladybird modifier bits (Web::UIEvents::KeyModifier), used by shortcuts too.
const modAlt* = 1
const modCtrl* = 2
const modShift* = 4
const modSuper* = 8

type
  Tab* = ref object
    view*: View              ## nil while the tab sleeps (no page, no WebContent process); see ensureView
    button*: kit.Widget      ## the tab's item in the tab strip
    label*: kit.Widget       ## the label inside it
    icon*: kit.Widget        ## an icon before the label (features may set a favicon with kit.`image=`)
    closeButton*: kit.Widget ## the × at its end
    url*, title*, hovered*: string
    loading*, canBack*, canForward*: bool
    cursor*: int
    pinned*: bool
    findCurrent*, findTotal*: int  ## native find in page: the 1-based active match (0 = none) and the match count
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
  commandLineUrls*: seq[string]

  # Widgets
  window*, mainBox*, tabStripBox*, toolbar*, toolbarEnd*, area*, status*: Widget
  urlField*: kit.Widget        ## the URL bar (features/omnibox.nim adds its suggestions and keys)
  urlFocused*: bool            ## the URL bar has the keyboard focus
  tabStrip*: kit.Widget        ## the tabs' row (a column with vertical tabs), inside a scroll view in tabStripBox
  tabStripSpace*: kit.Widget   ## the strip's empty space after the tabs (the last child of tabStrip)
  tabStripRoot*: kit.Widget    ## tabStripBox as nimkit sees it: the scroll view and the new-tab button
  barSlot*: Widget             ## a box under the toolbar (the bookmark bar goes here)
  findSlot*: Widget            ## a box under the page (the find bar goes here)
  pagePane*: Widget            ## GtkPaned: the page on the left, the side panel on the right
  pageBox*: Widget             ## holds the vertical tab list (if any) and the page area
  page*: kit.Canvas            ## the page view: a nimkit canvas showing the active tab's frame (its GtkWidget is `area`)
  sidePanel*: Widget           ## the side panel's box (hidden when nothing shows)
  sidePanelTitle*: Widget
  sidePanelBody*: Widget
  starSlot*: Widget            ## a box inside the URL bar row, right of the entry (the bookmark star goes here)
  toolbarRow*: kit.Widget      ## the toolbar as nimkit sees it (`toolbar` is its GtkBox)
  starSlotRow*, toolbarEndRow*: kit.Widget  ## `starSlot` and `toolbarEnd` as nimkit rows
  urlSlotRow*: kit.Widget      ## holds the URL entry, in toolbarRow
  backButton*, forwardButton*, reloadButton*, moreButton*: kit.Widget

  tabs*: seq[Tab]
  activeIndex* = -1

  # Hooks
  startupHooks*: seq[proc ()]                     ## before Ladybird starts
  windowHooks*: seq[proc ()]                      ## once the window and its boxes exist
  initialTabsHooks*: seq[proc (urls: seq[string]): bool]  ## first one returning true opened the start tabs
  tabCreatedHooks*: seq[proc (t: Tab)]
  viewCreatedHooks*: seq[proc (t: Tab)]           ## a sleeping tab got its view back (ensureView)
  tabClosedHooks*: seq[proc (t: Tab)]             ## before the view is destroyed
  activeTabHooks*: seq[proc (t: Tab)]
  tabStateHooks*: seq[proc (t: Tab)]              ## url, title, loading or history changed
  findHooks*: seq[proc (t: Tab)]                  ## a native find-in-page result arrived (findCurrent/findTotal)
  navigationHooks*: seq[proc (t: Tab)]            ## a page finished loading (url + title final)
  pageMessageHooks*: seq[proc (t: Tab, msg: string): bool]  ## true = handled
  pageScriptHooks*: seq[proc (t: Tab): string]    ## JS run with the compat shims on every page
  quitHooks*: seq[proc (): bool]                  ## false cancels quitting
  shutdownHooks*: seq[proc ()]                    ## quitting for real
  tabStripHooks*: seq[proc ()]                    ## tabs added, removed, moved or pinned
  pumpHooks*: seq[proc ()]                        ## every pump tick, after Ladybird's events ran (keep them cheap)
  suggestionProviders*: seq[proc (text: string): seq[Suggestion]]
  tabMenuHooks*: seq[proc (t: Tab, items: var seq[kit.MenuItem])]  ## right-click on a tab: append menu items
  moreMenuHooks*: seq[proc (items: var seq[kit.MenuItem])]  ## the ⋮ menu, built each time it opens; see addMenuItem
  pagePointerHooks*: seq[proc (t: Tab, e: kit.PointerEvent): bool]  ## before the page gets it; true = handled
  urlFocusHooks*: seq[proc (focused: bool)]       ## the URL bar got or lost the keyboard focus
  pageContextMenuHook*: proc (t: Tab, info: JsonNode, x, y: float) ## replaces the built-in page menu if set; x, y:
                                                                   ## where, in the page canvas's pixels

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
  shortcuts: seq[tuple[mods: int, keyval: uint32, action: proc (): bool]]
  quitting = false
  # Wheel coalescing: while a sent wheel event hasn't produced a new frame yet, later ones add up here and go out
  # as one event with the next frame (or after wheelHoldMs), so a fast touchpad can't queue work in the engine.
  wheelQ: tuple[t: Tab, x, y: cint, dx, dy: float, precise, mods: cint, pending: bool]
  wheelInFlight = false
  wheelSentAt: MonoTime
  # Smooth wheel scrolling: a mouse-wheel notch glides in along an ease-out curve instead of jumping. smooth.rem is
  # the distance the curve still has to cover (it decays with smoothTau); each event sent to the page carries the
  # curve's position at the time its frame should be on screen (frameEst ahead), so a page that draws every 60 ms
  # still moves most of a notch on its first frame while a fast page glides over several. smooth.left is what the
  # page has yet to be sent of the notches so far.
  smooth: tuple[t: Tab, x, y: cint, remX, remY, leftX, leftY: float, at: MonoTime, active: bool]
  frameEstMs = 16.0
  # WEBBY_TRACE counters
  trace = getEnv("WEBBY_TRACE") == "1"
  startedAt = getMonoTime()
  framesMarked = 0
  firstDrawSeen = false
  pumps, frames, draws: int
  nativeUs, drawUs, maxTickUs: int64
  wheelSent: MonoTime
  wheelPending = false
  wheelFrames: int
  wheelUs, maxWheelUs: int64

proc us(d: Duration): int64 = d.inMicroseconds

const wheelHoldMs = 50

const smoothTau = 40.0   # ms; the curve is 95% done after ~120 ms

proc flushWheel()

proc advanceSmooth() =
  let now = getMonoTime()
  let decay = exp(-(now - smooth.at).inMicroseconds.float / 1000 / smoothTau)
  smooth.at = now
  smooth.remX *= decay; smooth.remY *= decay

# Moves the smooth-scroll curve to now and, unless a sent wheel event still awaits its frame, sends the page the
# distance to where the curve will be when the next frame shows.
proc stepSmooth() =
  if not smooth.active: return
  advanceSmooth()
  if smooth.t.closed:
    smooth.active = false
    return
  if wheelInFlight: return
  let ahead = exp(-frameEstMs / smoothTau)
  var tx = smooth.remX * ahead
  var ty = smooth.remY * ahead
  if abs(tx) < 0.5 and abs(ty) < 0.5:
    tx = 0; ty = 0
    smooth.active = false
  let dx = smooth.leftX - tx
  let dy = smooth.leftY - ty
  smooth.leftX = tx; smooth.leftY = ty
  if abs(dx) < 0.01 and abs(dy) < 0.01: return
  if wheelQ.pending and (wheelQ.t != smooth.t or wheelQ.precise != 1 or wheelQ.mods != 0): flushWheel()
  if wheelQ.pending:
    wheelQ.dx += dx; wheelQ.dy += dy
  else:
    wheelQ = (smooth.t, smooth.x, smooth.y, dx, dy, 1.cint, 0.cint, true)
  flushWheel()

proc flushWheel() =
  if not wheelQ.pending: return
  wheelQ.pending = false
  wheelInFlight = true
  wheelSentAt = getMonoTime()
  let q = wheelQ
  if not q.t.closed:
    webby_view_wheel_event(q.t.view, q.x, q.y, q.dx, q.dy, q.precise, q.mods)

# ---------------------------------------------------------------------------------------------------------------
# Timers for base.startTimer: nimkit's (GLib sources, from its GTK backend)

base.startTimer = serviceImpl.startTimer
base.stopTimer = serviceImpl.stopTimer

# ---------------------------------------------------------------------------------------------------------------
# Tabs

proc wake*()
proc schedule(ms: int)

proc currentTab*(): Tab = (if activeIndex in 0 ..< tabs.len: tabs[activeIndex] else: nil)

proc tabLabel*(t: Tab): string =
  if t.url == "about:blank": "New tab" elif t.title.len > 0: t.title elif t.url.len > 0: t.url else: "New tab"

proc runJs*(t: Tab, source: string) =
  if t != nil and not t.closed and t.view != nil: webby_view_run_javascript(t.view, source.cstring)

proc refreshChrome*() =
  let t = currentTab()
  if t == nil: return
  let name = if incognito: "Webby (Incognito)" else: "Webby"
  # An installed web app's window is titled by the app alone.
  let title = if appUrl.len > 0 and t.title.len > 0: t.title
              elif t.title.len > 0: t.title & " - " & name else: name
  gtk_window_set_title(window, title.cstring)
  if not urlFocused: kit.`text=`(urlField, if t.url == "about:blank": "" else: t.url)
  kit.`enabled=`(backButton, t.canBack)
  kit.`enabled=`(forwardButton, t.canForward)
  kit.`iconName=`(reloadButton, if t.loading: "close" else: "refresh")
  kit.`tooltip=`(reloadButton, if t.loading: "Stop" else: "Reload (Ctrl+R)")
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
  kit.`text=`(t.label, if t.pinned: "" else: s)
  kit.`visible=`(t.label, not t.pinned)
  kit.`tooltip=`(t.button, s)

proc notifyTabStrip*() =
  for h in tabStripHooks: h()

proc resizeView(t: Tab) =
  if viewW > 0 and t.view != nil: webby_view_resize(t.view, cint(viewW * viewScale), cint(viewH * viewScale), viewScale.cdouble)

proc ensureView*(t: Tab)

proc activateTab*(i: int) =
  if i notin 0 ..< tabs.len: return
  if activeIndex in 0 ..< tabs.len and activeIndex != i:
    if tabs[activeIndex].view != nil: webby_view_set_visible(tabs[activeIndex].view, 0)
    kit.removeClass(tabs[activeIndex].button, "webby-active-tab")
  activeIndex = i
  let t = tabs[i]
  ensureView(t)
  webby_view_set_visible(t.view, 1)
  resizeView(t)
  kit.addClass(t.button, "webby-active-tab")
  refreshChrome()
  kit.invalidate(page)
  for h in activeTabHooks: h(t)
  wake()

proc activateTab*(t: Tab) = activateTab(tabs.find(t))

proc closeTab*(t: Tab)

proc tabMenu(t: Tab) =
  var items: seq[kit.MenuItem]
  for h in tabMenuHooks: h(t, items)
  if items.len == 0: items.add kit.menuItem("Close tab", proc () = closeTab(t))
  kit.popupMenu(items)

proc randomPrefix(): string =
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  result = "webby-msg-"
  for _ in 0 ..< 16: result.add chars[rand(chars.high)]
  result.add ':'

proc newViewSized(): View =
  let s = max(viewScale, 1)
  webby_view_create(cint(max(viewW, 1280) * s), cint(max(viewH, 720) * s), s.cdouble)

proc ensureView*(t: Tab) =
  ## Gives a sleeping tab (view = nil) a fresh, hidden, empty view; selecting a tab or loading into it does this.
  if t.view != nil or t.closed: return
  t.view = newViewSized()
  webby_view_set_message_prefix(t.view, t.messagePrefix.cstring)
  webby_view_set_visible(t.view, 0)
  t.stateSerial = 0
  t.frameSerial = 0
  for h in viewCreatedHooks: h(t)

proc sleepTab*(t: Tab) =
  ## Throws away the tab's view and its WebContent process, keeping the tab (url and title stay as they were).
  if t.view == nil or t == currentTab(): return
  let old = t.view
  t.view = nil
  webby_view_destroy(old)

proc adoptView*(view: View, focus = true, index = -1): Tab =
  ## Adds a tab around an existing view (one a page opened, or one made by newViewSized), or a sleeping tab when
  ## `view` is nil (it gets a view when it's selected or loads something).
  let t = Tab(view: view, lastCompat: getMonoTime(), messagePrefix: randomPrefix())
  GC_ref(t)
  if view != nil: webby_view_set_message_prefix(view, t.messagePrefix.cstring)
  t.icon = kit.icon("public", 14)
  t.label = kit.label("New tab")
  kit.`maxChars=`(t.label, 22)
  t.closeButton = kit.iconButton("close", "Close tab", proc () = closeTab(t), 14)
  kit.addClass(t.closeButton, "webby-tab-close")
  t.button = kit.item(t.icon, kit.expand(kit.sized(t.label, 100)), t.closeButton, onClick = proc () = activateTab(t))
  t.button.spacing = 4
  kit.addClass(t.button, "webby-tab")
  t.button.onMiddle = proc () = closeTab(t)
  t.button.onContext = proc () = tabMenu(t)
  let at = if index in 0 .. tabs.len: index else: tabs.len
  tabs.insert(t, at)
  kit.insert(tabStrip, t.button, at)
  if at <= activeIndex: inc activeIndex
  for h in tabCreatedHooks: h(t)
  if focus or activeIndex < 0: activateTab(at)
  elif view != nil: webby_view_set_visible(view, 0)
  notifyTabStrip()
  t

proc loadUrl*(t: Tab, text: string) =
  if t == nil: return
  ensureView(t)
  webby_view_load(t.view, text.cstring)
  wake()

proc focusUrl*() =
  ## Puts the keyboard focus in the URL bar (its text selected).
  kit.focus(urlField)
  kit.selectAll(urlField)

proc openTab*(url: string, focus = true, index = -1): Tab =
  let t = adoptView(newViewSized(), focus, index)
  if url.len > 0: t.loadUrl(url)
  if (url.len == 0 or url == homePage) and focus:
    kit.`text=`(urlField, "")
    focusUrl()
  t

proc moveTab*(t: Tab, index: int) =
  let i = tabs.find(t)
  if i < 0 or index notin 0 ..< tabs.len or index == i: return
  let cur = currentTab()
  tabs.delete(i)
  tabs.insert(t, index)
  kit.insert(tabStrip, t.button, index)
  activeIndex = tabs.find(cur)
  notifyTabStrip()

proc quit*()

proc closeTab*(t: Tab) =
  let i = tabs.find(t)
  if i < 0: return
  for h in tabClosedHooks: h(t)
  tabs.delete(i)
  t.closed = true
  kit.remove(tabStrip, t.button)
  if t.view != nil: webby_view_destroy(t.view)
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

var kitButtons: Table[pointer, kit.Widget]   # iconButton's GtkWidgets -> their nimkit buttons

proc iconButton*(icon, tooltip: string, action: proc () {.closure.}, size = 18): Widget =
  ## A flat button with one of the Flutter app's icons (an Icons.* name, see icons.nim), as a GtkWidget for GTK
  ## boxes; a nimkit iconButton underneath (setButtonIcon changes its icon).
  let b = kit.iconButton(icon, tooltip, action, size)
  result = nkgtk.gtkWidget(b)
  kitButtons[result] = b
  connect(result, "destroy", proc (w: Widget, d: pointer) {.cdecl.} = kitButtons.del w)

proc setButtonIcon*(button: Widget, icon: string) =
  ## Switches the icon of a button made by iconButton.
  let b = kitButtons.getOrDefault(button)
  if b != nil: kit.`iconName=`(b, icon)

var panelButtons: seq[tuple[button: kit.Widget, icon, openIcon, panel: string]]
var openPanel: string   ## the side panel's title while it shows

proc refreshPanelButtons() =
  for b in panelButtons:
    kit.`iconName=`(b.button, if b.panel == openPanel: b.openIcon else: b.icon)

proc addToolbarButton*(icon, tooltip: string, action: proc () {.closure.}, openIcon = "", panel = ""): kit.Widget
    {.discardable.} =
  ## A button right of the URL bar, before the ⋮ menu. A button that toggles a side panel names it (its title) and
  ## the icon to show while it is open, as the Flutter app swaps Icons.key_outlined for Icons.key.
  result = kit.iconButton(icon, tooltip, action)
  kit.add(toolbarEndRow, result)
  if openIcon.len > 0: panelButtons.add (result, icon, openIcon, panel)

proc shortcutText*(mods: int, keyval: uint32): string =
  ## "Ctrl+Shift+T" for a shortcut's mods and GDK keyval, to show in menus.
  if (mods and modCtrl) != 0: result.add "Ctrl+"
  if (mods and modAlt) != 0: result.add "Alt+"
  if (mods and modShift) != 0: result.add "Shift+"
  if (mods and modSuper) != 0: result.add "Super+"
  result.add(
    if keyval in 0x61'u32 .. 0x7a'u32: $chr(keyval - 0x20)
    elif keyval in 0x20'u32 .. 0x7e'u32: $chr(keyval)
    elif keyval in 0xffbe'u32 .. 0xffc9'u32: "F" & $(keyval - 0xffbe + 1)
    else:
      case keyval
      of 0xffff: "Delete"
      of 0xff1b: "Esc"
      of 0xff09: "Tab"
      of 0xff51: "Left"
      of 0xff53: "Right"
      else: "")

proc addMenuItem*(label: string, action: proc () {.closure.}, shortcut = "") =
  ## An item in the ⋮ (More) menu.
  moreMenuHooks.add proc (items: var seq[kit.MenuItem]) = items.add kit.menuItem(label, action, shortcut = shortcut)

proc addMenuCheck*(label: string, checked: proc (): bool, action: proc () {.closure.}, shortcut = "") =
  ## A check item in the ⋮ menu; `checked` is asked each time the menu opens.
  moreMenuHooks.add proc (items: var seq[kit.MenuItem]) =
    var it = kit.checkItem(label, checked(), action)
    it.shortcut = shortcut
    items.add it

proc addMenuSeparator*() =
  moreMenuHooks.add proc (items: var seq[kit.MenuItem]) =
    if items.len > 0 and not items[^1].separator: items.add kit.menuSeparator()

proc moreMenuItems(): seq[kit.MenuItem] =
  var all: seq[kit.MenuItem]
  for h in moreMenuHooks: h(all)
  for it in all:   # no separator first, last or twice in a row
    if it.separator and (result.len == 0 or result[^1].separator): continue
    result.add it
  while result.len > 0 and result[^1].separator: result.setLen(result.len - 1)

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
  # Right after a load starts, the tab's URL is already the new page's while its document is still the about:blank
  # one being navigated away from. Our scripts there (several of them talk back through prompt()) can wedge
  # Ladybird's navigation: under CPU load the new page's DOMContentLoaded and first paint then wait out a 15 s timeout.
  # So a tab that isn't headed for about:blank skips that document; the 100 ms re-runs while loading reach the new one.
  let (open, close) = if t.url == "about:blank": ("", "") else: ("if (location.href !== 'about:blank') {\n", "\n}")
  t.runJs(open & pageCompatScript & close)
  for h in pageScriptHooks:
    let js = h(t)
    if js.len > 0: t.runJs(open & js & close)

template mark*(what: string) =
  ## WEBBY_TRACE=1: when each step of startup happened, in ms since the process started.
  if trace: stderr.writeLine "webby-startup ", (getMonoTime() - startedAt).inMilliseconds, " ms ", what

proc pumpTab(t: Tab, isActive: bool): bool =
  if t.view == nil: return false
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
    if hasNativeFind():
      let found = (int(webby_view_find_current(t.view)), int(webby_view_find_total(t.view)))
      if found != (t.findCurrent, t.findTotal):
        (t.findCurrent, t.findTotal) = found
        for h in findHooks: h(t)
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
    if trace and framesMarked < 3:
      inc framesMarked
      mark "frame " & $fs & " " & t.url
    if isActive:
      inc frames
      if wheelInFlight:
        wheelInFlight = false
        let ms = (getMonoTime() - wheelSentAt).inMicroseconds.float / 1000
        frameEstMs = clamp(frameEstMs * 0.7 + ms * 0.3, 8.0, 120.0)
        flushWheel()
        stepSmooth()
      if trace and wheelPending:
        let d = us(getMonoTime() - wheelSent)
        wheelPending = false
        inc wheelFrames
        wheelUs += d
        maxWheelUs = max(maxWheelUs, d)
      kit.invalidate(page)
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
  for h in pumpHooks: h()
  var snapshot = tabs   # a copy: pumpTab may add or close tabs
  for t in snapshot:
    if not t.closed and pumpTab(t, t == currentTab()): busy = true
  if trace:
    nativeUs += us(t1 - t0)
    maxTickUs = max(maxTickUs, us(getMonoTime() - t0))
  if wheelInFlight and getMonoTime() - wheelSentAt >= initDuration(milliseconds = wheelHoldMs):
    wheelInFlight = false
    flushWheel()
  stepSmooth()
  if wheelQ.pending or smooth.active: busy = true
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

# CPU time of this process and its helpers, for WEBBY_TRACE: "webby-cpu" lines give each process's (and its busiest
# threads') share of one core since the last tick, read from /proc.
var cpuTicks: Table[string, int]   # "pid" or "pid/tid" -> utime + stime clock ticks
var cpuLast = getMonoTime()

proc statFields(path: string): (string, seq[string]) =
  # comm is in parentheses and may contain spaces; the fields after it are space-separated.
  try:
    let s = readFile(path)
    let a = s.find('(')
    let b = s.rfind(')')
    if a < 0 or b < a: return ("", @[])
    (s[a + 1 ..< b], s[b + 2 .. ^1].splitWhitespace())
  except CatchableError: ("", @[])

proc cpuReport(): string =
  let now = getMonoTime()
  let secs = max((now - cpuLast).inMicroseconds.float / 1e6, 0.001)
  cpuLast = now
  # Our process tree: pid -> parent, from /proc/<pid>/stat (state is field 0 after comm, ppid field 1).
  var parent: Table[int, int]
  var names: Table[int, string]
  for kind, path in walkDir("/proc"):
    let pid = try: parseInt(path.extractFilename) except ValueError: -1
    if pid < 0: continue
    let (name, f) = statFields(path / "stat")
    if f.len < 2: continue
    parent[pid] = parseInt(f[1])
    names[pid] = name
  let me = getCurrentProcessId()
  proc ours(pid: int): bool =
    var p = pid
    for _ in 0 .. 32:
      if p == me: return true
      if p <= 1 or p notin parent: return false
      p = parent[p]
    false
  var fresh: Table[string, int]
  var parts: seq[string]
  for pid, name in names:
    if not ours(pid): continue
    let (_, f) = statFields("/proc" / $pid / "stat")
    if f.len < 13: continue
    let ticks = parseInt(f[11]) + parseInt(f[12])
    fresh[$pid] = ticks
    let pct = (ticks - cpuTicks.getOrDefault($pid, ticks)).float / secs   # 100 ticks/s = 100%
    if pct < 2: continue
    # The busiest threads of a busy process, which tell e.g. LibJS from Wasm from painting apart.
    var threads: seq[(float, string)]
    for kind, tpath in walkDir("/proc" / $pid / "task"):
      let tid = tpath.extractFilename
      let (tname, tf) = statFields(tpath / "stat")
      if tf.len < 13: continue
      let tt = parseInt(tf[11]) + parseInt(tf[12])
      let key = $pid & "/" & tid
      fresh[key] = tt
      let tp = (tt - cpuTicks.getOrDefault(key, tt)).float / secs
      if tp >= 5: threads.add((tp, tname))
    threads.sort(proc (a, b: (float, string)): int = cmp(b[0], a[0]))
    var part = (if pid == me: "UI" else: name) & "=" & $int(pct) & "%"
    if threads.len > 1:
      part.add " ["
      for i, (tp, tname) in threads:
        if i >= 3: break
        if i > 0: part.add ", "
        part.add tname & " " & $int(tp) & "%"
      part.add "]"
    parts.add part
  cpuTicks = fresh
  parts.join("  ")

proc traceTick(data: pointer): gboolean {.cdecl.} =
  stderr.writeLine "webby-cpu ", cpuReport()
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

proc goBack*()
proc goForward*()

proc pageFrame(c: kit.Canvas): tuple[data: pointer, width, height, stride: int] =
  ## The page canvas paints the active tab's current frame. Ladybird's frame is premultiplied BGRA, which is
  ## cairo's ARGB32 on little-endian, so nimkit draws it in place.
  if trace: inc draws
  let t = currentTab()
  if t == nil or t.view == nil: return
  let fw = webby_view_frame_width(t.view)
  let fh = webby_view_frame_height(t.view)
  let px = webby_view_frame_pixels(t.view)
  if fw <= 0 or fh <= 0 or px == nil: return
  if not firstDrawSeen:
    firstDrawSeen = true
    mark "first frame drawn"
  (px, fw.int, fh.int, fw.int * 4)

proc pageResized(c: kit.Canvas) =
  viewScale = c.scale
  viewW = c.width div c.scale
  viewH = c.height div c.scale
  let t = currentTab()
  if t != nil:
    resizeView(t)
    wake()

proc modifiers*(state: uint32): int =
  ## GDK modifier state as modAlt/modCtrl/modShift/modSuper (for the chrome's own GTK events).
  if (state and GDK_MOD1_MASK) != 0: result = result or modAlt
  if (state and GDK_CONTROL_MASK) != 0: result = result or modCtrl
  if (state and GDK_SHIFT_MASK) != 0: result = result or modShift
  if (state and GDK_SUPER_MASK) != 0: result = result or modSuper

proc eventState*(e: GEvent): uint32 =
  discard gdk_event_get_state(e, addr result)

proc ladybirdButton(b: int): cint =
  case b
  of 1: 1
  of 2: 4
  of 3: 2
  of 8: 8
  of 9: 16
  else: 0

var lastClicks = 1   # the last press's click count, which its release repeats

proc pagePointer(c: kit.Canvas, e: kit.PointerEvent) =
  let t = currentTab()
  if t == nil or t.view == nil: return
  for h in pagePointerHooks:
    if h(t, e): return
  let x = cint(e.x)
  let y = cint(e.y)
  case e.kind
  of kit.pkDown, kit.pkUp:
    let down = e.kind == kit.pkDown
    if down:
      lastClicks = e.clicks
      if e.button == 8: goBack(); return
      if e.button == 9: goForward(); return
    webby_view_mouse_event(t.view, cint(if down: mouseDown else: mouseUp), x, y, ladybirdButton(e.button),
      e.buttons.cint, e.mods.cint, lastClicks.cint)
  of kit.pkMove: webby_view_mouse_event(t.view, mouseMove, x, y, 0, e.buttons.cint, e.mods.cint, 0)
  of kit.pkLeave: webby_view_mouse_event(t.view, mouseLeave, 0, 0, 0, 0, 0, 0)
  of kit.pkCancel: return
  wake()

proc pageWheel(c: kit.Canvas, e: kit.WheelEvent): bool =
  let t = currentTab()
  if t == nil or t.view == nil: return false
  let x = cint(e.x)
  let y = cint(e.y)
  let (dx, dy) = (e.dx, e.dy)
  let precise = e.precise.cint
  # 53 logical pixels per wheel step, as Flutter's Linux embedder scrolls.
  let s = 53.0 * max(viewScale, 1).float
  if trace and not wheelPending:
    wheelSent = getMonoTime()
    wheelPending = true
  let mods = e.mods.cint
  # A plain wheel notch joins the smooth-scroll curve; touchpads already scroll smoothly, and Ctrl+wheel zooms.
  if precise == 0 and mods == 0:
    if smooth.active and smooth.t == t:
      advanceSmooth()
      # A reversed notch starts the curve over from where the page is rather than unwinding the old one first.
      if smooth.remY * dy < 0 or smooth.remX * dx < 0:
        smooth.remX = smooth.leftX; smooth.remY = smooth.leftY
      smooth.remX += dx * s; smooth.remY += dy * s
      smooth.leftX += dx * s; smooth.leftY += dy * s
    else:
      smooth = (t, x, y, dx * s, dy * s, dx * s, dy * s, getMonoTime(), true)
    smooth.x = x; smooth.y = y
    stepSmooth()
    wake()
    return true
  if smooth.active: smooth.active = false
  if wheelQ.pending and (wheelQ.t != t or wheelQ.precise != precise or wheelQ.mods != mods): flushWheel()
  if wheelQ.pending:
    wheelQ.x = x; wheelQ.y = y; wheelQ.dx += dx * s; wheelQ.dy += dy * s
  else:
    wheelQ = (t, x, y, dx * s, dy * s, precise, mods, true)
  if not wheelInFlight or getMonoTime() - wheelSentAt >= initDuration(milliseconds = wheelHoldMs): flushWheel()
  wake()
  true

proc pageKey(c: kit.Canvas, e: kit.KeyEvent): bool =
  let t = currentTab()
  if t == nil or t.view == nil: return false
  var cp = e.text
  if (e.mods and (modCtrl or modAlt)) != 0: cp = 0
  if e.code == 0x0D: cp = (if e.down: 0x0A'u32 else: 0)
  if e.code == 0 and cp == 0: return false
  if e.down and (e.mods and modCtrl) != 0 and e.code == 0x56:   # Ctrl+V: hand the page the system clipboard first
    let text = gtk_clipboard_wait_for_text(systemClipboard())
    if text != nil:
      webby_clipboard_set_text(text)
      g_free(text)
  webby_view_key_event(t.view, e.down.cint, e.code.cint, e.mods.cint, cp, 0)
  wake()
  true

proc pageFocus(c: kit.Canvas, focused: bool) =
  let t = currentTab()
  if t != nil and t.view != nil: webby_view_set_focus(t.view, focused.cint)

# ---------------------------------------------------------------------------------------------------------------
# Chrome: toolbar, URL bar, shortcuts

proc onUrlSubmit(text: string) =
  let text = text.strip
  if text.len == 0: return
  let t = currentTab()
  if t == nil: discard openTab(text)
  else:
    t.loadUrl(text)
    gtk_widget_grab_focus(area)

proc onUrlFocus(focused: bool) =
  urlFocused = focused
  # The whole address is selected on focus, after the click that focused it has placed the cursor.
  if focused: discard after(0, proc () = (if urlFocused: kit.selectAll(urlField)))
  for h in urlFocusHooks: h(focused)

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
  addShortcut(modCtrl, 0x74, proc () = discard openTab(homePage))                       # Ctrl+T
  addShortcut(modCtrl, 0x77, proc () = (let t = currentTab(); if t != nil: closeTab(t)))  # Ctrl+W
  addShortcut(modCtrl, 0x6c, focusUrl)                                           # Ctrl+L
  addShortcut(modAlt, 0x66, proc () = kit.popupMenu(moreMenuItems(), moreButton))  # Alt+F, the ⋮ menu
  addShortcut(0, 0xffc6, focusUrl)                                               # F6
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
button.webby-tab { padding: 4px 6px 4px 10px; border-radius: 6px 6px 0 0; min-height: 0; }
button.webby-active-tab { background-color: alpha(@theme_selected_bg_color, 0.18); }
.webby-tab-close { padding: 0; min-height: 16px; min-width: 16px; }
.webby-side-panel { border-left: 1px solid alpha(currentColor, 0.15); }
.webby-link-status { background-color: @theme_bg_color; padding: 2px 8px; font-size: smaller;
  border-top: 1px solid alpha(currentColor, 0.15); border-right: 1px solid alpha(currentColor, 0.15);
  border-radius: 0 6px 0 0; }
"""

proc buildTabStrip*(vertical: bool) =
  ## Makes the strip (again): a row of tabs under the window's top, or a column of them for vertical tabs. The tabs
  ## move over from the old strip; the caller puts the new tabStripBox where it goes.
  let old = tabStrip
  tabStrip = if vertical: kit.column() else: kit.row()
  tabStrip.spacing = 2
  if old != nil:
    while old.children.len > 0:
      let c = old.children[0]
      kit.remove(old, c, keep = true)
      kit.add(tabStrip, c)
  else:
    tabStripSpace = kit.expand(kit.item())
    kit.addClass(tabStripSpace, "webby-strip-space")
    kit.add(tabStrip, tabStripSpace)
  let newTab = kit.iconButton("add", "New tab (Ctrl+T)", proc () = discard openTab(homePage))
  tabStripRoot = if vertical: kit.column(kit.expand(kit.scroll(tabStrip)), newTab)
                 else: kit.row(kit.expand(kit.scroll(tabStrip, horizontal = true)), newTab)
  tabStripRoot.spacing = 0
  tabStripBox = nkgtk.gtkWidget(tabStripRoot)

proc buildWindow() =
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
  gtk_window_set_default_size(window, 1280, 800)
  gtk_window_set_title(window, if incognito: "Webby (Incognito)" else: "Webby")
  setAppIcon(window)
  connect(window, "delete-event", onDelete)
  connect(window, "key-press-event", onWindowKey)
  nkgtk.useWindow(window)   # nimkit's menus and dialogs belong to it (its own key and close handlers do nothing)
  kit.registerIcons(idata.iconPaths, idata.iconEm)
  loadCss(css)

  mainBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_container_add(window, mainBox)

  buildTabStrip(vertical = false)
  gtk_box_pack_start(mainBox, tabStripBox, 0, 0, 0)

  backButton = kit.iconButton("arrow_back", "Back (Alt+Left)", goBack)
  forwardButton = kit.iconButton("arrow_forward", "Forward (Alt+Right)", goForward)
  reloadButton = kit.iconButton("refresh", "Reload (Ctrl+R)", reloadOrStop)
  moreButton = kit.iconButton("more_vert", "More (Alt+F)", proc () = kit.popupMenu(moreMenuItems(), moreButton))
  urlField = kit.entry("Search or enter address")
  urlField.onSubmit = onUrlSubmit
  urlField.onFocusChange = onUrlFocus
  urlSlotRow = kit.expand(kit.row(kit.expand(urlField)))
  starSlotRow = kit.row()
  toolbarEndRow = kit.row()
  for r in [starSlotRow, toolbarEndRow]: r.spacing = 0
  toolbarRow = kit.row(backButton, forwardButton, reloadButton, urlSlotRow, starSlotRow, toolbarEndRow, moreButton)
  toolbarRow.spacing = 2
  toolbar = nkgtk.gtkWidget(toolbarRow)
  starSlot = nkgtk.gtkWidget(starSlotRow)
  toolbarEnd = nkgtk.gtkWidget(toolbarEndRow)
  gtk_box_pack_start(mainBox, toolbar, 0, 0, 2)

  barSlot = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_box_pack_start(mainBox, barSlot, 0, 0, 0)

  pagePane = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)
  pageBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  let pageColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  page = kit.externalCanvas()
  page.onFrame = pageFrame
  page.onResize = pageResized
  page.onPointer = pagePointer
  page.onWheel = pageWheel
  page.onKey = pageKey
  page.onFocus = pageFocus
  area = nkgtk.gtkWidget(page)
  # The hovered-link bubble floats over the page's bottom-left corner: packed in the box, showing it shrank the
  # page view, which re-laid out the page and flickered on every hover.
  let pageOverlay = gtk_overlay_new()
  gtk_container_add(pageOverlay, area)
  status = gtk_label_new("")
  gtk_label_set_xalign(status, 0)
  gtk_label_set_ellipsize(status, PANGO_ELLIPSIZE_END)
  gtk_label_set_max_width_chars(status, 80)
  gtk_widget_set_halign(status, GTK_ALIGN_START)
  gtk_widget_set_valign(status, GTK_ALIGN_END)
  addClass(status, "webby-link-status")
  gtk_widget_set_no_show_all(status, 1)
  gtk_overlay_add_overlay(pageOverlay, status)
  gtk_overlay_set_overlay_pass_through(pageOverlay, status, 1)
  gtk_box_pack_start(pageColumn, pageOverlay, 1, 1, 0)
  findSlot = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_box_pack_start(pageColumn, findSlot, 0, 0, 0)
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

const incognitoPrefix = "webby-incognito-"

proc incognitoRoot(): string =
  let r = getEnv("XDG_RUNTIME_DIR")
  if r.len > 0 and dirExists(r): r else: getTempDir()

proc sweepIncognitoProfiles() =
  ## Deletes incognito profiles whose window is gone (crashed or killed before it could delete its own).
  for kind, path in walkDir(incognitoRoot()):
    let name = path.extractFilename
    if kind != pcDir or not name.startsWith(incognitoPrefix): continue
    let owner = try: parseInt(name[incognitoPrefix.len .. ^1]) except ValueError: continue
    if owner == getCurrentProcessId() or dirExists("/proc/" & $owner): continue
    try: removeDir(path) except OSError: discard

proc parseCommandLine() =
  for a in commandLineParams():
    if a.startsWith("--app="): appUrl = a[6 .. ^1]
    elif a == "--incognito": incognito = true
    elif not a.startsWith("--"): commandLineUrls.add a
  if appUrl.len > 0: incognito = false
  if incognito:
    # Ladybird flags for an engine that forgets everything when the window closes (Incognito.engineFlags), with a
    # throwaway profile of our own instead of --temporary-profile so features can seed it (the ad blocker's switch
    # and lists): deleted on exit, swept at the next start if a crash left it.
    sweepIncognitoProfiles()
    incognitoProfile = incognitoRoot() / (incognitoPrefix & $getCurrentProcessId())
    removeDir(incognitoProfile)
    createDir(incognitoProfile)
    var kept: seq[string]
    let words = getEnv("WEBBY_LADYBIRD_ARGS").splitWhitespace
    originalLadybirdArgs = words
    var i = 0
    while i < words.len:
      let w = words[i]
      if w in ["--profile", "--profile-path"]: inc i
      elif not (w.startsWith("--profile=") or w.startsWith("--profile-path=") or
                w in ["--force-new-process", "--temporary-profile"]):
        kept.add w
      inc i
    putEnv("WEBBY_LADYBIRD_ARGS", (kept & @["--profile-path=" & incognitoProfile, "--disable-sql-database",
      "--disable-http-disk-cache"]).join(" "))

proc run*() =
  randomize()
  parseCommandLine()
  mark "main"
  gtk_init(nil, nil)
  mark "gtk_init"
  if incognito:
    g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", 1.cint, nil)
  for h in startupHooks: h()
  mark "startup hooks"
  let prefix = ladybirdPrefix()
  loadWebby(prefix)
  if webby_init(prefix.cstring) != 0: quit "webby_init failed for " & prefix
  mark "webby_init"
  defaultShortcuts()
  buildWindow()
  for h in windowHooks: h()
  mark "window hooks"
  gtk_widget_show_all(window)
  mark "window shown"

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
  mark "tabs opened"
  focusPage()
  if trace: discard g_timeout_add(5000, traceTick, nil)
  wake()
  gtk_main()
  for t in tabs:
    if t.view != nil: webby_view_destroy(t.view)
  if incognitoProfile.len > 0:
    try: removeDir(incognitoProfile) except OSError: discard
