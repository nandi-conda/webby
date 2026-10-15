## The GTK 3 backend (Linux desktop): each widget is a GtkWidget, canvases are GtkDrawingAreas painted with cairo
## straight from the pixel buffer (premultiplied 0xAARRGGBB is cairo's ARGB32), timers are GLib sources, storage is
## files in $XDG_DATA_HOME/<appName>/, HTTP is GIO (gio_http.nim).

import std/[os, sets, strutils, tables]
import ../[core, glyphs, services]
import gtkapi, gio_http

var
  window: GtkWidget
  syncing = false          # true while we set a native widget's state, so its signal isn't taken as the user's
  shownMarks: Table[int, seq[(float, string)]]   # slider id -> the marks its GtkScale has
  shownItems: Table[int, seq[string]]            # dropdown id -> the choices its GtkComboBoxText has
  shownClasses: Table[int, seq[string]]          # widget id -> the style classes its GtkWidget has
  shownIcons: Table[int, (string, int)]          # button/toggle/item id -> the icon its image shows
  shownLabels: Table[int, string]                # button/check/toggle id -> its label text (absent: no label)
  inner: Table[int, GtkWidget]                   # item id -> the box inside its GtkButton

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

proc onItemPress(b: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} =
  let w = byId(data)
  if w == nil: return 0
  var button: cuint
  discard gdk_event_get_button(ev, addr button)
  if gdk_event_get_event_type(ev) == GDK_2BUTTON_PRESS and button == 1 and w.onDoubleClick != nil:
    w.onDoubleClick()
    return 1
  if gdk_event_get_event_type(ev) != GDK_BUTTON_PRESS: return 0
  if button == 3 and w.onContext != nil: w.onContext(); return 1
  if button == 2 and w.onMiddle != nil: w.onMiddle(); return 1
  0

proc onEntryFocus(e: GtkWidget, ev: pointer, data: pointer, focused: bool): gboolean =
  let w = byId(data)
  if w != nil and w.onFocusChange != nil: w.onFocusChange(focused)
  0

proc onEntryFocusIn(e: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = onEntryFocus(e, ev, data, true)
proc onEntryFocusOut(e: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} = onEntryFocus(e, ev, data, false)

proc keyEvent(ev: pointer, down: bool): KeyEvent

proc onEntryKey(e: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} =
  let w = byId(data)
  if w == nil or w.onEntryKey == nil: return 0
  w.onEntryKey(keyEvent(ev, true)).gboolean

var pictures: Table[int, tuple[bytes: string, size: int, pixbuf: pointer]]   # icon id -> its image, decoded

proc picture(w: Widget, scale: int): pointer =
  ## `w.image` decoded at the icon's size in device pixels (nil if it isn't a picture GdkPixbuf reads).
  let px = w.iconSize * scale
  let had = pictures.getOrDefault(w.id)
  if had.bytes == w.image and had.size == px: return had.pixbuf
  if had.pixbuf != nil: g_object_unref(had.pixbuf)
  var pix: pointer
  let bytes = w.image
  let l = gdk_pixbuf_loader_new()
  if gdk_pixbuf_loader_write(l, unsafeAddr bytes[0], bytes.len.csize_t, nil) != 0 and
      gdk_pixbuf_loader_close(l, nil) != 0:
    let full = gdk_pixbuf_loader_get_pixbuf(l)
    if full != nil: pix = gdk_pixbuf_scale_simple(full, px.cint, px.cint, GDK_INTERP_BILINEAR)
  else:
    discard gdk_pixbuf_loader_close(l, nil)
  g_object_unref(l)
  pictures[w.id] = (w.image, px, pix)
  pix

proc onIconDraw(area: GtkWidget, cr: pointer, data: pointer): gboolean {.cdecl.} =
  # The glyph in the widget's text colour (the button's, inside a button), centred, like a symbolic icon; or the
  # icon's picture.
  let w = byId(data)
  if w == nil: return 0
  if w.image.len > 0:
    let scale = max(gtk_widget_get_scale_factor(area).int, 1)
    let p = w.picture(scale)
    if p != nil:
      let size = w.iconSize.float
      cairo_save(cr)
      cairo_translate(cr, ((gtk_widget_get_allocated_width(area).float - size) / 2).int.float,
        ((gtk_widget_get_allocated_height(area).float - size) / 2).int.float)
      cairo_scale(cr, 1 / scale.float, 1 / scale.float)
      gdk_cairo_set_source_pixbuf(cr, p, 0, 0)
      cairo_paint(cr)
      cairo_restore(cr)
      return 1
  let g = glyph(w.iconName)
  if g == nil: return 0
  let size = w.iconSize.float
  let ctx = gtk_widget_get_style_context(area)
  var c: GdkRGBA
  gtk_style_context_get_color(ctx, gtk_style_context_get_state(ctx), addr c)
  cairo_save(cr)
  cairo_translate(cr, ((gtk_widget_get_allocated_width(area).float - size) / 2).int.float,
    ((gtk_widget_get_allocated_height(area).float - size) / 2).int.float)
  cairo_scale(cr, size / iconEm.float, size / iconEm.float)
  cairo_new_path(cr)
  for (op, p) in g.ops:
    case op
    of goMove: cairo_move_to(cr, p[0], p[1])
    of goLine: cairo_line_to(cr, p[0], p[1])
    of goCurve: cairo_curve_to(cr, p[0], p[1], p[2], p[3], p[4], p[5])
    of goClose: cairo_close_path(cr)
  cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
  cairo_fill(cr)
  cairo_restore(cr)
  1

proc glyphArea(w: Widget): GtkWidget =
  ## A drawing area showing `w`'s icon (an icon widget's own, or the image of a button with an icon).
  result = gtk_drawing_area_new()
  gtk_widget_set_size_request(result, w.iconSize.cint, w.iconSize.cint)
  connect(result, "draw", onIconDraw, cast[pointer](w.id))

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

proc keyEvent(ev: pointer, down: bool): KeyEvent =
  var keyval: cuint
  discard gdk_event_get_keyval(ev, addr keyval)
  var state: uint32
  discard gdk_event_get_state(ev, addr state)
  var text = gdk_keyval_to_unicode(keyval)
  if text < 0x20 or text == 0x7f: text = 0
  KeyEvent(down: down, code: keyCode(keyval), text: text, mods: mods(state), keyval: keyval)

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
  let along = if w.parent != nil and w.parent.kind in {wkRow, wkItem}: GTK_ORIENTATION_HORIZONTAL else: GTK_ORIENTATION_VERTICAL
  gtk_widget_set_hexpand(w.native, (w.expanded and along == GTK_ORIENTATION_HORIZONTAL).gboolean)
  gtk_widget_set_vexpand(w.native, (w.expanded and along == GTK_ORIENTATION_VERTICAL).gboolean)

const classCss = """
.nk-heading { font-weight: bold; font-size: 1.2em; }
.nk-bold { font-weight: bold; }
.nk-dim { opacity: 0.65; }
.nk-small { font-size: 0.85em; }
.nk-mono { font-family: monospace; }
.nk-error { color: #c01c28; }
.nk-selected { background-color: alpha(@theme_selected_bg_color, 0.25); }
.nk-popover { border: 1px solid alpha(currentColor, 0.2); }
.nk-dialog-title { font-weight: bold; font-size: larger; }
.nk-card { border: 1px solid alpha(currentColor, 0.15); border-radius: 6px; padding: 8px; }
button.nk-item { padding: 2px 6px; }
"""

var cssLoaded = false

proc syncClasses(w: Widget) =
  if not cssLoaded:
    cssLoaded = true
    let p = gtk_css_provider_new()
    discard gtk_css_provider_load_from_data(p, classCss.cstring, classCss.len, nil)
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), p, GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
  let want = w.classes
  let have = shownClasses.getOrDefault(w.id)
  if want == have: return
  let ctx = gtk_widget_get_style_context(w.native)
  proc gtkNames(name: string): seq[string] =
    case name
    of "suggested": @["suggested-action"]
    of "destructive": @["destructive-action"]
    of "flat": @["flat"]
    else: @["nk-" & name, name]
  for c in have:
    if c notin want:
      for n in gtkNames(c): gtk_style_context_remove_class(ctx, n.cstring)
  for c in want:
    if c notin have:
      for n in gtkNames(c): gtk_style_context_add_class(ctx, n.cstring)
  if w.kind in {wkButton, wkToggle, wkItem}:
    gtk_button_set_relief(w.native, (if "flat" in want or w.kind == wkItem: GTK_RELIEF_NONE else: 0.cint))
  shownClasses[w.id] = want

proc syncButtonIcon(w: Widget) =
  let want = (w.iconName, w.iconSize)
  if shownIcons.getOrDefault(w.id) == want: return
  shownIcons[w.id] = want
  let old = gtk_button_get_image(w.native)
  if w.iconName.len == 0:
    gtk_button_set_image(w.native, nil)
  elif old != nil:
    # The image draws the widget's current icon: resize and redraw it rather than rebuild the button's insides.
    gtk_widget_set_size_request(old, w.iconSize.cint, w.iconSize.cint)
    gtk_widget_queue_draw(old)
  else:
    let a = glyphArea(w)
    gtk_widget_show(a)
    gtk_button_set_image(w.native, a)
    gtk_button_set_always_show_image(w.native, 1)

# ---------------------------------------------------------------------------------------------------------------
# Drag and drop within the app: the dragged item's data travels in `dragPayload`.

var
  dragTarget = GtkTargetEntry(target: "nimkit/item", flags: GTK_TARGET_SAME_APP, info: 0)
  dragPayload: string
  dragSources, dropTargets: HashSet[int]

proc onDragBegin(g: GtkWidget, ctx: pointer, data: pointer) {.cdecl.} =
  let w = byId(data)
  dragPayload = if w != nil: w.dragData else: ""

proc onDragDataGet(g: GtkWidget, ctx, sel: pointer, info, time: cuint, data: pointer) {.cdecl.} =
  gtk_selection_data_set(sel, gtk_selection_data_get_target(sel), 8, dragPayload.cstring, dragPayload.len.cint)

proc onDragEnd(g: GtkWidget, ctx: pointer, data: pointer) {.cdecl.} =
  # After drag-data-received, which reads the payload.
  dragPayload = ""

proc onDragReceived(g: GtkWidget, ctx: pointer, x, y: cint, sel: pointer, info, time: cuint,
                    data: pointer) {.cdecl.} =
  let w = byId(data)
  if w == nil or w.dropHandler == nil or dragPayload.len == 0: return
  let h = w.dropHandler
  let payload = dragPayload
  h(payload, x.float / max(gtk_widget_get_allocated_width(g), 1).float,
    y.float / max(gtk_widget_get_allocated_height(g), 1).float)

proc onActivateLink(l: GtkWidget, uri: cstring, data: pointer): gboolean {.cdecl.} =
  let w = byId(data)
  if w != nil and w.onLink != nil and w.onLink($uri): 1 else: 0

proc atEnd(adj: pointer): bool =
  gtk_adjustment_get_value(adj) >= gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj) - 24

proc onAdjustmentChanged(adj: pointer, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w != nil and w.followEnd:
    gtk_adjustment_set_value(adj, gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj))

proc onAdjustmentValue(adj: pointer, data: pointer) {.cdecl.} =
  let w = byId(data)
  if w != nil and w.followEnd and not atEnd(adj): w.setFollowSilently(false)

proc syncDrag(w: Widget) =
  let data = cast[pointer](w.id)
  if w.dragData.len > 0 and w.id notin dragSources:
    dragSources.incl w.id
    gtk_drag_source_set(w.native, GDK_BUTTON1_MASK.cuint, addr dragTarget, 1, GDK_ACTION_MOVE)
    connect(w.native, "drag-begin", onDragBegin, data)
    connect(w.native, "drag-data-get", onDragDataGet, data)
    connect(w.native, "drag-end", onDragEnd, data)
  if w.dropHandler != nil and w.id notin dropTargets:
    dropTargets.incl w.id
    gtk_drag_dest_set(w.native, GTK_DEST_DEFAULT_ALL, addr dragTarget, 1, GDK_ACTION_MOVE)
    connect(w.native, "drag-data-received", onDragReceived, data)

proc sync(w: Widget) =
  syncing = true
  defer: syncing = false
  case w.kind
  of wkColumn, wkRow:
    gtk_box_set_spacing(w.native, w.spacing.cint)
    gtk_container_set_border_width(w.native, w.padding.cuint)
  of wkLabel:
    if w.rich: gtk_label_set_markup(w.native, w.text.cstring)
    else: gtk_label_set_text(w.native, w.text.cstring)
    gtk_label_set_selectable(w.native, w.selectable.gboolean)
    if w.selectable: gtk_widget_set_can_focus(w.native, 0)
    gtk_label_set_line_wrap(w.native, (w.maxChars == 0).gboolean)
    gtk_label_set_ellipsize(w.native, if w.maxChars > 0: PANGO_ELLIPSIZE_END else: PANGO_ELLIPSIZE_NONE)
    # A wrapping label asks for a readable line's width (not its whole text's, which would widen dialogs); one that
    # expands asks for little and wraps to the room it gets.
    gtk_label_set_max_width_chars(w.native, (if w.maxChars > 0: w.maxChars elif w.expanded: 1 else: 70).cint)
  of wkButton, wkCheck, wkToggle:
    # A button with only an icon has no label at all (an empty label would still take room). Only changes are
    # set: setting a GtkButton's label rebuilds its insides, and one rebuilt while the pointer is over it stops
    # taking clicks until the pointer leaves.
    if w.text.len > 0 or w.iconName.len == 0 or w.kind == wkCheck:
      if shownLabels.getOrDefault(w.id, "\0") != w.text:
        gtk_button_set_label(w.native, w.text.cstring)
        shownLabels[w.id] = w.text
    elif w.id in shownLabels:
      gtk_button_set_label(w.native, nil)
      shownLabels.del w.id
    if w.kind in {wkButton, wkToggle}: w.syncButtonIcon()
    if w.kind in {wkCheck, wkToggle}: gtk_toggle_button_set_active(w.native, w.checked.gboolean)
  of wkItem:
    gtk_box_set_spacing(inner[w.id], w.spacing.cint)
    gtk_container_set_border_width(inner[w.id], w.padding.cuint)
  of wkIcon:
    gtk_widget_set_size_request(w.native, w.iconSize.cint, w.iconSize.cint)
    gtk_widget_queue_draw(w.native)
  of wkSeparator: discard
  of wkEntry:
    if $gtk_entry_get_text(w.native) != w.text: gtk_entry_set_text(w.native, w.text.cstring)
    gtk_entry_set_placeholder_text(w.native, w.placeholder.cstring)
    gtk_entry_set_visibility(w.native, (not w.password).gboolean)
  of wkCanvas: discard
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
  of wkScroll:
    if w.followEnd: onAdjustmentChanged(gtk_scrolled_window_get_vadjustment(w.native), cast[pointer](w.id))
    if w.horizontal: gtk_scrolled_window_set_policy(w.native, GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
    else: gtk_scrolled_window_set_policy(w.native, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  if w.kind != wkIcon:
    gtk_widget_set_size_request(w.native, (if w.minWidth > 0: w.minWidth else: -1).cint,
                                (if w.minHeight > 0: w.minHeight else: -1).cint)
  gtk_widget_set_sensitive(w.native, w.enabled.gboolean)
  gtk_widget_set_tooltip_text(w.native, (if w.tooltip.len > 0: w.tooltip.cstring else: nil))
  gtk_widget_set_no_show_all(w.native, (not w.visible).gboolean)
  gtk_widget_set_visible(w.native, w.visible.gboolean)
  w.syncClasses()
  w.applyExpand()
  w.syncDrag()

proc attach(parent, child: Widget)

proc realize(w: Widget) =
  let data = cast[pointer](w.id)
  w.native = case w.kind
    of wkColumn: gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
    of wkRow: gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
    of wkScroll:
      let s = gtk_scrolled_window_new(nil, nil)
      gtk_scrolled_window_set_policy(s, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
      let adj = gtk_scrolled_window_get_vadjustment(s)
      connect(adj, "changed", onAdjustmentChanged, data)
      connect(adj, "value-changed", onAdjustmentValue, data)
      s
    of wkLabel:
      let l = gtk_label_new("")
      gtk_label_set_xalign(l, 0)
      gtk_label_set_line_wrap(l, 1)
      gtk_label_set_line_wrap_mode(l, PANGO_WRAP_WORD_CHAR)
      connect(l, "activate-link", onActivateLink, data)
      l
    of wkButton:
      let b = gtk_button_new_with_label("")
      shownLabels[w.id] = ""
      connect(b, "clicked", onClicked, data)
      b
    of wkEntry:
      let e = gtk_entry_new()
      connect(e, "changed", onChanged, data)
      connect(e, "activate", onActivate, data)
      connect(e, "key-press-event", onEntryKey, data)
      connect(e, "focus-in-event", onEntryFocusIn, data)
      connect(e, "focus-out-event", onEntryFocusOut, data)
      e
    of wkIcon: glyphArea(w)
    of wkItem:
      let b = gtk_button_new()
      let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
      gtk_container_add(b, box)
      inner[w.id] = box
      gtk_style_context_add_class(gtk_widget_get_style_context(b), "nk-item")
      gtk_button_set_relief(b, GTK_RELIEF_NONE)
      gtk_widget_set_focus_on_click(b, 0)   # a click on a row (a tab) leaves the keyboard focus where it was
      connect(b, "clicked", onClicked, data)
      connect(b, "button-press-event", onItemPress, data)
      b
    of wkSeparator:
      gtk_separator_new(if w.parent != nil and w.parent.kind in {wkRow, wkItem}: GTK_ORIENTATION_VERTICAL
                        else: GTK_ORIENTATION_HORIZONTAL)
    of wkCheck:
      let b = gtk_check_button_new_with_label("")
      shownLabels[w.id] = ""
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
      shownLabels[w.id] = ""
      connect(b, "toggled", onToggled, data)
      b
  discard g_object_ref(w.native)   # ours until the widget is removed, so removing it from a box doesn't free it
  w.realized = true
  w.sync()
  for c in w.children:
    c.realize()
    attach(w, c)

proc box(w: Widget): GtkWidget = (if w.kind == wkItem: inner[w.id] else: w.native)

proc attach(parent, child: Widget) =
  if parent.kind == wkScroll: gtk_container_add(parent.native, child.native)
  else: gtk_box_pack_start(parent.box, child.native, 0, 1, 0)
  child.applyExpand()

proc unrealize(w: Widget) =
  for c in w.children: c.unrealize()
  if w.native != nil: g_object_unref(w.native)
  w.native = nil
  shownMarks.del w.id
  shownItems.del w.id
  shownClasses.del w.id
  shownIcons.del w.id
  shownLabels.del w.id
  if w.id in pictures:
    if pictures[w.id].pixbuf != nil: g_object_unref(pictures[w.id].pixbuf)
    pictures.del w.id
  inner.del w.id
  dragSources.excl w.id
  dropTargets.excl w.id
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
  if parent.kind != wkScroll: gtk_box_reorder_child(parent.box, child.native, index.cint)
  gtk_widget_show_all(child.native)

backend.removed = proc (parent, child: Widget) =
  gtk_container_remove(parent.box, child.native)
  child.unrealize()

backend.moved = proc (parent, child: Widget, index: int) =
  if parent.kind != wkScroll: gtk_box_reorder_child(parent.box, child.native, index.cint)

backend.selectAll = proc (w: Widget) =
  if w.kind == wkEntry: gtk_editable_select_region(w.native, 0, -1)

backend.present = proc (c: Canvas) = gtk_widget_queue_draw(c.native)
backend.focus = proc (w: Widget) = gtk_widget_grab_focus(w.native)
backend.setTitle = proc (title: string) =
  if window != nil: gtk_window_set_title(window, title.cstring)
backend.quit = proc () = gtk_main_quit()

# ---------------------------------------------------------------------------------------------------------------
# Menus

var menuActions: Table[int, proc ()]
var nextAction = 1

proc runAction(data: pointer): gboolean {.cdecl.} =
  let a = menuActions.getOrDefault(cast[int](data))
  menuActions.del cast[int](data)
  if a != nil: a()
  0

proc onMenuActivate(item: GtkWidget, data: pointer) {.cdecl.} =
  # After the menu has closed, so the action may open dialogs or other menus.
  discard g_idle_add(runAction, data)

proc buildMenu(items: seq[MenuItem]): GtkWidget =
  result = gtk_menu_new()
  for it in items:
    var mi: GtkWidget
    if it.separator: mi = gtk_separator_menu_item_new()
    else:
      mi = if it.checked >= 0: gtk_check_menu_item_new() else: gtk_menu_item_new()
      let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 24)
      let l = gtk_label_new(it.label.cstring)
      gtk_label_set_xalign(l, 0)
      gtk_box_pack_start(row, l, 1, 1, 0)
      if it.shortcut.len > 0:
        let k = gtk_label_new(it.shortcut.cstring)
        gtk_style_context_add_class(gtk_widget_get_style_context(k), "nk-dim")
        gtk_box_pack_end(row, k, 0, 0, 0)
      gtk_container_add(mi, row)
      if it.checked >= 0: gtk_check_menu_item_set_active(mi, (it.checked == 1).gboolean)
      if it.submenu.len > 0: gtk_menu_item_set_submenu(mi, buildMenu(it.submenu))
      elif it.action != nil:
        let id = nextAction
        inc nextAction
        menuActions[id] = it.action
        connect(mi, "activate", onMenuActivate, cast[pointer](id))
      gtk_widget_set_sensitive(mi, it.enabled.gboolean)
    gtk_menu_shell_append(result, mi)
  gtk_widget_show_all(result)

proc toplevel(): GtkWidget = window

backend.popup = proc (items: seq[MenuItem], anchor: Widget, x, y: float) =
  if items.len == 0: return
  let menu = buildMenu(items)
  let target = if anchor != nil and anchor.realized: anchor.native else: toplevel()
  if target != nil: gtk_menu_attach_to_widget(menu, gtk_widget_get_toplevel(target), nil)
  if anchor != nil and anchor.realized and x >= 0 and y >= 0:
    # x, y are in the anchor's pixels: a canvas's are device pixels, other widgets' logical ones.
    let s = if anchor.kind == wkCanvas: max(anchor.scale, 1).float else: 1.0
    let top = gtk_widget_get_toplevel(anchor.native)
    var tx, ty: cint
    discard gtk_widget_translate_coordinates(anchor.native, top, cint(x / s), cint(y / s), addr tx, addr ty)
    var r = GdkRectangle(x: tx, y: ty, width: 1, height: 1)
    gtk_menu_popup_at_rect(menu, gtk_widget_get_window(top), addr r, GDK_GRAVITY_NORTH_WEST, GDK_GRAVITY_NORTH_WEST,
                           nil)
  elif anchor != nil and anchor.realized:
    gtk_menu_popup_at_widget(menu, anchor.native, GDK_GRAVITY_SOUTH_WEST, GDK_GRAVITY_NORTH_WEST, nil)
  else:
    let ev = gtk_get_current_event()
    gtk_menu_popup_at_pointer(menu, ev)
    if ev != nil: gdk_event_free(ev)

# ---------------------------------------------------------------------------------------------------------------
# Dialogs

var dialogs: Table[int, Dialog]
var nextDialog = 1

proc onResponse(d: GtkWidget, response: cint, data: pointer) {.cdecl.} =
  let dlg = dialogs.getOrDefault(cast[int](data))
  if dlg != nil: dlg.dialogResult(if response >= 0: response.int else: -1)

backend.showDialog = proc (d: Dialog) =
  let id = nextDialog
  inc nextDialog
  dialogs[id] = d
  let g = gtk_dialog_new()
  d.native = cast[pointer](id)
  gtk_window_set_title(g, "")
  if toplevel() != nil: gtk_window_set_transient_for(g, toplevel())
  gtk_window_set_modal(g, 1)
  gtk_window_set_destroy_with_parent(g, 1)
  let area = gtk_dialog_get_content_area(g)
  gtk_container_set_border_width(area, 12)
  gtk_box_set_spacing(area, 8)
  # The title in the dialog too, as GTK's message dialogs show it (window managers may not draw a title bar).
  if d.title.len > 0:
    let t = gtk_label_new(d.title.cstring)
    gtk_label_set_xalign(t, 0)
    gtk_style_context_add_class(gtk_widget_get_style_context(t), "nk-dialog-title")
    gtk_box_pack_start(area, t, 0, 0, 0)
  if d.content != nil:
    d.content.realize()
    gtk_box_pack_start(area, d.content.native, 1, 1, 0)
  for i, b in d.buttons:
    let bw = gtk_dialog_add_button(g, b.cstring, i.cint)
    if i == d.destructive: gtk_style_context_add_class(gtk_widget_get_style_context(bw), "destructive-action")
    elif i == d.buttons.high and d.buttons.len > 1:
      gtk_style_context_add_class(gtk_widget_get_style_context(bw), "suggested-action")
  if d.buttons.len > 0: gtk_dialog_set_default_response(g, d.buttons.high.cint)
  connect(g, "response", onResponse, cast[pointer](id))
  inner[-id] = g
  gtk_widget_show_all(g)

backend.closeDialog = proc (d: Dialog) =
  let id = cast[int](d.native)
  let g = inner.getOrDefault(-id)
  inner.del -id
  dialogs.del id
  if g == nil: return
  if d.content != nil and d.content.realized:
    gtk_container_remove(gtk_dialog_get_content_area(g), d.content.native)
    d.content.unrealize()
  gtk_widget_destroy(g)

backend.chooseFile = proc (title: string, save: bool, name: string, patterns: seq[string], filterName: string,
                          onDone: proc (path: string)) =
  let d = gtk_file_chooser_dialog_new(title.cstring, toplevel(),
    if save: GTK_FILE_CHOOSER_ACTION_SAVE else: GTK_FILE_CHOOSER_ACTION_OPEN,
    "_Cancel", GTK_RESPONSE_CANCEL, (if save: "_Save" else: "_Open").cstring, GTK_RESPONSE_ACCEPT, nil)
  if patterns.len > 0:
    let f = gtk_file_filter_new()
    gtk_file_filter_set_name(f, (if filterName.len > 0: filterName else: patterns.join(", ")).cstring)
    for p in patterns: gtk_file_filter_add_pattern(f, p.cstring)
    gtk_file_chooser_add_filter(d, f)
  if save:
    if name.len > 0: gtk_file_chooser_set_current_name(d, name.cstring)
    gtk_file_chooser_set_do_overwrite_confirmation(d, 1)
  var path = ""
  if gtk_dialog_run(d) == GTK_RESPONSE_ACCEPT:
    let p = gtk_file_chooser_get_filename(d)
    if p != nil:
      path = $p
      g_free(cast[pointer](p))
  gtk_widget_destroy(d)
  onDone(path)

# ---------------------------------------------------------------------------------------------------------------
# Popovers: an undecorated popup window (it never takes the keyboard focus) under the anchor.

backend.showPopover = proc (p: Popover) =
  let top = gtk_widget_get_toplevel(p.anchor.native)
  if p.native == nil:
    p.native = gtk_window_new(1)   # GTK_WINDOW_POPUP
    gtk_window_set_transient_for(p.native, top)
    gtk_style_context_add_class(gtk_widget_get_style_context(p.native), "nk-popover")
    if not p.content.realized: p.content.realize()
    gtk_container_add(p.native, p.content.native)
  var ox, oy, ax, ay: cint
  discard gdk_window_get_origin(gtk_widget_get_window(top), addr ox, addr oy)
  discard gtk_widget_translate_coordinates(p.anchor.native, top, 0, 0, addr ax, addr ay)
  gtk_window_move(p.native, ox + ax, oy + ay + gtk_widget_get_allocated_height(p.anchor.native) + 4)
  gtk_window_resize(p.native, gtk_widget_get_allocated_width(p.anchor.native), 1)
  gtk_widget_show_all(p.native)

backend.hidePopover = proc (p: Popover) =
  if p.native != nil: gtk_widget_hide(p.native)

# ---------------------------------------------------------------------------------------------------------------
# The window

proc onWindowKeyPress(w: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} =
  if onWindowKey == nil: return 0
  onWindowKey(keyEvent(ev, true)).gboolean

proc onDelete(w: GtkWidget, ev: pointer, data: pointer): gboolean {.cdecl.} =
  if onCloseRequest != nil and not onCloseRequest(): 1 else: 0

proc useWindow*(w: GtkWidget) =
  ## For apps that make their own GtkWindow (webby): dialogs and menus belong to it, and onWindowKey and
  ## onCloseRequest work for it as for run()'s window.
  window = w
  connect(w, "key-press-event", onWindowKeyPress, nil)
  connect(w, "delete-event", onDelete, nil)

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
  useWindow(gtk_window_new(GTK_WINDOW_TOPLEVEL))
  gtk_window_set_title(window, title.cstring)
  gtk_window_set_default_size(window, width.cint, height.cint)
  connect(window, "destroy", onDestroy, nil)
  root.realize()
  gtk_container_add(window, root.native)
  gtk_widget_show_all(window)
  gtk_main()

gtkInit()
