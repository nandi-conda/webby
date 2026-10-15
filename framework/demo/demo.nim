## nimkit's demo: the same source runs on the Linux desktop, Android and the web (see framework/README.md).
## A counter, an entry that is kept between runs, a timer, an HTTP fetch, a slider, a dropdown and a canvas you can
## draw on.

import std/[strutils, tables]
import nimkit

appName = "nimkit-demo"

const inks = [("Blue", (40, 90, 200)), ("Red", (200, 50, 40)), ("Green", (40, 150, 70))]

var
  count = 0
  strokes: seq[seq[(float, float)]]   # one per finger or mouse drag
  big = false
  ink = 0

let
  counter = label("Clicked 0 times")
  greeting = label("")
  uptime = label("Up for 0 s")
  fetched = label("")
  urlField = entry("Address to fetch", text = (if platform == "web": "index.html" else: "http://example.com/"))

proc greet(name: string) =
  greeting.text = if name.len > 0: "Hello, " & name & "!" else: "Type your name above; it is kept for next time."

let pad = canvas(minWidth = 200, minHeight = 160,
  onDraw = proc (c: Canvas) =
    c.fill(rgb(245, 245, 240))
    let width = (if big: 24.0 else: 8.0) * pixelRatio
    for s in strokes:
      for i in 0 ..< s.len:
        let (x0, y0) = s[max(i - 1, 0)]
        let (r, g, b) = inks[ink][1]
        c.line(x0, y0, s[i][0], s[i][1], width, rgb(r, g, b)))

var current: Table[int, int]   # pointer -> its stroke
pad.onPointer = proc (c: Canvas, e: PointerEvent) =
  case e.kind
  of pkDown:
    current[e.pointer] = strokes.len
    strokes.add @[(e.x, e.y)]
  of pkMove:
    if e.pointer in current: strokes[current[e.pointer]].add (e.x, e.y)
  of pkUp, pkCancel: current.del e.pointer
  c.redraw()

let name = entry("Your name", text = load("name"),
  onChange = proc (text: string) =
    store("name", text)
    greet(text))
greet(name.text)

let level = progress(0.5)
let levelText = label("50%")
let volume = slider(0, 100, 50, step = 5, onValue = proc (v: float) =
  level.value = v / 100
  levelText.text = $int(v) & "%")
volume.marks = @[(0.0, "Off"), (50.0, "Half"), (100.0, "Full")]

let ui = column(
  label("nimkit demo, running on " & platform),
  row(button("Click me", proc () =
        inc count
        counter.text = "Clicked " & $count & (if count == 1: " time" else: " times")),
      counter.expand),
  name,
  greeting,
  uptime,
  row(urlField.expand, button("Fetch", proc () =
    fetched.text = "Fetching " & urlField.text & "..."
    request("GET", urlField.text, proc (r: Response) =
      fetched.text = if r.status == 0: "Failed: " & r.error
                     else: $r.status & " " & r.reason & ", " & $r.body.len & " bytes: " &
                           r.body.strip.splitLines()[0][0 ..< min(60, r.body.strip.splitLines()[0].len)]))),
  fetched,
  row(volume.expand, levelText),
  level,
  row(check("Big dots", onToggle = proc (on: bool) =
        big = on
        pad.redraw()),
      dropdown(@[inks[0][0], inks[1][0], inks[2][0]], 0, proc (i: int) =
        ink = i
        pad.redraw()),
      button("Clear", proc () =
        strokes.setLen 0
        pad.redraw())),
  pad.expand)
ui.padding = 12

var seconds = 0
discard every(1000, proc () =
  inc seconds
  uptime.text = "Up for " & $seconds & " s")

run("nimkit demo", ui)
