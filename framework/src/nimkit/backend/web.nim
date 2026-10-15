## The web backend (`nim js`): each widget is a DOM element laid out with flexbox, canvases are <canvas> elements
## (the pixel buffer is copied into an ImageData), timers are setTimeout, storage is localStorage, HTTP is fetch().

import std/[jsffi, strutils, tables, unicode]
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
proc parseFloat(s: cstring): float {.importjs: "parseFloat(#)".}
proc onError(p: JsObject, cb: proc (err: JsObject)): JsObject {.importjs: "#.catch(#)".}

var elems: Table[int, JsObject]   # widget id -> its element (for a check box, the <label> holding the <input>)
var inputs: Table[int, JsObject]  # check box id -> its <input>; slider id -> its <input type=range>

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
.nk-slider { display: flex; flex-direction: column; min-width: 0; }
.nk-slider > input { width: 100%; margin: 0; }
.nk-marks { position: relative; height: 1.4em; font-size: 11px; opacity: 0.7; }
.nk-marks > span { position: absolute; transform: translateX(-50%); white-space: nowrap; }
.nk-marks > span:first-child { transform: none; }
select { font: inherit; min-width: 0; padding: 4px 6px; }
progress { width: 100%; height: 6px; }
.nk-toggle[aria-pressed=true] { background: #c9daf2; border-color: #6b8fc4; }
.nk-hidden { display: none !important; }
.nk-icon { display: inline-block; flex: none; fill: currentColor; vertical-align: middle; }
button > .nk-icon + span:not(:empty) { margin-left: 6px; }
.nk-item { display: flex; align-items: center; cursor: pointer; padding: 4px 8px; border-radius: 6px; user-select: none; }
.nk-item:hover { background: rgba(127,127,127,0.12); }
.nk-selected { background: rgba(80,130,220,0.2); }
.nk-separator { flex: none; align-self: stretch; background: rgba(127,127,127,0.3); min-height: 1px; min-width: 1px; }
.nk-flat { background: none; border: none; padding: 4px; border-radius: 6px; color: inherit; }
.nk-flat:hover { background: rgba(127,127,127,0.15); }
.nk-heading { font-weight: bold; font-size: 1.2em; } .nk-bold { font-weight: bold; } .nk-dim { opacity: 0.65; }
.nk-small { font-size: 0.85em; } .nk-mono { font-family: monospace; } .nk-error { color: #c01c28; }
.nk-suggested { background: #3584e4; color: white; border: none; border-radius: 4px; padding: 5px 12px; }
.nk-destructive { background: #e01b24; color: white; border: none; border-radius: 4px; padding: 5px 12px; }
.nk-card { border: 1px solid rgba(127,127,127,0.25); border-radius: 6px; padding: 8px; }
.nk-menu { position: fixed; z-index: 10; background: #fff; color: #222; border: 1px solid rgba(0,0,0,0.15);
  border-radius: 6px; box-shadow: 0 4px 16px rgba(0,0,0,0.2); padding: 4px 0; min-width: 160px; }
@media (prefers-color-scheme: dark) { .nk-menu { background: #2a2a2c; color: #eee; } }
.nk-menu > div { display: flex; gap: 24px; padding: 5px 14px; cursor: default; white-space: nowrap; }
.nk-menu > div:hover { background: rgba(80,130,220,0.25); }
.nk-menu > div.nk-off { opacity: 0.45; pointer-events: none; }
.nk-menu > div > span:first-child { flex: 1; } .nk-menu > div > span + span { opacity: 0.6; }
.nk-menu > hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 4px 0; }
dialog.nk-dialog { border: none; border-radius: 10px; padding: 16px; min-width: 280px; color: inherit;
  background: #f6f5f2; } @media (prefers-color-scheme: dark) { dialog.nk-dialog { background: #2a2a2c; } }
dialog.nk-dialog h3 { margin: 0 0 12px; font-size: 1.1em; }
dialog.nk-dialog .nk-buttons { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }
@media (prefers-color-scheme: dark) { .nk-toggle[aria-pressed=true] { background: #2c4a73; } }
"""

proc el(tag: string, class = ""): JsObject =
  result = document.createElement(tag.cstring)
  if class.len > 0: result.className = class.cstring

proc svgIcon(name: string, size: int): JsObject =
  ## An inline <svg> of the icon `name` in the text colour.
  let ns = "http://www.w3.org/2000/svg".cstring
  result = document.createElementNS(ns, "svg".cstring)
  result.setAttribute("class", "nk-icon".cstring)
  result.setAttribute("width", cstring($size))
  result.setAttribute("height", cstring($size))
  result.setAttribute("viewBox", cstring("0 0 " & $iconEm & " " & $iconEm))
  let path = document.createElementNS(ns, "path".cstring)
  path.setAttribute("d", iconPaths.getOrDefault(name).cstring)
  result.appendChild(path)


proc keyEvent(ev: JsObject): KeyEvent =
  var mods = 0
  if ev.altKey.to(bool): mods = mods or modAlt
  if ev.ctrlKey.to(bool): mods = mods or modCtrl
  if ev.shiftKey.to(bool): mods = mods or modShift
  if ev.metaKey.to(bool): mods = mods or modSuper
  let key = $ev.key.to(cstring)
  var text = 0'u32
  if key.len > 0 and key.len <= 4 and key.runeLen == 1: text = uint32(key.runeAt(0))
  KeyEvent(down: true, code: ev["keyCode"].to(int), text: text, mods: mods)   # keyCode: Windows VK codes

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
  of wkLabel: e.textContent = w.text.cstring
  of wkButton:
    e.textContent = "".cstring
    if w.iconName.len > 0: e.appendChild(svgIcon(w.iconName, w.iconSize))
    let t = el("span")
    t.textContent = w.text.cstring
    e.appendChild(t)
  of wkIcon:
    let fresh = svgIcon(w.iconName, w.iconSize)
    e.setAttribute("width", fresh.getAttribute("width"))
    e.setAttribute("height", fresh.getAttribute("height"))
    e.firstChild.setAttribute("d", iconPaths.getOrDefault(w.iconName).cstring)
  of wkItem:
    e.style.gap = cstring($w.spacing & "px")
    if w.padding > 0: e.style.padding = cstring($w.padding & "px")
  of wkSeparator: discard
  of wkToggle:
    e.textContent = w.text.cstring
    e.setAttribute("aria-pressed", cstring(if w.checked: "true" else: "false"))
  of wkEntry:
    if $e.value.to(cstring) != w.text: e.value = w.text.cstring
    e.placeholder = w.placeholder.cstring
    e.`type` = cstring(if w.password: "password" else: "text")
  of wkCheck:
    e.lastChild.textContent = w.text.cstring
    inputs[w.id].checked = w.checked
  of wkCanvas: discard
  of wkSlider:
    let i = inputs[w.id]
    i.min = w.rangeMin
    i.max = w.rangeMax
    i.step = w.step
    if i.value.to(cstring) != cstring($w.value): i.value = cstring($w.value)
    let marks = e.lastChild
    marks.textContent = "".cstring
    marks.style.display = cstring(if w.marks.len > 0: "" else: "none")
    for (at, text) in w.marks:
      let m = el("span")
      m.textContent = text.cstring
      let span = w.rangeMax - w.rangeMin
      m.style.left = cstring($(if span > 0: (at - w.rangeMin) / span * 100 else: 0.0) & "%")
      if at >= w.rangeMax: m.style.transform = "translateX(-100%)".cstring
      marks.appendChild(m)
  of wkDropdown:
    while e.options.length.to(int) > w.items.len: discard e.remove(e.options.length.to(int) - 1)
    for i, item in w.items:
      if i < e.options.length.to(int): e.options[i].text = item.cstring
      else:
        let o = el("option")
        o.text = item.cstring
        discard e.add(o)
    e.selectedIndex = w.selected
  of wkProgress: e.value = w.value.clamp(0.0, 1.0)
  of wkScroll: discard
  if w.kind in {wkButton, wkToggle, wkEntry, wkDropdown}: e.disabled = not w.enabled
  if w.kind in {wkCheck, wkSlider}: inputs[w.id].disabled = not w.enabled
  e.style.minWidth = cstring(if w.minWidth > 0: $w.minWidth & "px" else: "")
  e.style.minHeight = cstring(if w.minHeight > 0: $w.minHeight & "px" else: "")
  e.classList.toggle("nk-expand".cstring, w.expanded)
  e.classList.toggle("nk-hidden".cstring, not w.visible)
  if w.tooltip.len > 0: e.title = w.tooltip.cstring else: e.removeAttribute("title")
  let shown = if e.dataset.nk.isUndefined: "" else: $e.dataset.nk.to(cstring)
  for c in shown.split(' '):
    if c.len > 0 and c notin w.classes: e.classList.remove(cstring("nk-" & c))
  for c in w.classes: e.classList.add(cstring("nk-" & c))
  e.dataset.nk = w.classes.join(" ").cstring

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
        if w.onEntryKey != nil and w.onEntryKey(keyEvent(ev)):
          ev.preventDefault()
          ev.stopPropagation()
          return
        if ev.key.to(cstring) == "Enter" and w.onSubmit != nil: w.onSubmit(w.text))
      i.addEventListener("focus", proc () = (if w.onFocusChange != nil: w.onFocusChange(true)))
      i.addEventListener("blur", proc () = (if w.onFocusChange != nil: w.onFocusChange(false)))
      i
    of wkIcon: svgIcon(w.iconName, w.iconSize)
    of wkItem:
      let d = el("div", "nk-item")
      d.setAttribute("role", "button")
      d.addEventListener("click", proc () = (if w.onClick != nil: w.onClick()))
      d.addEventListener("contextmenu", proc (ev: JsObject) =
        if w.onContext != nil:
          ev.preventDefault()
          w.onContext())
      d.addEventListener("auxclick", proc (ev: JsObject) =
        if ev.button.to(int) == 1 and w.onMiddle != nil:
          ev.preventDefault()
          w.onMiddle())
      d
    of wkSeparator: el("div", "nk-separator")
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
    of wkSlider:
      let box = el("div", "nk-slider")
      let i = el("input")
      i.`type` = "range".cstring
      i.addEventListener("input", proc () =
        w.setValueSilently(parseFloat(i.value.to(cstring)))
        if w.onValue != nil: w.onValue(w.value))
      box.appendChild(i)
      box.appendChild(el("div", "nk-marks"))
      inputs[w.id] = i
      box
    of wkDropdown:
      let s = el("select")
      s.addEventListener("change", proc () =
        w.setSelectedSilently(s.selectedIndex.to(int))
        if w.onSelect != nil and w.selected >= 0: w.onSelect(w.selected))
      s
    of wkToggle:
      let b = el("button", "nk-toggle")
      b.addEventListener("click", proc () =
        w.setCheckedSilently(not w.checked)
        b.setAttribute("aria-pressed", cstring(if w.checked: "true" else: "false"))
        if w.onToggle != nil: w.onToggle(w.checked))
      b
    of wkProgress:
      let p = el("progress")
      p.max = 1
      p
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
backend.moved = proc (parent, child: Widget, index: int) =
  let e = elems[parent.id]
  if index + 1 < parent.children.len: e.insertBefore(elems[child.id], elems[parent.children[index + 1].id])
  else: e.appendChild(elems[child.id])
backend.focus = proc (w: Widget) = discard elems[w.id].focus()
backend.selectAll = proc (w: Widget) =
  if w.kind == wkEntry: discard elems[w.id].select()
backend.present = paint
backend.setTitle = proc (title: string) = document.title = title.cstring
backend.quit = proc () = window.close()

# ---------------------------------------------------------------------------------------------------------------
# Menus and dialogs

var openMenu: JsObject
var lastPointer: tuple[x, y: float]   # where the last pointer press was (a menu without an anchor opens there)

proc closeMenu() =
  if openMenu != nil and not openMenu.isNull:
    discard openMenu.remove()
  openMenu = nil

proc showMenu(items: seq[MenuItem], x, y: float)

proc menuRow(it: MenuItem): JsObject =
  # One proc call per item, so each row's listener keeps its own item (closures in a loop share variables).
  if it.separator: return el("hr")
  let row = el("div")
  let l = el("span")
  l.textContent = cstring((if it.checked == 1: "✓ " elif it.checked == 0: "   " else: "") & it.label &
                          (if it.submenu.len > 0: " ▸" else: ""))
  row.appendChild(l)
  if it.shortcut.len > 0:
    let k = el("span")
    k.textContent = it.shortcut.cstring
    row.appendChild(k)
  if not it.enabled: row.classList.add("nk-off".cstring)
  row.addEventListener("click", proc (ev: JsObject) =
    ev.stopPropagation()
    if it.submenu.len > 0:
      let r = row.getBoundingClientRect()
      showMenu(it.submenu, r.right.to(float), r.top.to(float))
      return
    closeMenu()
    if it.action != nil: discard window.setTimeout(it.action, 0))
  row

proc showMenu(items: seq[MenuItem], x, y: float) =
  closeMenu()
  let m = el("div", "nk-menu")
  for it in items: m.appendChild(menuRow(it))
  m.style.left = cstring($x & "px")
  m.style.top = cstring($y & "px")
  document.body.appendChild(m)
  openMenu = m

backend.popup = proc (items: seq[MenuItem], anchor: Widget, x, y: float) =
  var px, py: float
  if anchor != nil and anchor.realized:
    let r = elems[anchor.id].getBoundingClientRect()
    if x >= 0 and y >= 0: (px, py) = (r.left.to(float) + x, r.top.to(float) + y)
    else: (px, py) = (r.left.to(float), r.bottom.to(float))
  else:
    (px, py) = (lastPointer.x, lastPointer.y)
  # Opened from a click: let that click finish before the document's "close on click" listener sees clicks.
  discard window.setTimeout(proc () = showMenu(items, px, py), 0)

var dialogEls: seq[(Dialog, JsObject)]

proc dialogButton(d: Dialog, i: int): JsObject =
  result = el("button")
  result.textContent = d.buttons[i].cstring
  if i == d.destructive: result.classList.add("nk-destructive".cstring)
  elif i == d.buttons.high and d.buttons.len > 1: result.classList.add("nk-suggested".cstring)
  result.addEventListener("click", proc () = d.dialogResult(i))

backend.showDialog = proc (d: Dialog) =
  let dl = el("dialog", "nk-dialog")
  let h = el("h3")
  h.textContent = d.title.cstring
  dl.appendChild(h)
  if d.content != nil: dl.appendChild(d.content.realize())
  let bs = el("div", "nk-buttons")
  for i in 0 ..< d.buttons.len: bs.appendChild(dialogButton(d, i))
  dl.appendChild(bs)
  dl.addEventListener("cancel", proc (ev: JsObject) =
    ev.preventDefault()
    d.dialogResult(-1))
  document.body.appendChild(dl)
  dialogEls.add (d, dl)
  discard dl.showModal()

backend.closeDialog = proc (d: Dialog) =
  var dl: JsObject
  for i in countdown(dialogEls.high, 0):
    if dialogEls[i][0] == d:
      dl = dialogEls[i][1]
      dialogEls.delete i
  if dl == nil: return
  if d.content != nil and d.content.realized: d.content.unrealize()
  discard dl.close()
  discard dl.remove()

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
  document.addEventListener("click", proc () = closeMenu())
  document.addEventListener("pointerdown", proc (ev: JsObject) =
    lastPointer = (ev.clientX.to(float), ev.clientY.to(float)), true)
  document.addEventListener("keydown", proc (ev: JsObject) =
    if ev.key.to(cstring) == "Escape" and openMenu != nil: closeMenu()
    if onWindowKey != nil and onWindowKey(keyEvent(ev)): ev.preventDefault())
