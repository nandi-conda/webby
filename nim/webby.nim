## webby-nim: an experimental webby front end in Nim on GTK 3, without Flutter.
##
## Same engine as the Flutter app (libwebby.so from the webby-ladybird runtime, see native/webby_ffi.h), drawn
## straight from Ladybird's BGRA frame into a GtkDrawingArea with cairo: no copy, no swizzle, no Flutter raster
## thread. Tabs, a URL bar, back/forward/reload, the hovered-link line, page dialogs and the clipboard; everything
## else the Flutter app has (bookmarks, passwords, sync, ...) is left out.
##
## Build: nim c -d:release nim/webby.nim   Run: WEBBY_LADYBIRD_PREFIX=<runtime> nim/webby [url]
## WEBBY_TRACE=1 prints the same pump/frame/wheel-latency counters as the Flutter app every 5 s.

import std/[dynlib, json, monotimes, os, strutils, tables, times]

{.passC: gorge("pkg-config --cflags gtk+-3.0").}
{.passL: gorge("pkg-config --libs gtk+-3.0").}

# ---------------------------------------------------------------------------------------------------------------
# GTK 3 / GDK / cairo: only what this file uses. Widgets and events are opaque; event fields come from accessors.

type
  Widget = pointer
  GEvent = pointer
  Cairo = pointer
  gboolean = cint

const
  GTK_WINDOW_TOPLEVEL = 0.cint
  GTK_ORIENTATION_HORIZONTAL = 0.cint
  GTK_ORIENTATION_VERTICAL = 1.cint
  GTK_RELIEF_NONE = 2.cint
  CAIRO_FORMAT_ARGB32 = 0.cint
  CAIRO_OPERATOR_SOURCE = 1.cint
  GDK_POINTER_MOTION_MASK = 1 shl 2
  GDK_BUTTON_PRESS_MASK = 1 shl 8
  GDK_BUTTON_RELEASE_MASK = 1 shl 9
  GDK_KEY_PRESS_MASK = 1 shl 10
  GDK_KEY_RELEASE_MASK = 1 shl 11
  GDK_LEAVE_NOTIFY_MASK = 1 shl 13
  GDK_FOCUS_CHANGE_MASK = 1 shl 14
  GDK_SCROLL_MASK = 1 shl 21
  GDK_SMOOTH_SCROLL_MASK = 1 shl 23
  GDK_SHIFT_MASK = 1'u32
  GDK_CONTROL_MASK = 1'u32 shl 2
  GDK_MOD1_MASK = 1'u32 shl 3
  GDK_BUTTON1_MASK = 1'u32 shl 8
  GDK_BUTTON2_MASK = 1'u32 shl 9
  GDK_BUTTON3_MASK = 1'u32 shl 10
  GDK_SUPER_MASK = 1'u32 shl 26
  GDK_BUTTON_PRESS = 4.cint
  GDK_SCROLL_UP = 0.cint
  GDK_SCROLL_DOWN = 1.cint
  GDK_SCROLL_LEFT = 2.cint
  GDK_SCROLL_RIGHT = 3.cint
  GTK_MESSAGE_INFO = 0.cint
  GTK_MESSAGE_QUESTION = 2.cint
  GTK_BUTTONS_OK = 1.cint
  GTK_BUTTONS_OK_CANCEL = 5.cint
  GTK_RESPONSE_OK = -5.cint
  GTK_DIALOG_MODAL = 1.cint

{.push cdecl, importc.}
proc gtk_init(argc: pointer, argv: pointer)
proc gtk_main()
proc gtk_main_quit()
proc gtk_window_new(kind: cint): Widget
proc gtk_window_set_title(w: Widget, title: cstring)
proc gtk_window_set_default_size(w: Widget, width, height: cint)
proc gtk_container_add(c, w: Widget)
proc gtk_box_new(orientation, spacing: cint): Widget
proc gtk_box_pack_start(box, child: Widget, expand, fill: gboolean, padding: cuint)
proc gtk_entry_new(): Widget
proc gtk_entry_set_text(e: Widget, text: cstring)
proc gtk_entry_get_text(e: Widget): cstring
proc gtk_button_new_with_label(label: cstring): Widget
proc gtk_button_set_label(b: Widget, label: cstring)
proc gtk_button_set_relief(b: Widget, relief: cint)
proc gtk_label_new(text: cstring): Widget
proc gtk_label_set_text(l: Widget, text: cstring)
proc gtk_label_set_xalign(l: Widget, x: cfloat)
proc gtk_label_set_ellipsize(l: Widget, mode: cint)
proc gtk_label_set_width_chars(l: Widget, n: cint)
proc gtk_label_set_max_width_chars(l: Widget, n: cint)
proc gtk_bin_get_child(b: Widget): Widget
proc gtk_drawing_area_new(): Widget
proc gtk_widget_add_events(w: Widget, events: cint)
proc gtk_widget_set_can_focus(w: Widget, can: gboolean)
proc gtk_widget_grab_focus(w: Widget)
proc gtk_widget_has_focus(w: Widget): gboolean
proc gtk_widget_set_sensitive(w: Widget, on: gboolean)
proc gtk_widget_show_all(w: Widget)
proc gtk_widget_destroy(w: Widget)
proc gtk_widget_queue_draw(w: Widget)
proc gtk_widget_get_allocated_width(w: Widget): cint
proc gtk_widget_get_allocated_height(w: Widget): cint
proc gtk_widget_get_scale_factor(w: Widget): cint
proc gtk_widget_get_window(w: Widget): pointer
proc gtk_widget_get_display(w: Widget): pointer
proc gtk_widget_get_style_context(w: Widget): pointer
proc gtk_style_context_add_class(c: pointer, name: cstring)
proc gtk_style_context_remove_class(c: pointer, name: cstring)
proc gtk_message_dialog_new(parent: Widget, flags, kind, buttons: cint, fmt: cstring): Widget {.varargs.}
proc gtk_dialog_run(d: Widget): cint
proc gtk_clipboard_get(selection: pointer): pointer
proc gtk_clipboard_set_text(cb: pointer, text: cstring, len: cint)
proc gtk_clipboard_wait_for_text(cb: pointer): cstring
proc gdk_atom_intern(name: cstring, onlyIfExists: gboolean): pointer
proc gdk_window_set_cursor(w, cursor: pointer)
proc gdk_cursor_new_from_name(display: pointer, name: cstring): pointer
proc gdk_event_get_event_type(e: GEvent): cint
proc gdk_event_get_coords(e: GEvent, x, y: ptr cdouble): gboolean
proc gdk_event_get_button(e: GEvent, button: ptr cuint): gboolean
proc gdk_event_get_state(e: GEvent, state: ptr uint32): gboolean
proc gdk_event_get_time(e: GEvent): uint32
proc gdk_event_get_scroll_direction(e: GEvent, dir: ptr cint): gboolean
proc gdk_event_get_scroll_deltas(e: GEvent, dx, dy: ptr cdouble): gboolean
proc gdk_event_get_keyval(e: GEvent, keyval: ptr cuint): gboolean
proc gdk_keyval_to_unicode(keyval: cuint): uint32
proc g_signal_connect_data(instance: pointer, signal: cstring, handler, data, destroy: pointer, flags: cint): culong
proc g_timeout_add(ms: cuint, fn, data: pointer): cuint
proc g_idle_add(fn, data: pointer): cuint
proc g_source_remove(id: cuint): gboolean
proc g_free(p: pointer)
proc cairo_image_surface_create_for_data(data: pointer, format, width, height, stride: cint): pointer
proc cairo_surface_destroy(s: pointer)
proc cairo_set_source_surface(cr: Cairo, s: pointer, x, y: cdouble)
proc cairo_set_source_rgb(cr: Cairo, r, g, b: cdouble)
proc cairo_set_operator(cr: Cairo, op: cint)
proc cairo_scale(cr: Cairo, sx, sy: cdouble)
proc cairo_paint(cr: Cairo)
{.pop.}

proc connect(w: pointer, signal: string, handler: pointer, data: pointer = nil) =
  discard g_signal_connect_data(w, signal.cstring, handler, data, nil, 0)

# ---------------------------------------------------------------------------------------------------------------
# libwebby.so, loaded from $WEBBY_LADYBIRD_PREFIX/lib like the Flutter app does.

type View = pointer

var
  webby_init: proc (prefix: cstring): cint {.cdecl.}
  webby_pump: proc (): cint {.cdecl.}
  webby_view_create: proc (w, h: cint, ratio: cdouble): View {.cdecl.}
  webby_view_destroy: proc (v: View) {.cdecl.}
  webby_view_load: proc (v: View, url: cstring) {.cdecl.}
  webby_view_go_back, webby_view_go_forward, webby_view_reload, webby_view_stop: proc (v: View) {.cdecl.}
  webby_view_resize: proc (v: View, w, h: cint, ratio: cdouble) {.cdecl.}
  webby_view_set_focus, webby_view_set_visible: proc (v: View, on: cint) {.cdecl.}
  webby_view_run_javascript: proc (v: View, source: cstring) {.cdecl.}
  webby_view_take_new_view: proc (v: View): View {.cdecl.}
  webby_view_close_requested: proc (v: View): cint {.cdecl.}
  webby_view_frame_serial, webby_view_state_serial: proc (v: View): uint64 {.cdecl.}
  webby_view_frame_pixels: proc (v: View): pointer {.cdecl.}
  webby_view_frame_width, webby_view_frame_height: proc (v: View): cint {.cdecl.}
  webby_view_url, webby_view_title, webby_view_hovered_link: proc (v: View): cstring {.cdecl.}
  webby_view_is_loading, webby_view_can_go_back, webby_view_can_go_forward, webby_view_cursor: proc (v: View): cint {.cdecl.}
  webby_view_dialog, webby_view_webauthn_prompt, webby_view_file_picker_request,
    webby_view_permission_request: proc (v: View): cstring {.cdecl.}
  webby_view_dialog_respond: proc (v: View, id: uint64, accepted: cint, text: cstring) {.cdecl.}
  webby_view_webauthn_respond: proc (v: View, accepted, account: cint) {.cdecl.}
  webby_view_file_picker_respond: proc (v: View, paths: cstring) {.cdecl.}
  webby_view_permission_respond: proc (v: View, id: uint64, granted: cint) {.cdecl.}
  webby_clipboard_serial: proc (): uint64 {.cdecl.}
  webby_clipboard_text: proc (): cstring {.cdecl.}
  webby_clipboard_set_text: proc (text: cstring) {.cdecl.}
  webby_view_mouse_event: proc (v: View, kind, x, y, button, buttons, modifiers, clicks: cint) {.cdecl.}
  webby_view_wheel_event: proc (v: View, x, y: cint, dx, dy: cdouble, precise, modifiers: cint) {.cdecl.}
  webby_view_key_event: proc (v: View, down, keyCode, modifiers: cint, codePoint: uint32, repeat: cint) {.cdecl.}

proc loadWebby(): string =
  let prefix = getEnv("WEBBY_LADYBIRD_PREFIX")
  if prefix.len == 0: quit "Set WEBBY_LADYBIRD_PREFIX to the Ladybird runtime (the webby-ladybird package's lib/webby-ladybird)."
  let lib = loadLib(prefix / "lib" / "libwebby.so")
  if lib == nil: quit "Could not load " & prefix / "lib" / "libwebby.so"
  template sym(p: untyped) = p = cast[typeof(p)](lib.checkedSymAddr(astToStr(p)))
  sym webby_init; sym webby_pump; sym webby_view_create; sym webby_view_destroy; sym webby_view_load
  sym webby_view_go_back; sym webby_view_go_forward; sym webby_view_reload; sym webby_view_stop
  sym webby_view_resize; sym webby_view_set_focus; sym webby_view_set_visible; sym webby_view_run_javascript
  sym webby_view_take_new_view; sym webby_view_close_requested; sym webby_view_frame_serial
  sym webby_view_state_serial; sym webby_view_frame_pixels; sym webby_view_frame_width; sym webby_view_frame_height
  sym webby_view_url; sym webby_view_title; sym webby_view_hovered_link; sym webby_view_is_loading
  sym webby_view_can_go_back; sym webby_view_can_go_forward; sym webby_view_cursor; sym webby_view_dialog
  sym webby_view_webauthn_prompt; sym webby_view_file_picker_request; sym webby_view_permission_request
  sym webby_view_dialog_respond; sym webby_view_webauthn_respond; sym webby_view_file_picker_respond
  sym webby_view_permission_respond; sym webby_clipboard_serial; sym webby_clipboard_text
  sym webby_clipboard_set_text; sym webby_view_mouse_event; sym webby_view_wheel_event; sym webby_view_key_event
  prefix

# The Flutter app's page shims (lib/src/page_compat.dart), read at compile time so both front ends run the same JS.
const pageCompatScript = block:
  let dart = staticRead("../app/lib/src/page_compat.dart")
  let start = dart.find("r'''") + 4
  dart[start ..< dart.rfind("'''")]

# ---------------------------------------------------------------------------------------------------------------
# Browser state

type Tab = ref object
  view: View
  button: Widget
  frameSerial, stateSerial: uint64
  url, title, hovered: string
  loading, canBack, canForward: bool
  cursor: int
  lastCompat: MonoTime
  answering: bool      # a dialog for this tab is open

var
  window, tabBar, urlEntry, area, status, backButton, forwardButton, reloadButton: Widget
  tabs: seq[Tab]
  active = -1
  viewW, viewH, viewScale = 0
  pumpSource: cuint
  pumpDelay = 0
  quietTicks = 0
  pumping = false     # inside pumpAll: it reschedules itself, wake() only marks the tick busy
  wokeInPump = false
  clipboardSerial: uint64
  cursors: Table[int, pointer]
  lastClick: tuple[time: uint32, x, y: float, button: cuint, count: int]
  # WEBBY_TRACE counters
  trace = getEnv("WEBBY_TRACE") == "1"
  pumps, frames, draws: int
  nativeUs, drawUs, maxTickUs: int64
  wheelSent: MonoTime
  wheelPending = false
  wheelFrames: int
  wheelUs, maxWheelUs: int64

proc us(d: Duration): int64 = d.inMicroseconds

proc current(): Tab = (if active in 0 ..< tabs.len: tabs[active] else: nil)

proc tabLabel(t: Tab): string =
  var s = if t.title.len > 0: t.title elif t.url.len > 0: t.url else: "New tab"
  if s.len > 24: s = s[0 ..< 23] & "…"
  s

proc refreshChrome() =
  let t = current()
  if t == nil: return
  gtk_window_set_title(window, cstring(if t.title.len > 0: t.title & " - webby (nim)" else: "webby (nim)"))
  if gtk_widget_has_focus(urlEntry) == 0: gtk_entry_set_text(urlEntry, t.url.cstring)
  gtk_widget_set_sensitive(backButton, t.canBack.gboolean)
  gtk_widget_set_sensitive(forwardButton, t.canForward.gboolean)
  gtk_button_set_label(reloadButton, cstring(if t.loading: "✕" else: "⟳"))
  gtk_label_set_text(status, t.hovered.cstring)
  let win = gtk_widget_get_window(area)
  if win != nil:
    const names = {1: "none", 2: "default", 3: "crosshair", 4: "text", 5: "ew-resize", 6: "ns-resize",
      7: "nwse-resize", 8: "nesw-resize", 9: "col-resize", 10: "row-resize", 11: "pointer", 12: "help", 13: "grab",
      14: "grabbing", 15: "copy", 16: "move", 17: "wait", 18: "not-allowed", 19: "crosshair", 20: "zoom-in"}.toTable
    let id = if t.cursor in names: t.cursor else: 2
    if id notin cursors: cursors[id] = gdk_cursor_new_from_name(gtk_widget_get_display(area), names[id].cstring)
    gdk_window_set_cursor(win, cursors[id])

proc wake()

proc schedule(ms: int)

proc activate(i: int) =
  if i notin 0 ..< tabs.len: return
  if active in 0 ..< tabs.len and active != i:
    webby_view_set_visible(tabs[active].view, 0)
    gtk_style_context_remove_class(gtk_widget_get_style_context(tabs[active].button), "suggested-action")
  active = i
  let t = tabs[i]
  webby_view_set_visible(t.view, 1)
  if viewW > 0: webby_view_resize(t.view, cint(viewW * viewScale), cint(viewH * viewScale), viewScale.cdouble)
  gtk_style_context_add_class(gtk_widget_get_style_context(t.button), "suggested-action")
  refreshChrome()
  gtk_widget_queue_draw(area)
  wake()

proc closeTab(t: Tab)

proc onTabClicked(button: Widget, data: pointer) {.cdecl.} =
  let t = cast[Tab](data)
  let i = tabs.find(t)
  if i >= 0: activate(i)

proc onTabPress(button: Widget, event: GEvent, data: pointer): gboolean {.cdecl.} =
  var b: cuint
  discard gdk_event_get_button(event, addr b)
  if b == 2:   # middle click closes
    closeTab(cast[Tab](data))
    return 1
  0

proc addTab(view: View, focus: bool): Tab =
  let t = Tab(view: view, lastCompat: getMonoTime())
  GC_ref(t)
  t.button = gtk_button_new_with_label("New tab")
  gtk_button_set_relief(t.button, GTK_RELIEF_NONE)
  let label = gtk_bin_get_child(t.button)
  gtk_label_set_ellipsize(label, 3)
  gtk_label_set_width_chars(label, 12)
  gtk_label_set_max_width_chars(label, 24)
  connect(t.button, "clicked", onTabClicked, cast[pointer](t))
  connect(t.button, "button-press-event", onTabPress, cast[pointer](t))
  gtk_box_pack_start(tabBar, t.button, 0, 0, 0)
  gtk_widget_show_all(t.button)
  tabs.add t
  if focus or active < 0: activate(tabs.high)
  else: webby_view_set_visible(view, 0)
  t

proc newView(): View =
  let s = max(viewScale, 1)
  webby_view_create(cint(max(viewW, 1280) * s), cint(max(viewH, 720) * s), s.cdouble)

proc openTab(url: string) =
  let t = addTab(newView(), true)
  if url.len > 0: webby_view_load(t.view, url)
  else: gtk_widget_grab_focus(urlEntry)

proc closeTab(t: Tab) =
  let i = tabs.find(t)
  if i < 0: return
  tabs.delete(i)
  gtk_widget_destroy(t.button)
  webby_view_destroy(t.view)
  GC_unref(t)
  if tabs.len == 0:
    gtk_main_quit()
    return
  if i == active or active >= tabs.len:
    active = -1
    activate(min(i, tabs.high))
  elif i < active:
    dec active

# ---------------------------------------------------------------------------------------------------------------
# Page requests that need an answer. Dialogs open from an idle callback, outside the pump.

proc runDialog(data: pointer): gboolean {.cdecl.} =
  let t = cast[Tab](data)
  if tabs.find(t) < 0: return 0
  let raw = $webby_view_dialog(t.view)
  if raw.len == 0:
    t.answering = false
    return 0
  let j = parseJson(raw)
  let kind = j{"type"}.getStr
  let d = gtk_message_dialog_new(window, GTK_DIALOG_MODAL,
    (if kind == "alert": GTK_MESSAGE_INFO else: GTK_MESSAGE_QUESTION),
    (if kind == "alert": GTK_BUTTONS_OK else: GTK_BUTTONS_OK_CANCEL), "%s", j{"message"}.getStr.cstring)
  let ok = gtk_dialog_run(d) == GTK_RESPONSE_OK
  gtk_widget_destroy(d)
  if tabs.find(t) >= 0:
    webby_view_dialog_respond(t.view, uint64(j{"id"}.getBiggestInt), ok.cint, j{"default"}.getStr.cstring)
  t.answering = false
  wake()
  0

proc answerRequests(t: Tab) =
  if not t.answering and webby_view_dialog(t.view)[0] != '\0':
    t.answering = true
    discard g_idle_add(runDialog, cast[pointer](t))
  # Passkeys, file pickers and permissions aren't built in this shell: decline so the page doesn't wait forever.
  if webby_view_webauthn_prompt(t.view)[0] != '\0': webby_view_webauthn_respond(t.view, 0, 0)
  if webby_view_file_picker_request(t.view)[0] != '\0': webby_view_file_picker_respond(t.view, "[]")
  let perm = $webby_view_permission_request(t.view)
  if perm.len > 0: webby_view_permission_respond(t.view, uint64(parseJson(perm){"id"}.getBiggestInt), 0)

# ---------------------------------------------------------------------------------------------------------------
# The pump: Ladybird's event loop runs on this (the GTK) thread. 4 ms while anything happens, backing off to 100 ms
# when idle, the same schedule as the Flutter app's web_view.dart.

proc pumpTab(t: Tab, isActive: bool): bool =
  var busy = t.loading
  let ss = webby_view_state_serial(t.view)
  if ss != t.stateSerial:
    busy = true
    t.stateSerial = ss
    let before = (t.url, t.title, t.loading)
    t.url = $webby_view_url(t.view)
    t.title = $webby_view_title(t.view)
    t.hovered = $webby_view_hovered_link(t.view)
    t.loading = webby_view_is_loading(t.view) != 0
    t.canBack = webby_view_can_go_back(t.view) != 0
    t.canForward = webby_view_can_go_forward(t.view) != 0
    t.cursor = webby_view_cursor(t.view)
    if (t.url, t.title, t.loading) != before:
      webby_view_run_javascript(t.view, pageCompatScript)
      t.lastCompat = getMonoTime()
    gtk_button_set_label(t.button, tabLabel(t).cstring)
    answerRequests(t)
    while true:
      let v = webby_view_take_new_view(t.view)
      if v == nil: break
      discard addTab(v, true)
    if webby_view_close_requested(t.view) != 0:
      closeTab(t)
      return true
    if isActive: refreshChrome()
  if t.loading and getMonoTime() - t.lastCompat >= initDuration(milliseconds = 100):
    webby_view_run_javascript(t.view, pageCompatScript)
    t.lastCompat = getMonoTime()
  let fs = webby_view_frame_serial(t.view)
  if fs != t.frameSerial:
    t.frameSerial = fs
    busy = true
    if isActive:
      inc frames
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
    gtk_clipboard_set_text(gtk_clipboard_get(gdk_atom_intern("CLIPBOARD", 0)), webby_clipboard_text(), -1)
  let snapshot = tabs
  for t in snapshot:
    if tabs.find(t) >= 0 and pumpTab(t, t == current()): busy = true
  if trace:
    nativeUs += us(t1 - t0)
    maxTickUs = max(maxTickUs, us(getMonoTime() - t0))
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

proc wake() =
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
  let t = current()
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
  let t = current()
  if t != nil:
    webby_view_resize(t.view, cint(nw * ns), cint(nh * ns), ns.cdouble)
    wake()

proc modifiers(state: uint32): cint =
  if (state and GDK_MOD1_MASK) != 0: result = result or 1
  if (state and GDK_CONTROL_MASK) != 0: result = result or 2
  if (state and GDK_SHIFT_MASK) != 0: result = result or 4
  if (state and GDK_SUPER_MASK) != 0: result = result or 8

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

proc eventState(e: GEvent): uint32 =
  discard gdk_event_get_state(e, addr result)

proc onButton(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = current()
  if t == nil: return 0
  # GTK 3 also sends 2BUTTON/3BUTTON events after the presses; the click count is worked out here instead.
  let kind = gdk_event_get_event_type(e)
  if kind == 5 or kind == 6: return 1
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
  webby_view_mouse_event(t.view, (if down: 0 else: 1), x, y, button, held, modifiers(state), lastClick.count.cint)
  wake()
  1

proc onMotion(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = current()
  if t == nil: return 0
  let (x, y, _, _) = eventPos(e)
  let state = eventState(e)
  webby_view_mouse_event(t.view, 2, x, y, 0, heldButtons(state), modifiers(state), 0)
  wake()
  1

proc onLeave(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = current()
  if t != nil: webby_view_mouse_event(t.view, 3, 0, 0, 0, 0, 0, 0)
  0

proc onScroll(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = current()
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
  webby_view_wheel_event(t.view, x, y, dx * s, dy * s, precise, modifiers(eventState(e)))
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
  let t = current()
  if t == nil: return 0
  let down = cast[int](data) == 1
  var keyval: cuint
  discard gdk_event_get_keyval(e, addr keyval)
  let state = eventState(e)
  let mods = modifiers(state)
  var cp = gdk_keyval_to_unicode(keyval)
  if cp < 0x20 or cp == 0x7f or (mods and 3) != 0: cp = 0
  let code = ladybirdKey(keyval)
  if code == 0x0D: cp = (if down: 0x0A'u32 else: 0)
  if code == 0 and cp == 0: return 0
  if down and (mods and 2) != 0 and code == 0x56:   # Ctrl+V: hand the page the system clipboard first
    let text = gtk_clipboard_wait_for_text(gtk_clipboard_get(gdk_atom_intern("CLIPBOARD", 0)))
    if text != nil:
      webby_clipboard_set_text(text)
      g_free(text)
  webby_view_key_event(t.view, down.cint, code.cint, mods, cp, 0)
  wake()
  1

proc onFocus(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  let t = current()
  if t != nil: webby_view_set_focus(t.view, cast[int](data).cint)
  0

# ---------------------------------------------------------------------------------------------------------------
# Chrome: toolbar, URL bar and browser shortcuts

proc onUrlActivate(e: Widget, data: pointer) {.cdecl.} =
  var text = ($gtk_entry_get_text(urlEntry)).strip
  if text.len == 0: return
  let t = current()
  if t == nil: openTab(text)
  else:
    webby_view_load(t.view, text)
    gtk_widget_grab_focus(area)
  wake()

proc onToolbar(b: Widget, data: pointer) {.cdecl.} =
  let t = current()
  if t == nil: return
  case cast[int](data)
  of 1: webby_view_go_back(t.view)
  of 2: webby_view_go_forward(t.view)
  of 3: (if t.loading: webby_view_stop(t.view) else: webby_view_reload(t.view))
  of 4: openTab("")
  else: discard
  wake()

proc onWindowKey(w: Widget, e: GEvent, data: pointer): gboolean {.cdecl.} =
  var keyval: cuint
  discard gdk_event_get_keyval(e, addr keyval)
  let mods = modifiers(eventState(e))
  let t = current()
  let k = if keyval in 0x41'u32 .. 0x5a'u32: keyval + 0x20 else: keyval
  if mods == 2:
    case k
    of 0x74: openTab(""); return 1                                  # Ctrl+T
    of 0x77: (if t != nil: closeTab(t)); return 1                   # Ctrl+W
    of 0x6c: gtk_widget_grab_focus(urlEntry); return 1              # Ctrl+L
    of 0x72: (if t != nil: webby_view_reload(t.view)); wake(); return 1  # Ctrl+R
    of 0xff09: (if tabs.len > 0: activate((active + 1) mod tabs.len)); return 1
    else: discard
  if mods == 6 and k == 0xfe20 and tabs.len > 0:                    # Ctrl+Shift+Tab
    activate((active + tabs.len - 1) mod tabs.len); return 1
  if mods == 0 and k == 0xffc2 and t != nil: webby_view_reload(t.view); wake(); return 1   # F5
  if mods == 1 and t != nil and (k == 0xff51 or k == 0xff53):       # Alt+Left / Alt+Right
    if k == 0xff51: webby_view_go_back(t.view) else: webby_view_go_forward(t.view)
    wake()
    return 1
  0

proc onDestroy(w: Widget, data: pointer) {.cdecl.} = gtk_main_quit()

proc toolButton(label: string, action: int): Widget =
  result = gtk_button_new_with_label(label)
  gtk_button_set_relief(result, GTK_RELIEF_NONE)
  connect(result, "clicked", onToolbar, cast[pointer](action))

proc main() =
  gtk_init(nil, nil)
  let prefix = loadWebby()
  if webby_init(prefix) != 0: quit "webby_init failed for " & prefix

  window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
  gtk_window_set_default_size(window, 1280, 800)
  gtk_window_set_title(window, "webby (nim)")
  connect(window, "destroy", onDestroy)
  connect(window, "key-press-event", onWindowKey)

  let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  gtk_container_add(window, column)

  let tabRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  tabBar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  gtk_box_pack_start(tabRow, tabBar, 0, 0, 0)
  gtk_box_pack_start(tabRow, toolButton("+", 4), 0, 0, 0)
  gtk_box_pack_start(column, tabRow, 0, 0, 0)

  let toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  backButton = toolButton("←", 1)
  forwardButton = toolButton("→", 2)
  reloadButton = toolButton("⟳", 3)
  urlEntry = gtk_entry_new()
  connect(urlEntry, "activate", onUrlActivate)
  for b in [backButton, forwardButton, reloadButton]: gtk_box_pack_start(toolbar, b, 0, 0, 0)
  gtk_box_pack_start(toolbar, urlEntry, 1, 1, 4)
  gtk_box_pack_start(column, toolbar, 0, 0, 2)

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
  gtk_box_pack_start(column, area, 1, 1, 0)

  status = gtk_label_new("")
  gtk_label_set_xalign(status, 0)
  gtk_label_set_ellipsize(status, 3)
  gtk_box_pack_start(column, status, 0, 0, 2)

  gtk_widget_show_all(window)
  let args = commandLineParams()
  openTab(if args.len > 0: args[0] else: "")
  if args.len > 0: gtk_widget_grab_focus(area)
  for url in args[1 .. ^1]:
    let t = addTab(newView(), false)
    webby_view_load(t.view, url)
  if trace: discard g_timeout_add(5000, traceTick, nil)
  wake()
  gtk_main()
  for t in tabs: webby_view_destroy(t.view)

main()
