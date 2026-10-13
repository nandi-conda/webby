## The Flutter app's icons (Material Icons, the glyphs behind Flutter's Icons.*) for the GTK UI, so both front ends
## look the same and nothing depends on the desktop's icon theme. The glyph outlines are compiled in (icondata.nim,
## made by scripts/material_icons.py) and drawn with cairo in the widget's text colour, like a symbolic icon:
## they follow light and dark themes and hover/disabled states, and stay sharp at any scale factor.
##
##   icon("arrow_back")              a GtkImage showing Icons.arrow_back at 16 px
##   setIcon(image, "close")         switch an icon made by icon() (or any GtkImage) to another glyph
##
## The image stays a plain GtkImage: setting a pixbuf on it (a site's favicon) shows that instead, and setIcon
## brings the glyph back. The window icon is the repo's icons/webby*.svg, also compiled in (setAppIcon).

import std/[strutils, tables]
import gtk, icondata

type
  Op = enum opMove, opLine, opCurve, opClose
  Glyph = ref object
    ops: seq[(Op, array[6, float])]
  Rgba {.bycopy.} = object
    r, g, b, a: cdouble

const GTK_IMAGE_EMPTY = 0.cint

{.push cdecl, importc.}
proc gtk_image_new(): Widget
proc gtk_image_clear(image: Widget)
proc gtk_image_get_storage_type(image: Widget): cint
proc gtk_style_context_get_state(c: pointer): cint
proc gtk_style_context_get_color(c: pointer, state: cint, color: ptr Rgba)
proc cairo_save(cr: Cairo)
proc cairo_restore(cr: Cairo)
proc cairo_translate(cr: Cairo, x, y: cdouble)
proc cairo_set_source_rgba(cr: Cairo, r, g, b, a: cdouble)
proc cairo_new_path(cr: Cairo)
proc cairo_move_to(cr: Cairo, x, y: cdouble)
proc cairo_line_to(cr: Cairo, x, y: cdouble)
proc cairo_curve_to(cr: Cairo, x1, y1, x2, y2, x3, y3: cdouble)
proc cairo_close_path(cr: Cairo)
proc gdk_pixbuf_loader_new(): pointer
proc gdk_pixbuf_loader_set_size(l: pointer, w, h: cint)
proc gdk_pixbuf_loader_write(l: pointer, data: pointer, len: csize_t, err: pointer): gboolean
proc gdk_pixbuf_loader_close(l: pointer, err: pointer): gboolean
proc gdk_pixbuf_loader_get_pixbuf(l: pointer): pointer
proc g_list_append(l, data: pointer): pointer
proc gtk_window_set_icon_list(w: Widget, list: pointer)
proc gtk_window_set_default_icon_list(list: pointer)
{.pop.}

proc parse(d: string): Glyph =
  ## An SVG path of absolute M, L, H, V, C and Z commands (what fontTools' SVGPathPen writes).
  result = Glyph()
  var nums: seq[float]
  var cmd = ' '
  var x, y: float
  proc flush(g: Glyph, cmd: char, nums: var seq[float], x, y: var float) =
    var i = 0
    case cmd
    of 'M', 'L':
      while i + 1 < nums.len:
        x = nums[i]; y = nums[i + 1]
        g.ops.add ((if cmd == 'M' and i == 0: opMove else: opLine), [x, y, 0, 0, 0, 0])
        i += 2
    of 'H':
      for n in nums: x = n; g.ops.add (opLine, [x, y, 0, 0, 0, 0])
    of 'V':
      for n in nums: y = n; g.ops.add (opLine, [x, y, 0, 0, 0, 0])
    of 'C':
      while i + 5 < nums.len:
        g.ops.add (opCurve, [nums[i], nums[i+1], nums[i+2], nums[i+3], nums[i+4], nums[i+5]])
        x = nums[i+4]; y = nums[i+5]
        i += 6
    of 'Z': g.ops.add (opClose, [0.0, 0, 0, 0, 0, 0])
    else: discard
    nums.setLen 0
  var token = ""
  for c in d & " ":
    if c in {'0'..'9', '.', '-'} and not (c == '-' and token.len > 0):
      token.add c
      continue
    if token.len > 0:
      nums.add parseFloat(token)
      token = ""
    if c == '-': token.add c
    elif c.isAlphaAscii:
      result.flush(cmd, nums, x, y)
      cmd = c
  result.flush(cmd, nums, x, y)

var glyphs: Table[string, Glyph]

proc glyph(name: string): Glyph =
  result = glyphs.getOrDefault(name)
  if result == nil and name in iconPaths:
    result = parse(iconPaths[name])
    GC_ref(result)   # widgets point at it
    glyphs[name] = result

proc onDraw(w: Widget, cr: Cairo, d: pointer): gboolean {.cdecl.} =
  let g = cast[Glyph](g_object_get_data(w, "webby-glyph"))
  if g == nil or gtk_image_get_storage_type(w) != GTK_IMAGE_EMPTY: return 0   # a favicon or nothing: GTK draws it
  let size = cast[int](g_object_get_data(w, "webby-glyph-size")).float
  let ctx = gtk_widget_get_style_context(w)
  var c: Rgba
  gtk_style_context_get_color(ctx, gtk_style_context_get_state(ctx), addr c)
  cairo_save(cr)
  cairo_translate(cr, ((gtk_widget_get_allocated_width(w).float - size) / 2).int.float,
    ((gtk_widget_get_allocated_height(w).float - size) / 2).int.float)
  cairo_scale(cr, size / iconEm, size / iconEm)
  cairo_new_path(cr)
  for (op, p) in g.ops:
    case op
    of opMove: cairo_move_to(cr, p[0], p[1])
    of opLine: cairo_line_to(cr, p[0], p[1])
    of opCurve: cairo_curve_to(cr, p[0], p[1], p[2], p[3], p[4], p[5])
    of opClose: cairo_close_path(cr)
  cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
  cairo_fill(cr)
  cairo_restore(cr)
  1

proc setIcon*(image: Widget, name: string, size = 0) =
  ## Shows the Flutter icon `name` (an Icons.* name such as "arrow_back") in a GtkImage; size 0 keeps the size it
  ## had (16 px for a new one).
  let g = glyph(name)
  if g == nil: stderr.writeLine "webby: no icon named ", name, " (add it to scripts/material_icons.py)"
  if g_object_get_data(image, "webby-glyph-hooked") == nil:
    g_object_set_data(image, "webby-glyph-hooked", cast[pointer](1))
    connect(image, "draw", onDraw)
  var px = size
  if px == 0: px = cast[int](g_object_get_data(image, "webby-glyph-size"))
  if px == 0: px = 16
  g_object_set_data(image, "webby-glyph-size", cast[pointer](px))
  g_object_set_data(image, "webby-glyph", cast[pointer](g))
  gtk_image_clear(image)
  gtk_widget_set_size_request(image, px.cint, px.cint)
  gtk_widget_queue_draw(image)

proc icon*(name: string, size = 16): Widget =
  ## A GtkImage showing the Flutter icon `name` at `size` px, in the text colour of wherever it is packed.
  result = gtk_image_new()
  setIcon(result, name, size)

proc iconButtonImage*(button: Widget, name: string, size = 16) =
  ## Puts the icon on a button (a GtkButton or GtkMenuButton), as the button's only content.
  gtk_button_set_image(button, icon(name, size))
  gtk_button_set_always_show_image(button, 1)

# --- the window icon --------------------------------------------------------------------------------------------

const appIconSvg = staticRead("../../icons/webby.svg")
const appIconSmallSvg = staticRead("../../icons/webby-small.svg")   # drawn for 32 px and below

var appIcons: pointer   # GList of GdkPixbufs, made once

proc setAppIcon*(window: Widget) =
  ## Gives the window (and, as the default, every later window and dialog) webby's icon. Needs gdk-pixbuf's SVG
  ## loader (librsvg); without it the window keeps the desktop's default.
  if appIcons == nil:
    for s in [16, 24, 32, 48, 64, 128, 256]:
      let svg = if s <= 32: appIconSmallSvg else: appIconSvg
      let loader = gdk_pixbuf_loader_new()
      gdk_pixbuf_loader_set_size(loader, s.cint, s.cint)
      if gdk_pixbuf_loader_write(loader, svg.cstring, svg.len.csize_t, nil) != 0 and
         gdk_pixbuf_loader_close(loader, nil) != 0:
        let p = gdk_pixbuf_loader_get_pixbuf(loader)
        if p != nil: appIcons = g_list_append(appIcons, g_object_ref(p))
      else:
        discard gdk_pixbuf_loader_close(loader, nil)
      g_object_unref(loader)
    if appIcons == nil: return
    gtk_window_set_default_icon_list(appIcons)
  if appIcons != nil: gtk_window_set_icon_list(window, appIcons)
