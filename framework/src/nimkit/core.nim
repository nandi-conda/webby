## nimkit's widget tree: what an app builds and changes, independent of the platform. A widget is a plain Nim
## object; once the app runs, the backend (gtk.nim, web.nim, android.nim) gives each one a native counterpart
## (a GtkWidget, a DOM element, an Android View) and keeps it in step through the `backend` hooks below.
##
## Everything happens on one thread, the platform's UI thread: event callbacks, timers and HTTP replies all run there.

import std/tables

type
  WidgetKind* = enum
    wkColumn, wkRow, wkScroll, wkLabel, wkButton, wkEntry, wkCheck, wkCanvas, wkSlider, wkDropdown, wkProgress, wkToggle

  PointerKind* = enum
    pkDown, pkMove, pkUp, pkCancel, pkLeave   ## pkLeave: the mouse left the canvas

  PointerEvent* = object
    kind*: PointerKind
    x*, y*: float        ## in the canvas's pixels, from its top left corner
    pointer*: int        ## which finger (0 for the mouse)
    button*: int         ## pkDown/pkUp of a mouse button: 1 left, 2 middle, 3 right, 8 back, 9 forward
    buttons*: int        ## the mouse buttons held after the event: 1 left, 2 right, 4 middle (DOM `buttons`)
    mods*: int           ## modAlt, modCtrl, modShift, modSuper
    clicks*: int         ## pkDown: 1, 2 for a double click, 3 for a triple...

  WheelEvent* = object
    x*, y*: float        ## in the canvas's pixels
    dx*, dy*: float      ## precise: the platform's smooth deltas (about a logical pixel each); else wheel notches
    precise*: bool       ## a touchpad or smooth-scrolling device rather than a notched wheel
    mods*: int

  KeyEvent* = object
    down*: bool
    code*: int           ## the key, as a Windows virtual-key code (also Ladybird's KeyCode); 0 if it has none
    text*: uint32        ## the character it types (a Unicode code point), 0 for none or a control character
    mods*: int
    keyval*: uint32      ## the platform's own key number (a GDK keyval on GTK)

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
    minWidth*, minHeight*: int       ## the smallest size (logical pixels), 0 for the natural one; see `sized`
    valueValue: float                ## a slider's value, a progress bar's fraction (0..1)
    minValue, maxValue, stepValue: float  ## a slider's range and the step its keys and wheel move by
    marksValue: seq[(float, string)] ## a slider's labelled ticks
    itemsValue: seq[string]          ## a dropdown's choices
    selectedValue: int               ## the chosen one's index, -1 for none
    realized*: bool                  ## the backend has made the native widget
    native*: pointer                 ## the backend's own handle, if it has one (GTK)
    # Events
    onClick*: proc ()                ## buttons
    onChange*: proc (text: string)   ## entries, as the text changes
    onSubmit*: proc (text: string)   ## entries, on Enter
    onToggle*: proc (checked: bool)  ## check boxes and toggle buttons
    onValue*: proc (value: float)    ## sliders, as the user moves them
    onSelect*: proc (index: int)     ## dropdowns, when the user picks a choice
    onDraw*: proc (c: Canvas)        ## canvases, whenever their pixels must be (re)made
    onPointer*: proc (c: Canvas, e: PointerEvent)
    onWheel*: proc (c: Canvas, e: WheelEvent): bool        ## true: handled
    onKey*: proc (c: Canvas, e: KeyEvent): bool            ## while the canvas has the focus; true: handled
    onFocus*: proc (c: Canvas, focused: bool)
    onResize*: proc (c: Canvas)      ## its pixel size or scale changed
    onFrame*: proc (c: Canvas): tuple[data: pointer, width, height, stride: int]
      ## external canvases: asked for the buffer each time the canvas paints, for buffers that move (Ladybird's)
    # Canvas pixels
    width*, height*: int             ## in pixels; the backend sets them from the widget's on-screen size
    scale*: int                      ## pixels per logical pixel (the desktop's scale factor), at least 1
    pixels*: seq[uint32]             ## width*height premultiplied 0xAARRGGBB (cairo ARGB32, Ladybird's BGRA)
    external*: bool                  ## shows `frame` (someone else's buffer, see present) instead of `pixels`
    frame*: tuple[data: pointer, width, height, stride: int]

  Canvas* = Widget                   ## a widget of kind wkCanvas

  Backend* = object
    ## Set by the platform backend when it is imported. `update` is called after a property changes on a
    ## realized widget; `added`/`removed` after a child is added to or taken from a realized parent.
    update*: proc (w: Widget)
    added*: proc (parent, child: Widget, index: int)
    removed*: proc (parent, child: Widget)
    present*: proc (c: Canvas)       ## show the canvas's current pixels
    focus*: proc (w: Widget)         ## give `w` the keyboard focus
    setTitle*: proc (title: string)
    quit*: proc ()

const
  modAlt* = 1
  modCtrl* = 2
  modShift* = 4
  modSuper* = 8

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

proc value*(w: Widget): float = w.valueValue
proc `value=`*(w: Widget, v: float) =
  if v == w.valueValue: return
  w.valueValue = v
  w.changed

proc setValueSilently*(w: Widget, v: float) = w.valueValue = v

proc rangeMin*(w: Widget): float = w.minValue
proc rangeMax*(w: Widget): float = w.maxValue
proc step*(w: Widget): float = w.stepValue

proc setRange*(w: Widget, min, max: float, step = 0.0) =
  ## A slider's range; `step` 0 keeps the current step.
  let step = if step > 0: step else: w.stepValue
  if min == w.minValue and max == w.maxValue and step == w.stepValue: return
  w.minValue = min
  w.maxValue = max
  w.stepValue = step
  w.changed

proc marks*(w: Widget): seq[(float, string)] = w.marksValue
proc `marks=`*(w: Widget, m: seq[(float, string)]) =
  ## Labelled ticks under a slider (a value and its label, which may be ""). Not shown on Android.
  if m == w.marksValue: return
  w.marksValue = m
  w.changed

proc items*(w: Widget): seq[string] = w.itemsValue
proc `items=`*(w: Widget, items: seq[string]) =
  if items == w.itemsValue: return
  w.itemsValue = items
  if w.selectedValue >= items.len: w.selectedValue = -1
  w.changed

proc selected*(w: Widget): int = w.selectedValue
proc `selected=`*(w: Widget, i: int) =
  if i == w.selectedValue: return
  w.selectedValue = i
  w.changed

proc setSelectedSilently*(w: Widget, i: int) = w.selectedValue = i

proc enabled*(w: Widget): bool = w.enabledValue
proc `enabled=`*(w: Widget, on: bool) =
  w.enabledValue = on
  w.changed

proc expanded*(w: Widget): bool = w.expandValue
proc `expanded=`*(w: Widget, on: bool) =
  w.expandValue = on
  w.changed

proc sized*(w: Widget, minWidth = 0, minHeight = 0): Widget =
  ## Gives `w` at least this size (logical pixels; 0 keeps its natural size along that side), e.g. so labels in
  ## different rows line up. Returns it, for use inside column(...)/row(...).
  w.minWidth = minWidth
  w.minHeight = minHeight
  w.changed
  w

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

proc toggle*(text: string, checked = false, onToggle: proc (checked: bool) = nil): Widget =
  ## A button that stays pressed in while `checked`: for on/off settings, or a row of them as tabs.
  result = newWidget(wkToggle)
  result.textValue = text
  result.checkedValue = checked
  result.onToggle = onToggle

proc canvas*(minWidth = 100, minHeight = 100, onDraw: proc (c: Canvas) = nil,
             onPointer: proc (c: Canvas, e: PointerEvent) = nil): Canvas =
  result = newWidget(wkCanvas)
  result.scale = 1
  result.minWidth = minWidth
  result.minHeight = minHeight
  result.onDraw = onDraw
  result.onPointer = onPointer

proc slider*(min = 0.0, max = 1.0, value = 0.0, step = 0.01, onValue: proc (value: float) = nil): Widget =
  ## A horizontal slider from `min` to `max`. `onValue` runs as the user drags it, scrolls over it or uses its keys,
  ## not when the app sets `value`.
  result = newWidget(wkSlider)
  result.minValue = min
  result.maxValue = max
  result.stepValue = step
  result.valueValue = value
  result.onValue = onValue

proc dropdown*(items: seq[string] = @[], selected = -1, onSelect: proc (index: int) = nil): Widget =
  ## A pop-up list of choices showing the selected one. `onSelect` runs when the user picks one, not when the app
  ## sets `selected` or `items`.
  result = newWidget(wkDropdown)
  result.itemsValue = items
  result.selectedValue = selected
  result.onSelect = onSelect

proc progress*(fraction = 0.0): Widget =
  ## A horizontal bar filled to `fraction` (0..1), set through `value`: a level meter or a progress bar.
  result = newWidget(wkProgress)
  result.valueValue = fraction

# ---------------------------------------------------------------------------------------------------------------
# Canvas pixels

proc redraw*(c: Canvas) =
  ## Runs onDraw over the current pixels and shows the result.
  if c.width <= 0 or c.height <= 0: return
  if c.onDraw != nil: c.onDraw(c)
  if c.realized and backend.present != nil: backend.present(c)

proc externalCanvas*(minWidth = 1, minHeight = 1): Canvas =
  ## A canvas that shows a buffer it doesn't own, handed over with `present(c, data, ...)` (webby's page view:
  ## Ladybird's frames, shown without a copy). It keeps no `pixels`; onResize says when to make a new frame.
  result = canvas(minWidth, minHeight)
  result.external = true

proc present*(c: Canvas, data: pointer, width, height, stride: int) =
  ## Shows `width` x `height` premultiplied BGRA pixels at `data` on an external canvas, drawn at the canvas's
  ## scale. The buffer must stay valid until the next present (the backend may paint from it at any time).
  c.frame = (data, width, height, stride)
  if c.realized and backend.present != nil: backend.present(c)

proc invalidate*(c: Canvas) =
  ## Paints an external canvas again (asking onFrame for its buffer).
  if c.realized and backend.present != nil: backend.present(c)

proc focus*(w: Widget) =
  if w.realized and backend.focus != nil: backend.focus(w)

proc resized*(c: Canvas, width, height: int, scale = 1) =
  ## For backends: the canvas is now `width` x `height` pixels, `scale` per logical pixel. Keeps what fits of the
  ## old pixels.
  if width == c.width and height == c.height and scale == c.scale: return
  c.scale = max(scale, 1)
  if c.external:
    c.width = width
    c.height = height
    if c.onResize != nil: c.onResize(c)
    return
  var px = newSeq[uint32](max(width, 0) * max(height, 0))
  for y in 0 ..< min(height, c.height):
    for x in 0 ..< min(width, c.width):
      px[y * width + x] = c.pixels[y * c.width + x]
  c.pixels = move px
  c.width = width
  c.height = height
  if c.onResize != nil: c.onResize(c)
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
