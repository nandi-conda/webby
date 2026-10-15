## nimkit's widget tree: what an app builds and changes, independent of the platform. A widget is a plain Nim
## object; once the app runs, the backend (gtk.nim, web.nim, android.nim) gives each one a native counterpart
## (a GtkWidget, a DOM element, an Android View) and keeps it in step through the `backend` hooks below.
##
## Everything happens on one thread, the platform's UI thread: event callbacks, timers and HTTP replies all run there.

import std/tables
from std/strutils import nil

type
  WidgetKind* = enum
    wkColumn, wkRow, wkScroll, wkLabel, wkButton, wkEntry, wkCheck, wkCanvas, wkSlider, wkDropdown, wkProgress, wkToggle,
    wkIcon, wkItem, wkSeparator

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
    visibleValue: bool               ## shown (the default) or hidden, taking no room
    tooltipValue: string
    classesValue: seq[string]        ## style names, see addClass
    iconValue: string                ## an icon's glyph, or a button's/toggle's/item's icon (see registerIcons)
    iconSizeValue: int               ## logical pixels
    passwordValue: bool              ## an entry that hides what is typed
    horizontalValue: bool            ## a scroll view that scrolls sideways instead of up and down
    maxCharsValue: int               ## a label kept to one line, cut short with "…" past this many characters
    imageValue: string               ## an icon showing a picture (PNG, JPEG, GIF, ICO, WebP or SVG bytes) instead
    dragValue: string                ## items: what dragging it carries (see `dragData=`); empty: not draggable
    dropHandler: proc (data: string, x, y: float)  ## see `onDrop=`
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
    onContext*: proc ()              ## items: right-click, or a long press on touch screens
    onMiddle*: proc ()               ## items: middle-click
    onDoubleClick*: proc ()          ## items: a double click with the mouse (onClick comes first)
    onEntryKey*: proc (e: KeyEvent): bool   ## entries: a key pressed while it has the focus; true: handled
    onFocusChange*: proc (focused: bool)    ## entries
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
    moved*: proc (parent, child: Widget, index: int)   ## a child now at `index` (insert of one already there)
    present*: proc (c: Canvas)       ## show the canvas's current pixels
    focus*: proc (w: Widget)         ## give `w` the keyboard focus
    setTitle*: proc (title: string)
    quit*: proc ()
    popup*: proc (items: seq[MenuItem], anchor: Widget, x, y: float)
    showDialog*: proc (d: Dialog)
    closeDialog*: proc (d: Dialog)
    selectAll*: proc (w: Widget)     ## an entry's text
    showPopover*: proc (p: Popover)  ## show (again) under its anchor, at the anchor's width
    hidePopover*: proc (p: Popover)
    chooseFile*: proc (title: string, save: bool, name: string, patterns: seq[string], filterName: string,
                       onDone: proc (path: string))

  MenuItem* = object
    ## One line of a pop-up menu (`popupMenu`): a command, a check item, a separator or a submenu.
    label*: string
    action*: proc ()
    enabled*: bool
    checked*: int                    ## -1: not a check item; 0 or 1: unchecked or checked
    shortcut*: string                ## shown at the end, e.g. "Ctrl+T" (the app handles the key itself)
    separator*: bool
    submenu*: seq[MenuItem]

  Popover* = ref object
    ## A panel floating under a widget, e.g. suggestions under a text field. It takes no keyboard focus, so
    ## typing goes on in the field; the app shows and hides it (`showPopover`, `hidePopover`).
    anchor*, content*: Widget
    native*: pointer                 ## the backend's handle once it has been shown
    shown*: bool

  Dialog* = ref object
    ## A modal dialog over the window (`showDialog`): a title, the app's content and a row of buttons.
    title*: string
    content*: Widget
    buttons*: seq[string]            ## left to right; the last is the default (Enter)
    destructive*: int                ## index of a button that deletes or discards something, -1 for none
    onResult*: proc (index: int)     ## the button's index, or -1 if the dialog was dismissed
    native*: pointer                 ## the backend's handle while it shows
    shown*: bool

const
  modAlt* = 1
  modCtrl* = 2
  modShift* = 4
  modSuper* = 8

var
  onWindowKey*: proc (e: KeyEvent): bool   ## every key pressed in the window, before the focused widget; true: handled
  onCloseRequest*: proc (): bool           ## the window's close button (desktop); false keeps it open
  backend*: Backend
  pixelRatio* = 1.0                  ## canvas pixels per logical pixel (the screen density on Android)
  widgets*: Table[int, Widget]       ## by id, so native callbacks can find their widget
  nextId = 1

proc newWidget*(kind: WidgetKind): Widget =
  result = Widget(kind: kind, id: nextId, enabledValue: true, visibleValue: true, iconSizeValue: 16)
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

proc visible*(w: Widget): bool = w.visibleValue
proc `visible=`*(w: Widget, on: bool) =
  if on == w.visibleValue: return
  w.visibleValue = on
  w.changed

proc tooltip*(w: Widget): string = w.tooltipValue
proc `tooltip=`*(w: Widget, s: string) =
  if s == w.tooltipValue: return
  w.tooltipValue = s
  w.changed

proc classes*(w: Widget): seq[string] = w.classesValue
proc hasClass*(w: Widget, name: string): bool = name in w.classesValue

proc addClass*(w: Widget, name: string): Widget {.discardable.} =
  ## Style names the backends know: "heading" (larger, bold), "bold", "dim" (secondary text), "small", "mono",
  ## "error", "flat" (a button without a frame), "suggested" and "destructive" (a button's emphasis), "selected"
  ## (an item shown as the current one), "card" (a framed box). Others are passed on where the platform can use
  ## them (GTK style classes, web CSS classes). Returns `w`.
  if name notin w.classesValue:
    w.classesValue.add name
    w.changed
  w

proc removeClass*(w: Widget, name: string) =
  let i = w.classesValue.find(name)
  if i >= 0:
    w.classesValue.delete i
    w.changed

proc setClass*(w: Widget, name: string, on: bool) =
  if on: discard w.addClass(name) else: w.removeClass(name)

proc iconName*(w: Widget): string = w.iconValue
proc `iconName=`*(w: Widget, name: string) =
  if name == w.iconValue: return
  w.iconValue = name
  w.changed

proc iconSize*(w: Widget): int = w.iconSizeValue
proc `iconSize=`*(w: Widget, px: int) =
  if px == w.iconSizeValue: return
  w.iconSizeValue = px
  w.changed

proc password*(w: Widget): bool = w.passwordValue
proc `password=`*(w: Widget, on: bool) =
  if on == w.passwordValue: return
  w.passwordValue = on
  w.changed

proc horizontal*(w: Widget): bool = w.horizontalValue

proc maxChars*(w: Widget): int = w.maxCharsValue
proc `maxChars=`*(w: Widget, n: int) =
  ## Labels: 0 (the default) wraps long text over several lines; n > 0 keeps it to one line at most n characters
  ## wide, ending in "…" when cut.
  if n == w.maxCharsValue: return
  w.maxCharsValue = n
  w.changed

proc image*(w: Widget): string = w.imageValue
proc `image=`*(w: Widget, bytes: string) =
  ## Icons: a picture (a site's favicon: PNG, JPEG, GIF, ICO, WebP or SVG file bytes) drawn at the icon's size
  ## instead of its glyph; "" brings the glyph back.
  if bytes == w.imageValue: return
  w.imageValue = bytes
  w.changed

proc imageMime*(bytes: string): string =
  ## The type of a picture from its first bytes ("" if it isn't one of the kinds `image=` takes).
  proc starts(p: string): bool = bytes.len >= p.len and bytes[0 ..< p.len] == p
  if starts("\x89PNG"): "image/png"
  elif starts("\xFF\xD8\xFF"): "image/jpeg"
  elif starts("GIF8"): "image/gif"
  elif starts("\0\0\1\0"): "image/x-icon"
  elif starts("RIFF") and bytes.len >= 12 and bytes[8 ..< 12] == "WEBP": "image/webp"
  elif strutils.find(bytes[0 ..< min(bytes.len, 1024)], "<svg") >= 0: "image/svg+xml"
  else: ""

proc dragData*(w: Widget): string = w.dragValue
proc `dragData=`*(w: Widget, data: string) =
  ## Makes an item draggable (within the app), carrying `data` to where it is dropped; "" stops it.
  if w.dragValue != data:
    w.dragValue = data
    w.changed

proc dropHandler*(w: Widget): proc (data: string, x, y: float) = w.dropHandler
proc `onDrop=`*(w: Widget, handler: proc (data: string, x, y: float)) =
  ## Lets a row, column or item take drops of dragged items: `handler` gets their dragData and where it was
  ## dropped as fractions (0..1) of `w`'s width and height. The innermost widget that takes drops gets it.
  w.dropHandler = handler
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
  assert parent.kind in {wkColumn, wkRow, wkScroll, wkItem}
  assert child.parent == nil
  child.parent = parent
  parent.children.add child
  if parent.realized and backend.added != nil: backend.added(parent, child, parent.children.high)

proc forget(w: Widget) =
  widgets.del w.id
  for c in w.children: forget(c)

proc remove*(parent, child: Widget, keep = false) =
  ## Takes `child` out of `parent`. Unless `keep` (it is going to be added somewhere else, e.g. tabs moving to
  ## another strip) it is done with: its events stop.
  let i = parent.children.find(child)
  if i < 0: return
  parent.children.delete i
  child.parent = nil
  if parent.realized and backend.removed != nil: backend.removed(parent, child)
  if not keep: forget(child)

proc clear*(parent: Widget) =
  while parent.children.len > 0: parent.remove(parent.children[^1])

proc insert*(parent, child: Widget, index: int) =
  ## Adds `child` at `index` among `parent`'s children (moving it there if it's already one of them).
  if child.parent == parent:
    let i = parent.children.find(child)
    let j = index.clamp(0, parent.children.high)
    if i == j: return
    parent.children.delete i
    parent.children.insert(child, j)
    if parent.realized and backend.moved != nil: backend.moved(parent, child, j)
    return
  assert child.parent == nil
  child.parent = parent
  let j = index.clamp(0, parent.children.len)
  parent.children.insert(child, j)
  if parent.realized and backend.added != nil: backend.added(parent, child, j)

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

proc scroll*(child: Widget, horizontal = false): Widget =
  ## A scrolling view of `child`: up and down, or sideways (a row too wide for the window, a tab strip).
  result = newWidget(wkScroll)
  result.horizontalValue = horizontal
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

proc icon*(name: string, size = 16): Widget =
  ## A glyph from the app's icons (`registerIcons`), `size` logical pixels square, in the text colour.
  result = newWidget(wkIcon)
  result.iconValue = name
  result.iconSizeValue = size

proc iconButton*(name: string, tooltip = "", onClick: proc () = nil, size = 18): Widget =
  ## A frameless button showing only an icon.
  result = button("", onClick)
  result.iconValue = name
  result.iconSizeValue = size
  result.tooltipValue = tooltip
  result.classesValue.add "flat"

proc item*(children: varargs[Widget], onClick: proc () = nil): Widget =
  ## A clickable row (a list entry, a tab): its children side by side, the whole row one button. `onContext` and
  ## `onMiddle` take right/long-press and middle clicks.
  result = newWidget(wkItem)
  result.spacing = 8
  result.onClick = onClick
  for c in children: result.add c

proc separator*(): Widget =
  ## A thin line across a column (or down a row).
  newWidget(wkSeparator)

proc spacer*(): Widget =
  ## Empty room that takes a row's or column's spare space, pushing what follows to the end.
  result = newWidget(wkColumn)
  result.spacing = 0
  result.expandValue = true

# ---------------------------------------------------------------------------------------------------------------
# Icons

var
  iconPaths*: Table[string, string]  ## name -> SVG path of absolute M, L, H, V, C and Z commands
  iconEm* = 512                      ## the paths' square: 0..iconEm, y pointing down

proc registerIcons*(paths: openArray[(string, string)], em: int) =
  ## The glyphs `icon(name)` and widgets' `iconName` draw (e.g. Material Icons outlines). All share one em square.
  iconEm = em
  for (name, path) in paths: iconPaths[name] = path

proc registerIcons*(paths: Table[string, string], em: int) =
  iconEm = em
  for name, path in paths: iconPaths[name] = path

# ---------------------------------------------------------------------------------------------------------------
# Menus and dialogs

proc menuItem*(label: string, action: proc (), enabled = true, shortcut = ""): MenuItem =
  MenuItem(label: label, action: action, enabled: enabled, checked: -1, shortcut: shortcut)

proc checkItem*(label: string, checked: bool, action: proc (), enabled = true): MenuItem =
  MenuItem(label: label, action: action, enabled: enabled, checked: ord(checked))

proc submenu*(label: string, items: seq[MenuItem]): MenuItem =
  MenuItem(label: label, enabled: true, checked: -1, submenu: items)

proc menuSeparator*(): MenuItem = MenuItem(separator: true, checked: -1)

proc popupMenu*(items: seq[MenuItem], anchor: Widget = nil, x = -1.0, y = -1.0) =
  ## Shows a pop-up menu: under `anchor` if given (at `x`, `y` in its pixels if those are >= 0, e.g. a canvas's
  ## right-click), else at the pointer. The chosen item's action runs after the menu closes.
  if backend.popup != nil: backend.popup(items, anchor, x, y)

proc showDialog*(d: Dialog) =
  if backend.showDialog != nil and not d.shown:
    d.shown = true
    backend.showDialog(d)

proc closeDialog*(d: Dialog) =
  ## Closes it without calling onResult.
  if d.shown:
    d.shown = false
    if backend.closeDialog != nil: backend.closeDialog(d)

proc dialogResult*(d: Dialog, index: int) =
  ## For backends: the user pressed button `index` (-1: dismissed).
  if not d.shown: return
  d.shown = false
  if backend.closeDialog != nil: backend.closeDialog(d)
  if d.onResult != nil: d.onResult(index)

proc dialog*(title: string, content: Widget, buttons: seq[string], onResult: proc (index: int) = nil,
             destructive = -1): Dialog =
  ## Shows a modal dialog and returns it. onResult gets the pressed button's index, or -1 if dismissed.
  result = Dialog(title: title, content: content, buttons: buttons, onResult: onResult, destructive: destructive)
  showDialog(result)

proc alert*(title: string, text = "", onDone: proc () = nil) =
  discard dialog(title, column(label(text)), @["OK"], proc (i: int) = (if onDone != nil: onDone()))

proc confirm*(title: string, text = "", ok = "OK", onResult: proc (ok: bool), destructive = false) =
  ## Cancel / `ok`; onResult(true) only for `ok`.
  discard dialog(title, column(label(text)), @["Cancel", ok], proc (i: int) = onResult(i == 1),
    if destructive: 1 else: -1)

proc focus*(w: Widget)
proc selectAll*(w: Widget)

proc prompt*(title: string, text = "", initial = "", onResult: proc (ok: bool, value: string),
             password = false, ok = "OK") =
  ## Asks for a line of text. Enter in the field answers `ok`.
  let field = entry(text = initial)
  field.password = password
  var d: Dialog
  field.onSubmit = proc (s: string) = d.dialogResult(1)
  let content = if text.len > 0: column(label(text), field) else: column(field)
  d = dialog(title, content, @["Cancel", ok], proc (i: int) = onResult(i == 1, field.text))
  field.focus()
  field.selectAll()

proc chooseFile*(title: string, onDone: proc (path: string), save = false, name = "",
                 patterns: seq[string] = @[], filterName = "") =
  ## Asks for a file to open (or, with `save`, a place to save one, suggesting `name`). `patterns` such as "*.html"
  ## limit the choice, under `filterName`. onDone gets the path, or "" if cancelled. Backends without files skip it.
  if backend.chooseFile != nil: backend.chooseFile(title, save, name, patterns, filterName, onDone)
  else: onDone("")

proc popover*(anchor, content: Widget): Popover =
  ## A popover for `content` under `anchor`, not shown yet. `content` stays live: change it while it shows.
  Popover(anchor: anchor, content: content)

proc showPopover*(p: Popover) =
  ## Shows `p` (or moves it back under its anchor if it already shows).
  if backend.showPopover != nil and p.anchor.realized:
    p.shown = true
    backend.showPopover(p)

proc hidePopover*(p: Popover) =
  if p.shown:
    p.shown = false
    if backend.hidePopover != nil: backend.hidePopover(p)

proc selectAll*(w: Widget) =
  if w.realized and backend.selectAll != nil: backend.selectAll(w)

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
