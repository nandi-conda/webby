## The web backend (`nim js`): each widget is a DOM element laid out with flexbox, canvases are <canvas> elements
## (the pixel buffer is copied into an ImageData), timers are setTimeout, storage is localStorage, HTTP is fetch().

import std/[jsffi, tables]
import ../[core, services]

var
  document {.importjs: "document", nodecl.}: JsObject
  window {.importjs: "window", nodecl.}: JsObject
  console {.importjs: "console", nodecl.}: JsObject
  localStorage {.importjs: "localStorage", nodecl.}: JsObject

proc newUint8ClampedArray(n: int): JsObject {.importjs: "new Uint8ClampedArray(#)".}
proc newImageData(data: JsObject, w, h: int): JsObject {.importjs: "new ImageData(#, #, #)".}
proc newResizeObserver(cb: proc (entries: JsObject)): JsObject {.importjs: "new ResizeObserver(#)".}
proc jsFetch(url: cstring, init: JsObject): JsObject {.importjs: "fetch(#, #)".}
proc onError(p: JsObject, cb: proc (err: JsObject)): JsObject {.importjs: "#.catch(#)".}

var elems: Table[int, JsObject]   # widget id -> its element (for a check box, the <label> holding the <input>)
var inputs: Table[int, JsObject]  # check box id -> its <input>

const css = """
html, body { margin: 0; height: 100%; font: 15px system-ui, sans-serif; color: #222; background: #f6f5f2; }
@media (prefers-color-scheme: dark) { html, body { color: #eee; background: #1d1d1f; } }
.nk-root { box-sizing: border-box; height: 100%; }
.nk-column, .nk-row { display: flex; box-sizing: border-box; min-width: 0; min-height: 0; }
.nk-column { flex-direction: column; } .nk-row { flex-direction: row; align-items: center; }
.nk-expand { flex: 1 1 0; min-width: 0; min-height: 0; }
.nk-scroll { overflow-y: auto; min-height: 0; }
.nk-canvas { display: block; touch-action: none; width: 100%; height: 100%; }
.nk-canvas-box { position: relative; min-height: 0; }
.nk-canvas-box > canvas { position: absolute; inset: 0; }
button, input { font: inherit; } input[type=text] { padding: 6px 8px; min-width: 0; }
.nk-label { white-space: pre-wrap; }
"""

proc el(tag: string, class = ""): JsObject =
  result = document.createElement(tag.cstring)
  if class.len > 0: result.className = class.cstring

# ---------------------------------------------------------------------------------------------------------------
# Canvases

proc paint(c: Canvas) =
  if c.width <= 0 or c.height <= 0: return
  let canvasEl = elems[c.id].firstChild
  let n = c.width * c.height
  let data = newUint8ClampedArray(n * 4)
  for i in 0 ..< n:
    # premultiplied 0xAARRGGBB -> straight RGBA bytes
    let p = c.pixels[i]
    let a = int(p shr 24)
    var r = int((p shr 16) and 255)
    var g = int((p shr 8) and 255)
    var b = int(p and 255)
    if a != 0 and a != 255:
      r = r * 255 div a
      g = g * 255 div a
      b = b * 255 div a
    data[i * 4] = r
    data[i * 4 + 1] = g
    data[i * 4 + 2] = b
    data[i * 4 + 3] = a
  canvasEl.getContext("2d".cstring).putImageData(newImageData(data, c.width, c.height), 0, 0)

proc canvasPointer(c: Canvas, kind: PointerKind, ev: JsObject) =
  if kind == pkDown: ev.target.setPointerCapture(ev.pointerId)
  if c.onPointer == nil: return
  let rect = ev.target.getBoundingClientRect()
  c.onPointer(c, PointerEvent(kind: kind, x: ev.clientX.to(float) - rect.left.to(float),
                              y: ev.clientY.to(float) - rect.top.to(float), pointer: ev.pointerId.to(int)))
  ev.preventDefault()

# ---------------------------------------------------------------------------------------------------------------
# Elements

proc sync(w: Widget) =
  let e = elems[w.id]
  case w.kind
  of wkColumn, wkRow:
    e.style.gap = cstring($w.spacing & "px")
    e.style.padding = cstring($w.padding & "px")
  of wkLabel, wkButton: e.textContent = w.text.cstring
  of wkEntry:
    if $e.value.to(cstring) != w.text: e.value = w.text.cstring
    e.placeholder = w.placeholder.cstring
  of wkCheck:
    e.lastChild.textContent = w.text.cstring
    inputs[w.id].checked = w.checked
  of wkCanvas:
    e.style.minWidth = cstring($w.minWidth & "px")
    e.style.minHeight = cstring($w.minHeight & "px")
  of wkScroll: discard
  if w.kind in {wkButton, wkEntry}: e.disabled = not w.enabled
  if w.kind == wkCheck: inputs[w.id].disabled = not w.enabled
  e.classList.toggle("nk-expand".cstring, w.expanded)

proc realize(w: Widget): JsObject =
  let e = case w.kind
    of wkColumn: el("div", "nk-column")
    of wkRow: el("div", "nk-row")
    of wkScroll: el("div", "nk-scroll")
    of wkLabel: el("div", "nk-label")
    of wkButton:
      let b = el("button")
      b.addEventListener("click", proc () =
        if w.onClick != nil: w.onClick())
      b
    of wkEntry:
      let i = el("input")
      i.`type` = "text".cstring
      i.addEventListener("input", proc () =
        w.setTextSilently($i.value.to(cstring))
        if w.onChange != nil: w.onChange(w.text))
      i.addEventListener("keydown", proc (ev: JsObject) =
        if ev.key.to(cstring) == "Enter" and w.onSubmit != nil: w.onSubmit(w.text))
      i
    of wkCheck:
      let l = el("label")
      let i = el("input")
      i.`type` = "checkbox".cstring
      i.addEventListener("change", proc () =
        w.setCheckedSilently(i.checked.to(bool))
        if w.onToggle != nil: w.onToggle(w.checked))
      l.appendChild(i)
      l.appendChild(el("span"))
      inputs[w.id] = i
      l
    of wkCanvas:
      let box = el("div", "nk-canvas-box")
      let c = el("canvas", "nk-canvas")
      box.appendChild(c)
      proc listen(name: string, kind: PointerKind) =   # a proc, so each listener keeps its own `kind`
        c.addEventListener(name.cstring, proc (ev: JsObject) = canvasPointer(w, kind, ev))
      listen("pointerdown", pkDown)
      listen("pointermove", pkMove)
      listen("pointerup", pkUp)
      listen("pointercancel", pkCancel)
      let observer = newResizeObserver(proc (entries: JsObject) =
        let width = box.clientWidth.to(int)
        let height = box.clientHeight.to(int)
        if width != w.width or height != w.height:
          c.width = width
          c.height = height
          w.resized(width, height))
      observer.observe(box)
      box
  elems[w.id] = e
  w.realized = true
  w.sync()
  for child in w.children: e.appendChild(child.realize())
  e

proc unrealize(w: Widget) =
  for c in w.children: c.unrealize()
  elems.del w.id
  inputs.del w.id
  w.realized = false

backend.update = proc (w: Widget) = w.sync()
backend.added = proc (parent, child: Widget, index: int) =
  let e = elems[parent.id]
  let node = child.realize()
  if index + 1 < parent.children.len: e.insertBefore(node, elems[parent.children[index + 1].id])
  else: e.appendChild(node)
backend.removed = proc (parent, child: Widget) =
  elems[parent.id].removeChild(elems[child.id])
  child.unrealize()
backend.present = paint
backend.setTitle = proc (title: string) = document.title = title.cstring
backend.quit = proc () = window.close()

# ---------------------------------------------------------------------------------------------------------------
# Services

platform = "web"
serviceImpl.startTimer = proc (ms: int, action: proc ()): int =
  window.setTimeout(action, ms).to(int)
serviceImpl.stopTimer = proc (id: int) = discard window.clearTimeout(id)
serviceImpl.load = proc (key: string): string =
  let v = localStorage.getItem(cstring(appName & "/" & key))
  if v.isNull: "" else: $v.to(cstring)
serviceImpl.store = proc (key, value: string) =
  discard localStorage.setItem(cstring(appName & "/" & key), value.cstring)
serviceImpl.request = proc (meth, url: string, headers: seq[(string, string)], body: string,
                            onDone: proc (r: Response)) =
  let init = newJsObject()
  init.method = meth.cstring
  let hs = newJsObject()
  for (k, v) in headers: hs[k.cstring] = v.cstring
  init.headers = hs
  if body.len > 0: init.body = body.cstring
  var r: Response
  let p = jsFetch(url.cstring, init)
  discard p.then(proc (res: JsObject): JsObject =
    r.status = res.status.to(int)
    r.reason = $res.statusText.to(cstring)
    discard res.headers.forEach(proc (value, name: JsObject) =
      r.headers.add ($name.to(cstring), $value.to(cstring)))
    res.text()
  ).then(proc (text: JsObject) =
    r.body = $text.to(cstring)
    onDone(r)
  ).onError(proc (err: JsObject) =
    onDone(Response(error: $err.toString().to(cstring))))
serviceImpl.log = proc (text: string) = console.log(text.cstring)

# ---------------------------------------------------------------------------------------------------------------

proc run*(title: string, root: Widget, width = 480, height = 640) =
  ## Puts `root` into the page (the whole viewport). Returns at once; the browser runs the event loop.
  document.title = title.cstring
  let style = el("style")
  style.textContent = css.cstring
  document.head.appendChild(style)
  let e = root.realize()
  e.classList.add("nk-root".cstring)
  document.body.appendChild(e)
