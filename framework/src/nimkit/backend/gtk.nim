## The GTK 3 backend (Linux desktop): each widget is a GtkWidget, canvases are GtkDrawingAreas painted with cairo
## straight from the pixel buffer (premultiplied 0xAARRGGBB is cairo's ARGB32), timers are GLib sources, storage is
## files in $XDG_DATA_HOME/<appName>/, HTTP is GIO (gio_http.nim).

import std/[os, strutils, tables]
import ../[core, services]
import gtkapi, gio_http

var
  window: GtkWidget
  syncing = false          # true while we set a native widget's state, so its signal isn't taken as the user's
  shownMarks: Table[int, seq[(float, string)]]   # slider id -> the marks its GtkScale has
  shownItems: Table[int, seq[string]]            # dropdown id -> the choices its GtkComboBoxText has

proc byId(data: pointer): Widget = widgets.getOrDefault(cast[int](data))

# ---------------------------------------------------------------------------------------------------------------
# Signals

proc onClicked(b: GtkWidget, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w != nil and w.onClick != nil: w.onClick()

proc onChanged(e: GtkWidget, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w == nil or syncing: return
  w.setTextSilently($gtk_entry_get_text(e))
  if w.onChange != nil: w.onChange(w.text)

proc onActivate(e: GtkWidget, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w != nil and w.onSubmit != nil: w.onSubmit(w.text)

proc onToggled(b: GtkWidget, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w == nil or syncing: return
  w.setCheckedSilently(gtk_toggle_button_get_active(b) != 0)
  if w.onToggle != nil: w.onToggle(w.checked)

proc onValueChanged(r: GtkWidget, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w == nil or syncing: return
  w.setValueSilently(gtk_range_get_value(r))
  if w.onValue != nil: w.onValue(w.value)

proc onComboChanged(c: GtkWidget, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w == nil or syncing: return
  w.setSelectedSilently(gtk_combo_box_get_active(c).int)
  if w.onSelect != nil and w.selected >= 0: w.onSelect(w.selected)

proc escapeMarkup(s: string): string =
  for ch in s:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    else: result.add ch

proc onDraw(area: GtkWidget, cr: pointer, data: pointer): gboolean {.cdecl.} =
  let c = byId(data)
  if c == nil: return 0
  let scale = max(gtk_widget_get_scale_factor(area).int, 1)
  c.resized(gtk_widget_get_allocated_width(area) * scale, gtk_widget_get_allocated_height(area) * scale, scale)
  var px: pointer
  var w, h, stride: int
  if c.external:
    if c.onFrame != nil: c.frame = c.onFrame(c)
    (px, w, h, stride) = c.frame
  elif c.pixels.len > 0: (px, w, h, stride) = (pointer(addr c.pixels[0]), c.width, c.height, c.width * 4)
  if px == nil or w <= 0 or h <= 0: return 0
  let surface = cairo_image_surface_create_for_data(px, CAIRO_FORMAT_ARGB32, w.cint, h.cint, stride.cint)
  let s = 1.0 / c.scale.float
  cairo_scale(cr, s, s)
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
  cairo_set_source_surface(cr, surface, 0, 0)
  cairo_paint(cr)
  cairo_surface_destroy(surface)
  1

proc onSizeAllocate(area: GtkWidget, alloc: pointer, data: pointer) {.cdecl.} =
  # External canvases learn their new size straight away (the app makes a frame for it); pixel canvases on the
  # next draw.
  let c = byId(data)
  if c == nil or not c.external: return
  let scale = max(gtk_widget_get_scale_factor(area).int, 1)
  c.resized(gtk_widget_get_allocated_width(area) * scale, gtk_widget_get_allocated_height(area) * scale, scale)

proc mods(state: uint32): int =
  if (state and GDK_MOD1_MASK) != 0: result = result or modAlt
  if (state and GDK_CONTROL_MASK) != 0: result = result or modCtrl
  if (state and GDK_SHIFT_MASK) != 0: result = result or modShift
  if (state and GDK_SUPER_MASK) != 0: result = result or modSuper

proc heldButtons(state: uint32): int =
  if (state and GDK_BUTTON1_MASK) != 0: result = result or 1
  if (state and GDK_BUTTON3_MASK) != 0: result = result or 2
  if (state and GDK_BUTTON2_MASK) != 0: result = result or 4

proc buttonBit(b: int): int =
  case b
  of 1: 1
  of 2: 4
  of 3: 2
  else: 0

var lastClick: tuple[time: uint32, x, y: float, button, count: int]

proc pointerEvent(area: GtkWidget, ev: pointer, data: pointer, kind: PointerKind): gboolean =
  let c = byId(data)
  if c == nil or c.onPointer == nil: return 0
  var x, y: cdouble
  discard gdk_event_get_coords(ev, addr x, addr y)
  var state: uint32
  discard gdk_event_get_state(ev, addr state)
  var e = PointerEvent(kind: kind, x: x * c.scale.float, y: y * c.scale.float, mods: mods(state),
                       buttons: heldButtons(state))
  if kind in {pkDown, pkUp}:
    # GTK 3 also sends 2BUTTON/3BUTTON events after the presses; the click count is worked out here instead.
    if kind == pkDown and gdk_event_get_event_type(ev) != GDK_BUTTON_PRESS: return 1
    var b: cuint
    discard gdk_event_get_button(ev, addr b)
    e.button = b.int
    if kind == pkDown:
      gtk_widget_grab_focus(area)
      e.buttons = e.buttons or buttonBit(e.button)
      let now = gdk_event_get_time(ev)
      if e.button == lastClick.button and now - lastClick.time < 400 and abs(x - lastClick.x) < 5 and
          abs(y - lastClick.y) < 5:
        inc lastClick.count
      else:
        lastClick.count = 1
      lastClick = (now, x.float, y.float, e.button, lastClick.count)
      e.clicks = lastClick.count
    else:
      e.buttons = e.buttons and not buttonBit(e.button)
  c.onPointer(c, e)
  1

proc onPress(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = pointerEvent(a, ev, data, pkDown)
proc onMotion(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = pointerEvent(a, ev, data, pkMove)
proc onRelease(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = pointerEvent(a, ev, data, pkUp)

proc onLeave(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} =
  let c = byId(data)
  if c != nil and c.onPointer != nil: c.onPointer(c, PointerEvent(kind: pkLeave))
  0

proc onScroll(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} =
  let c = byId(data)
  if c == nil or c.onWheel == nil: return 0
  var x, y, dx, dy: cdouble
  discard gdk_event_get_coords(ev, addr x, addr y)
  var state: uint32
  discard gdk_event_get_state(ev, addr state)
  var precise = false
  var dir: cint
  if gdk_event_get_scroll_deltas(ev, addr dx, addr dy) != 0:
    precise = true
    # A wheel notch arrives as a smooth delta of 1.0 under XInput 2; it's still a notched wheel, not a touchpad.
    if (abs(dx) == 1 or abs(dy) == 1) and (dx == 0 or dy == 0): precise = false
  elif gdk_event_get_scroll_direction(ev, addr dir) != 0:
    case dir
    of GDK_SCROLL_UP: dy = -1
    of GDK_SCROLL_DOWN: dy = 1
    of GDK_SCROLL_LEFT: dx = -1
    of GDK_SCROLL_RIGHT: dx = 1
    else: discard
  c.onWheel(c, WheelEvent(x: x * c.scale.float, y: y * c.scale.float, dx: dx, dy: dy, precise: precise,
                          mods: mods(state))).gboolean

# GDK keyvals to Windows virtual-key codes (Ladybird's KeyCode numbers).
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

proc keyCode(keyval: cuint): int =
  let k = keyval.int
  if k in specialKeys: return specialKeys[k]
  if k in 0xffbe .. 0xffc9: return 0x70 + (k - 0xffbe)            # F1..F12
  if k in 0x61 .. 0x7a: return k - 0x20                            # a..z
  if k in 0x41 .. 0x5a or k in 0x30 .. 0x39: return k
  if k < 0x80 and k.char in punctuation: return punctuation[k.char]
  0

proc onKey(a: GtkWidget, ev: pointer, data: pointer, down: bool): gboolean =
  let c = byId(data)
  if c == nil or c.onKey == nil: return 0
  var keyval: cuint
  discard gdk_event_get_keyval(ev, addr keyval)
  var state: uint32
  discard gdk_event_get_state(ev, addr state)
  var text = gdk_keyval_to_unicode(keyval)
  if text < 0x20 or text == 0x7f: text = 0
  c.onKey(c, KeyEvent(down: down, code: keyCode(keyval), text: text, mods: mods(state), keyval: keyval)).gboolean

proc onKeyPress(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = onKey(a, ev, data, true)
proc onKeyRelease(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = onKey(a, ev, data, false)

proc onFocusChange(a: GtkWidget, ev: pointer, data: pointer, focused: bool): gboolean =
  let c = byId(data)
  if c != nil and c.onFocus != nil: c.onFocus(c, focused)
  0

proc onFocusIn(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = onFocusChange(a, ev, data, true)
proc onFocusOut(a: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = onFocusChange(a, ev, data, false)

# ---------------------------------------------------------------------------------------------------------------
# Native widgets

proc applyExpand(w: Widget) =
  let along = if w.parent != nil and w.parent.kind == wkRow: GTK_ORIENTATION_HORIZONTAL else: GTK_ORIENTATION_VERTICAL
  gtk_widget_set_hexpand(w.native, (w.expanded and along == GTK_ORIENTATION_HORIZONTAL).gboolean)
  gtk_widget_set_vexpand(w.native, (w.expanded and along == GTK_ORIENTATION_VERTICAL).gboolean)

proc sync(w: Widget) =
  syncing = true
  defer: syncing = false
  case w.kind
  of wkColumn, wkRow:
    gtk_box_set_spacing(w.native, w.spacing.cint)
    gtk_container_set_border_width(w.native, w.padding.cuint)
  of wkLabel: gtk_label_set_text(w.native, w.text.cstring)
  of wkButton, wkCheck, wkToggle:
    gtk_button_set_label(w.native, w.text.cstring)
    if w.kind in {wkCheck, wkToggle}: gtk_toggle_button_set_active(w.native, w.checked.gboolean)
  of wkEntry:
    if $gtk_entry_get_text(w.native) != w.text: gtk_entry_set_text(w.native, w.text.cstring)
    gtk_entry_set_placeholder_text(w.native, w.placeholder.cstring)
  of wkCanvas: gtk_widget_set_size_request(w.native, w.minWidth.cint, w.minHeight.cint)
  of wkSlider:
    gtk_range_set_range(w.native, w.rangeMin, w.rangeMax)
    gtk_range_set_increments(w.native, w.step, w.step)
    if gtk_range_get_value(w.native) != w.value: gtk_range_set_value(w.native, w.value)
    if shownMarks.getOrDefault(w.id) != w.marks:
      gtk_scale_clear_marks(w.native)
      for (at, text) in w.marks: gtk_scale_add_mark(w.native, at, GTK_POS_BOTTOM, escapeMarkup(text).cstring)
      shownMarks[w.id] = w.marks
  of wkDropdown:
    if shownItems.getOrDefault(w.id) != w.items:
      gtk_combo_box_text_remove_all(w.native)
      for item in w.items: gtk_combo_box_text_append_text(w.native, item.cstring)
      shownItems[w.id] = w.items
    if gtk_combo_box_get_active(w.native) != w.selected.cint: gtk_combo_box_set_active(w.native, w.selected.cint)
  of wkProgress: gtk_progress_bar_set_fraction(w.native, w.value.clamp(0.0, 1.0))
  of wkScroll: discard
  gtk_widget_set_sensitive(w.native, w.enabled.gboolean)
  w.applyExpand()

proc attach(parent, child: Widget)

proc realize(w: Widget) =
  let data = cast[pointer](w.id)
  w.native = case w.kind
    of wkColumn: gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    of wkRow: gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    of wkScroll:
      let s = gtk_scrolled_window_new(nil, nil)
      gtk_scrolled_window_set_policy(s, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
      s
    of wkLabel:
      let l = gtk_label_new("")
      gtk_label_set_xalign(l, 0)
      gtk_label_set_line_wrap(l, 1)
      l
    of wkButton:
      let b = gtk_button_new_with_label("")
      connect(b, "clicked", onClicked, data)
      b
    of wkEntry:
      let e = gtk_entry_new()
      connect(e, "changed", onChanged, data)
      connect(e, "activate", onActivate, data)
      e
    of wkCheck:
      let b = gtk_check_button_new_with_label("")
      connect(b, "toggled", onToggled, data)
      b
    of wkCanvas:
      let a = gtk_drawing_area_new()
      gtk_widget_set_can_focus(a, 1)
      gtk_widget_add_events(a, GDK_BUTTON_PRESS_MASK or GDK_BUTTON_RELEASE_MASK or GDK_POINTER_MOTION_MASK or
        GDK_KEY_PRESS_MASK or GDK_KEY_RELEASE_MASK or GDK_LEAVE_NOTIFY_MASK or GDK_FOCUS_CHANGE_MASK or
        GDK_SCROLL_MASK or GDK_SMOOTH_SCROLL_MASK)
      connect(a, "draw", onDraw, data)
      connect(a, "size-allocate", onSizeAllocate, data)
      connect(a, "button-press-event", onPress, data)
      connect(a, "motion-notify-event", onMotion, data)
      connect(a, "button-release-event", onRelease, data)
      connect(a, "leave-notify-event", onLeave, data)
      connect(a, "scroll-event", onScroll, data)
      connect(a, "key-press-event", onKeyPress, data)
      connect(a, "key-release-event", onKeyRelease, data)
      connect(a, "focus-in-event", onFocusIn, data)
      connect(a, "focus-out-event", onFocusOut, data)
      a
    of wkSlider:
      let r = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.01)
      gtk_scale_set_draw_value(r, 0)
      connect(r, "value-changed", onValueChanged, data)
      r
    of wkDropdown:
      let c = gtk_combo_box_text_new()
      connect(c, "changed", onComboChanged, data)
      c
    of wkProgress: gtk_progress_bar_new()
    of wkToggle:
      let b = gtk_toggle_button_new_with_label("")
      connect(b, "toggled", onToggled, data)
      b
  discard g_object_ref(w.native)   # ours until the widget is removed, so removing it from a box doesn't free it
  w.realized = true
  w.sync()
  for c in w.children:
    c.realize()
    attach(w, c)

proc attach(parent, child: Widget) =
  if parent.kind == wkScroll: gtk_container_add(parent.native, child.native)
  else: gtk_box_pack_start(parent.native, child.native, 0, 1, 0)
  child.applyExpand()

proc unrealize(w: Widget) =
  for c in w.children: c.unrealize()
  if w.native != nil: g_object_unref(w.native)
  w.native = nil
  shownMarks.del w.id
  shownItems.del w.id
  w.realized = false

proc gtkWidget*(w: Widget): GtkWidget =
  ## `w`'s GtkWidget, made now if it isn't yet: for apps that put nimkit widgets inside GTK widgets of their own
  ## (webby's GTK chrome, while it moves over). The widget stays nimkit's; don't destroy it.
  if not w.realized: w.realize()
  w.native

backend.update = proc (w: Widget) = w.sync()

backend.added = proc (parent, child: Widget, index: int) =
  child.realize()
  attach(parent, child)
  if parent.kind != wkScroll: gtk_box_reorder_child(parent.native, child.native, index.cint)
  gtk_widget_show_all(child.native)

backend.removed = proc (parent, child: Widget) =
  gtk_container_remove(parent.native, child.native)
  child.unrealize()

backend.present = proc (c: Canvas) = gtk_widget_queue_draw(c.native)
backend.focus = proc (w: Widget) = gtk_widget_grab_focus(w.native)
backend.setTitle = proc (title: string) =
  if window != nil: gtk_window_set_title(window, title.cstring)
backend.quit = proc () = gtk_main_quit()

# ---------------------------------------------------------------------------------------------------------------
# Services

type TimerBox = ref object
  id: int
  action: proc ()
  source: cuint

var timers: Table[int, TimerBox]
var nextTimer = 1

proc fire(data: pointer): gboolean {.cdecl.} =
  let box = timers.getOrDefault(cast[int](data))
  if box != nil:
    timers.del box.id
    box.action()
  0

proc dataDir(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".local" / "share") / appName

proc keyFile(key: string): string =
  var name = ""
  for ch in key: name.add(if ch.isAlphaNumeric or ch in "-_.": ch else: '_')
  dataDir() / name

platform = "gtk"
serviceImpl.startTimer = proc (ms: int, action: proc ()): int =
  let box = TimerBox(id: nextTimer, action: action)
  inc nextTimer
  timers[box.id] = box
  box.source = g_timeout_add(max(ms, 0).cuint, fire, cast[pointer](box.id))
  box.id
serviceImpl.stopTimer = proc (id: int) =
  let box = timers.getOrDefault(id)
  if box == nil: return
  timers.del id
  discard g_source_remove(box.source)
serviceImpl.load = proc (key: string): string =
  try: readFile(keyFile(key)) except CatchableError: ""
serviceImpl.store = proc (key, value: string) =
  let path = keyFile(key)
  createDir(path.parentDir)
  writeFile(path & ".tmp", value)
  moveFile(path & ".tmp", path)
serviceImpl.request = gioRequest
serviceImpl.log = proc (text: string) = stderr.writeLine(text)

# ---------------------------------------------------------------------------------------------------------------

proc onDestroy(w: GtkWidget, data: pointer) {.cdecl.} = gtk_main_quit()

proc run*(title: string, root: Widget, width = 480, height = 640) =
  ## Shows `root` in a window and runs until it is closed.
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
  gtk_window_set_title(window, title.cstring)
  gtk_window_set_default_size(window, width.cint, height.cint)
  connect(window, "destroy", onDestroy, nil)
  root.realize()
  gtk_container_add(window, root.native)
  gtk_widget_show_all(window)
  gtk_main()

gtkInit()
