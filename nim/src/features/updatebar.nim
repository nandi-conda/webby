## The bar under the toolbar that shows an update of webby while it downloads: what is coming, a progress bar and
## the percentage, then what to do once it's there (desktop: restart into it). update.nim (AppImage) and
## apkupdate.nim (Android) drive it; ✕ hides it until the next update starts (the download carries on, and
## ⋮ > Help still says how far it is).

import std/strutils
import ../browser
from nimkit/core as kit import nil

var
  bar, title, meter, actionButton: kit.Widget
  action: proc ()
  dismissed = false  ## ✕ was pressed: stays hidden until show() is called with `reopen`

proc build() =
  if bar != nil or barSlot == nil: return
  title = kit.label("")
  kit.`maxChars=`(title, 200)
  meter = kit.progress()
  let text = kit.column(title, meter)
  text.spacing = 2
  actionButton = kit.button("", proc () = (if action != nil: action()))
  proc dismiss() =
    dismissed = true
    kit.`visible=`(bar, false)
  let close = kit.iconButton("close", "Hide", dismiss, 16)
  bar = kit.row(kit.icon("downloading"), kit.expand(text), actionButton, close)
  bar.spacing = 8
  kit.addClass(bar, "webby-info-bar")
  kit.`visible=`(bar, false)
  kit.add(barSlot, bar)

proc percentText(fraction: float): string =
  if fraction < 0: "" else: " " & $int(fraction.clamp(0.0, 1.0) * 100) & "%"

proc show*(text: string, fraction = -1.0, buttonText = "", onButton: proc () = nil, reopen = false) =
  ## Shows `text` (with the percentage) over a bar filled to `fraction` (0..1; below 0 hides the bar, e.g. once
  ## it's done), and a button when `buttonText` is set. `reopen` shows it again after ✕.
  build()
  if bar == nil: return
  if reopen: dismissed = false
  kit.`text=`(title, text & percentText(fraction))
  kit.`visible=`(meter, fraction >= 0)
  if fraction >= 0: kit.`value=`(meter, fraction.clamp(0.0, 1.0))
  action = onButton
  kit.`text=`(actionButton, buttonText)
  kit.`visible=`(actionButton, buttonText.len > 0)
  kit.`visible=`(bar, not dismissed)

proc hide*() =
  if bar != nil: kit.`visible=`(bar, false)
  dismissed = false

proc lastPercent*(output: string): float =
  ## The last "NN.N%" in a tool's progress output (zsync2 prints "\r####---------- 43.2%" as it goes), as 0..1,
  ## or -1 if there's none.
  let at = output.rfind('%')
  if at <= 0: return -1
  var start = at
  while start > 0 and output[start - 1] in {'0'..'9', '.'}: dec start
  if start == at: return -1
  try: parseFloat(output[start ..< at]) / 100 except ValueError: -1
