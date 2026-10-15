## nimkit's widget tree: what an app builds and changes, independent of the platform. A widget is a plain Nim
## object; once the app runs, the backend (gtk.nim, web.nim, android.nim) gives each one a native counterpart
## (a GtkWidget, a DOM element, an Android View) and keeps it in step through the `backend` hooks below.
##
## Everything happens on one thread, the platform's UI thread: event callbacks, timers and HTTP replies all run there.

import std/tables

type
  WidgetKind* = enum
    wkColumn, wkRow, wkScroll, wkLabel, wkButton, wkEntry, wkCheck, wkCanvas

  PointerKind* = enum
    pkDown, pkMove, pkUp, pkCancel

  PointerEvent* = object
    kind*: PointerKind
    x*, y*: float        ## in the canvas's pixels, from its top left corner
    pointer*: int        ## which finger (0 for the mouse)

  Widget* = ref object
    kind*: WidgetKind
    id*: int                         ## unique, > 0; how backends without pointers (Android) name it
    parent*: Widget
    children*: seq[Widget]
    textValue: string                ## a label's or button's text, an entry's contents
    placeholderValue: string         ## an entry's hint
    checkedValue: bool
    expandValue: bool                ## takes the spare room along its parent's direction
    enabledValue: bool
    spacing*: int                    ## between a column's or row's children (logical pixels)
    padding*: int                    ## around them
    minWidth*, minHeight*: int       ## a canvas's smallest size (logical pixels)
    realized*: bool                  ## the backend has made the native widget
    native*: pointer                 ## the backend's own handle, if it has one (GTK)
    # Events
    onClick*: proc ()                ## buttons
    onChange*: proc (text: string)   ## entries, as the text changes
    onSubmit*: proc (text: string)   ## entries, on Enter
    onToggle*: proc (checked: bool)  ## check boxes
    onDraw*: proc (c: Canvas)        ## canvases, whenever their pixels must be (re)made
    onPointer*: proc (c: Canvas, e: PointerEvent)
    # Canvas pixels
    width*, height*: int             ## in pixels; the backend sets them from the widget's on-screen size
    pixels*: seq[uint32]             ## width*height premultiplied 0xAARRGGBB (cairo ARGB32, Ladybird's BGRA)

  Canvas* = Widget                   ## a widget of kind wkCanvas

  Backend* = object
    ## Set by the platform backend when it is imported. `update` is called after a property changes on a
    ## realized widget; `added`/`removed` after a child is added to or taken from a realized parent.
    update*: proc (w: Widget)
    added*: proc (parent, child: Widget, index: int)
    removed*: proc (parent, child: Widget)
    present*: proc (c: Canvas)       ## show the canvas's current pixels
    setTitle*: proc (title: string)
    quit*: proc ()

var
  backend*: Backend
  pixelRatio* = 1.0                  ## canvas pixels per logical pixel (the screen density on Android)
  widgets*: Table[int, Widget]       ## by id, so native callbacks can find their widget
  nextId = 1

proc newWidget*(kind: WidgetKind): Widget =
  result = Widget(kind: kind, id: nextId, enabledValue: true)
  inc nextId
  widgets[result.id] = result

proc changed(w: Widget) =
  if w.realized and backend.update != nil: backend.update(w)

# ---------------------------------------------------------------------------------------------------------------
# Properties

proc text*(w: Widget): string = w.textValue
proc `text=`*(w: Widget, s: string) =
  if s == w.textValue: return
  w.textValue = s
  w.changed

proc setTextSilently*(w: Widget, s: string) =
  ## For backends: the native widget already shows `s` (the user typed it).
  w.textValue = s

proc placeholder*(w: Widget): string = w.placeholderValue
proc `placeholder=`*(w: Widget, s: string) =
  w.placeholderValue = s
  w.changed

proc checked*(w: Widget): bool = w.checkedValue
proc `checked=`*(w: Widget, on: bool) =
  if on == w.checkedValue: return
  w.checkedValue = on
  w.changed

proc setCheckedSilently*(w: Widget, on: bool) = w.checkedValue = on

proc enabled*(w: Widget): bool = w.enabledValue
proc `enabled=`*(w: Widget, on: bool) =
  w.enabledValue = on
  w.changed

proc expanded*(w: Widget): bool = w.expandValue
proc `expanded=`*(w: Widget, on: bool) =
  w.expandValue = on
  w.changed

proc expand*(w: Widget): Widget =
  ## Marks `w` to take its parent's spare room; returns it, for use inside column(...)/row(...).
  w.expandValue = true
  w

# ---------------------------------------------------------------------------------------------------------------
# The tree

proc add*(parent, child: Widget) =
  assert parent.kind in {wkColumn, wkRow, wkScroll}
  assert child.parent == nil
  child.parent = parent
  parent.children.add child
  if parent.realized and backend.added != nil: backend.added(parent, child, parent.children.high)

proc forget(w: Widget) =
  widgets.del w.id
  for c in w.children: forget(c)

proc remove*(parent, child: Widget) =
  let i = parent.children.find(child)
  if i < 0: return
  parent.children.delete i
  child.parent = nil
  if parent.realized and backend.removed != nil: backend.removed(parent, child)
  forget(child)

proc clear*(parent: Widget) =
  while parent.children.len > 0: parent.remove(parent.children[^1])

# ---------------------------------------------------------------------------------------------------------------
# Constructors

proc column*(children: varargs[Widget]): Widget =
  result = newWidget(wkColumn)
  result.spacing = 8
  for c in children: result.add c

proc row*(children: varargs[Widget]): Widget =
  result = newWidget(wkRow)
  result.spacing = 8
  for c in children: result.add c

proc scroll*(child: Widget): Widget =
  ## A vertically scrolling view of `child`.
  result = newWidget(wkScroll)
  result.add child

proc label*(text: string): Widget =
  result = newWidget(wkLabel)
  result.textValue = text

proc button*(text: string, onClick: proc () = nil): Widget =
  result = newWidget(wkButton)
  result.textValue = text
  result.onClick = onClick

proc entry*(placeholder = "", text = "", onChange: proc (text: string) = nil,
            onSubmit: proc (text: string) = nil): Widget =
  result = newWidget(wkEntry)
  result.placeholderValue = placeholder
  result.textValue = text
  result.onChange = onChange
  result.onSubmit = onSubmit

proc check*(text: string, checked = false, onToggle: proc (checked: bool) = nil): Widget =
  result = newWidget(wkCheck)
  result.textValue = text
  result.checkedValue = checked
  result.onToggle = onToggle

proc canvas*(minWidth = 100, minHeight = 100, onDraw: proc (c: Canvas) = nil,
             onPointer: proc (c: Canvas, e: PointerEvent) = nil): Canvas =
  result = newWidget(wkCanvas)
  result.minWidth = minWidth
  result.minHeight = minHeight
  result.onDraw = onDraw
  result.onPointer = onPointer

# ---------------------------------------------------------------------------------------------------------------
# Canvas pixels

proc redraw*(c: Canvas) =
  ## Runs onDraw over the current pixels and shows the result.
  if c.width <= 0 or c.height <= 0: return
  if c.onDraw != nil: c.onDraw(c)
  if c.realized and backend.present != nil: backend.present(c)

proc resized*(c: Canvas, width, height: int) =
  ## For backends: the canvas is now `width` x `height` pixels. Keeps what fits of the old pixels.
  if width == c.width and height == c.height: return
  var px = newSeq[uint32](max(width, 0) * max(height, 0))
  for y in 0 ..< min(height, c.height):
    for x in 0 ..< min(width, c.width):
      px[y * width + x] = c.pixels[y * c.width + x]
  c.pixels = move px
  c.width = width
  c.height = height
  c.redraw()

proc rgb*(r, g, b: int, a = 255): uint32 =
  ## A premultiplied pixel from straight (not premultiplied) 0..255 components.
  let a = a.clamp(0, 255)
  let p = proc (v: int): uint32 = uint32(v.clamp(0, 255) * a div 255)
  (uint32(a) shl 24) or (p(r) shl 16) or (p(g) shl 8) or p(b)

proc fill*(c: Canvas, color: uint32) =
  for p in c.pixels.mitems: p = color

proc fillRect*(c: Canvas, x, y, w, h: int, color: uint32) =
  for yy in max(y, 0) ..< min(y + h, c.height):
    for xx in max(x, 0) ..< min(x + w, c.width):
      c.pixels[yy * c.width + xx] = color

proc fillCircle*(c: Canvas, cx, cy, r: float, color: uint32) =
  for yy in max(int(cy - r), 0) .. min(int(cy + r), c.height - 1):
    for xx in max(int(cx - r), 0) .. min(int(cx + r), c.width - 1):
      let dx = float(xx) + 0.5 - cx
      let dy = float(yy) + 0.5 - cy
      if dx * dx + dy * dy <= r * r: c.pixels[yy * c.width + xx] = color

proc line*(c: Canvas, x0, y0, x1, y1, width: float, color: uint32) =
  ## A round-capped line `width` wide.
  let steps = max(1, int(max(abs(x1 - x0), abs(y1 - y0)) / max(width / 4, 0.5)))
  for i in 0 .. steps:
    let t = i / steps
    c.fillCircle(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, width / 2, color)

# ---------------------------------------------------------------------------------------------------------------

proc setTitle*(title: string) =
  if backend.setTitle != nil: backend.setTitle(title)

proc quitApp*() =
  if backend.quit != nil: backend.quit()
