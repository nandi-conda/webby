## The Android backend: the app is a shared library under a generic Java Activity (framework/android/java,
## dev.nimkit.Host). Widgets become Android Views made by Host on request (nk_op), their events come back through
## nk_event, canvases are SurfaceViews filled from the pixel buffer (nk_blit), timers are Handler.postDelayed,
## storage is files in the app's files dir, HTTP is HttpURLConnection on a worker thread. All on the main thread.
## The JNI side is framework/android/glue.c; framework/android/build.sh makes the APK.

import std/[base64, json, os, strutils, tables]
import ../[core, services]

{.compile: "../../../android/glue.c".}
{.passL: "-landroid -llog".}

proc nk_op(op, id, arg: cint, text: cstring) {.importc, cdecl.}
proc nk_http(id: cint, json: cstring) {.importc, cdecl.}
proc nk_blit(id: cint, pixels: pointer, w, h: cint) {.importc, cdecl.}
proc nk_data_dir(): cstring {.importc, cdecl.}
proc nk_log(text: cstring) {.importc, cdecl.}
proc nk_density(): cfloat {.importc, cdecl.}

const   # Host.java's ops
  opCreate = 0
  opText = 1
  opPlaceholder = 2
  opChecked = 3
  opEnabled = 4
  opExpand = 5
  opSpacing = 6
  opPadding = 7
  opMinSize = 8
  opAdd = 9
  opRemove = 10
  opRoot = 11
  opTitle = 12
  opTimer = 13
  opUntimer = 14
  opQuit = 15
  opForget = 16

proc op(o: int, id = 0, arg = 0, text = "") = nk_op(o.cint, id.cint, arg.cint, text.cstring)

var
  root: Widget
  title: string
  attached: Table[int, bool]       # canvas id -> its surface is there

# ---------------------------------------------------------------------------------------------------------------
# Widgets

proc sync(w: Widget) =
  case w.kind
  of wkColumn, wkRow:
    op(opSpacing, w.id, w.spacing)
    op(opPadding, w.id, w.padding)
  of wkLabel, wkButton, wkCheck:
    op(opText, w.id, text = w.text)
    if w.kind == wkCheck: op(opChecked, w.id, ord(w.checked))
  of wkEntry:
    op(opText, w.id, text = w.text)
    op(opPlaceholder, w.id, text = w.placeholder)
  of wkCanvas: op(opMinSize, w.id, w.minWidth, $w.minHeight)
  of wkScroll: discard
  op(opEnabled, w.id, ord(w.enabled))
  op(opExpand, w.id, ord(w.expanded))

proc realize(w: Widget) =
  op(opCreate, w.id, ord(w.kind))
  w.realized = true
  w.sync()
  for i, c in w.children:
    c.realize()
    op(opAdd, w.id, c.id, $i)

proc unrealize(w: Widget) =
  for c in w.children: c.unrealize()
  op(opForget, w.id)
  w.realized = false

backend.update = proc (w: Widget) = w.sync()
backend.added = proc (parent, child: Widget, index: int) =
  child.realize()
  op(opAdd, parent.id, child.id, $index)
backend.removed = proc (parent, child: Widget) =
  op(opRemove, parent.id, child.id)
  child.unrealize()
backend.present = proc (c: Canvas) =
  if attached.getOrDefault(c.id) and c.pixels.len > 0:
    nk_blit(c.id.cint, addr c.pixels[0], c.width.cint, c.height.cint)
backend.setTitle = proc (t: string) =
  title = t
  op(opTitle, text = t)
backend.quit = proc () = op(opQuit)

# ---------------------------------------------------------------------------------------------------------------
# Events from Java (glue.c)

const   # Native.java's event kinds
  evClick = 0
  evChange = 1
  evSubmit = 2
  evToggle = 3
  evPointerDown = 4
  evHttpDone = 8

var httpPending: Table[int, proc (r: Response)]

proc httpDone(id: int, text: string) =
  let done = httpPending.getOrDefault(id)
  httpPending.del id
  if done == nil: return
  var r: Response
  try:
    let j = parseJson(text)
    r.status = j{"status"}.getInt
    r.reason = j{"reason"}.getStr
    r.error = j{"error"}.getStr
    for h in j{"headers"}.getElems: r.headers.add (h[0].getStr, h[1].getStr)
    r.body = decode(j{"body"}.getStr)
  except CatchableError as e:
    r = Response(error: e.msg)
  done(r)

proc nk_event(id, kind: cint, text: cstring, x, y: cfloat, pointer: cint) {.exportc, cdecl.} =
  if kind == evHttpDone:
    httpDone(id, $text)
    return
  let w = widgets.getOrDefault(id)
  if w == nil: return
  case kind
  of evClick:
    if w.onClick != nil: w.onClick()
  of evChange:
    w.setTextSilently($text)
    if w.onChange != nil: w.onChange(w.text)
  of evSubmit:
    if w.onSubmit != nil: w.onSubmit(w.text)
  of evToggle:
    w.setCheckedSilently(x != 0)
    if w.onToggle != nil: w.onToggle(w.checked)
  of evPointerDown .. evPointerDown + 3:
    if w.onPointer != nil:
      w.onPointer(w, PointerEvent(kind: PointerKind(kind - evPointerDown), x: x, y: y, pointer: pointer))
  else: discard

proc nk_surface(id, width, height, isAttached: cint) {.exportc, cdecl.} =
  let c = widgets.getOrDefault(id)
  if c == nil: return
  attached[id] = isAttached != 0
  if isAttached != 0:
    if width == c.width and height == c.height: c.redraw()
    else: c.resized(width, height)

var timerActions: Table[int, proc ()]
var nextTimer = 1

proc nk_timer(id: cint) {.exportc, cdecl.} =
  let action = timerActions.getOrDefault(id)
  timerActions.del id
  if action != nil: action()

proc unmark(w: Widget) =
  w.realized = false
  for c in w.children: c.unmark()

proc nk_restart() {.exportc, cdecl.} =
  ## A new Activity: its views are new, so build them all again.
  if root == nil: return
  attached.clear()
  root.unmark()
  root.realize()
  op(opRoot, root.id)
  if title.len > 0: op(opTitle, text = title)

# ---------------------------------------------------------------------------------------------------------------
# Services

platform = "android"
pixelRatio = nk_density()
serviceImpl.startTimer = proc (ms: int, action: proc ()): int =
  let id = nextTimer
  inc nextTimer
  timerActions[id] = action
  op(opTimer, id, max(ms, 0))
  id
serviceImpl.stopTimer = proc (id: int) =
  timerActions.del id
  op(opUntimer, id)

proc keyFile(key: string): string =
  var name = ""
  for ch in key: name.add(if ch.isAlphaNumeric or ch in "-_.": ch else: '_')
  $nk_data_dir() / name

serviceImpl.load = proc (key: string): string =
  try: readFile(keyFile(key)) except CatchableError: ""
serviceImpl.store = proc (key, value: string) =
  let path = keyFile(key)
  writeFile(path & ".tmp", value)
  moveFile(path & ".tmp", path)
serviceImpl.request = proc (meth, url: string, headers: seq[(string, string)], body: string,
                            onDone: proc (r: Response)) =
  let id = nextTimer   # any unused number
  inc nextTimer
  httpPending[id] = onDone
  var hs = newJArray()
  for (k, v) in headers: hs.add %*[k, v]
  nk_http(id.cint, cstring($(%*{"method": meth, "url": url, "headers": hs, "body": encode(body)})))
serviceImpl.log = proc (text: string) = nk_log(text.cstring)

# ---------------------------------------------------------------------------------------------------------------

proc run*(t: string, r: Widget, width = 480, height = 640) =
  ## Shows `r` as the Activity's content. Returns at once; Android runs the event loop.
  root = r
  title = t
  root.realize()
  op(opRoot, root.id)
  op(opTitle, text = t)
