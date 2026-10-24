## Find in page: Ctrl+F (or ⋮ > Find in page) opens a bar under the page with the query, "n of m", previous/next
## and close. Enter / F3 / Ctrl+G go to the next match, Shift with them to the previous one, Esc closes the bar.
## Ladybird does the search when the runtime has webby_view_find (every match highlighted); older runtimes get
## the page script, scripts/find_in_page.js.

import std/strutils
import ../browser
from nimkit/core as kit import nil

const findScript = staticRead("../scripts/find_in_page.js")

var
  bar, entry, countLabel, caseButton: kit.Widget
  shownFor: Tab          ## the tab the bar searches (nil while it is hidden)
  scriptCurrent, scriptTotal: int  ## the page script's last report
  scriptDefinedFor: string  ## url the page script was last defined in

proc js(s: string): string = $(%s)

proc query(): string = kit.text(entry)
proc caseSensitive(): bool = kit.checked(caseButton)

proc showCount(current, total: int) =
  let q = query()
  kit.`text=`(countLabel, if q.len == 0: "" elif total == 0: "No matches" else: $current & " of " & $total)
  kit.setClass(entry, "error", q.len > 0 and total == 0)

proc ensureScript(t: Tab) =
  if scriptDefinedFor != t.url:
    t.runJs(findScript.replace("__WEBBY_FIND_PREFIX__", js(t.messagePrefix)))
    scriptDefinedFor = t.url

proc byFeature(t: Tab, op: string): bool =
  ## A feature showing the tab itself (features/pdf) finds in it.
  for h in pageFindHooks:
    if h(t, op, query(), caseSensitive()): return true

proc search(t: Tab) =
  if t == nil: return
  let q = query()
  if byFeature(t, "find"):
    if q.len == 0: showCount(0, 0)
    return
  if hasNativeFind():
    webby_view_find(t.view, q.cstring, caseSensitive().cint)
  else:
    ensureScript(t)
    t.runJs("window.__webbyFind && window.__webbyFind.find(" & js(q) & ", " & $caseSensitive() & ");")
  if q.len == 0: showCount(0, 0)
  wake()

proc step(forward: bool) =
  let t = shownFor
  if t == nil: return
  if byFeature(t, if forward: "next" else: "previous"): return
  if hasNativeFind():
    if forward: webby_view_find_next(t.view) else: webby_view_find_previous(t.view)
  else:
    ensureScript(t)
    t.runJs("window.__webbyFind && window.__webbyFind." & (if forward: "next" else: "previous") & "();")
  wake()

proc endFind(t: Tab) =
  if t == nil or t.closed: return
  if byFeature(t, "end"): return
  if hasNativeFind(): webby_view_find_end(t.view)
  else: t.runJs("window.__webbyFind && window.__webbyFind.end();")
  wake()

proc closeBar*() =
  if shownFor == nil: return
  endFind(shownFor)
  shownFor = nil
  kit.`visible=`(bar, false)
  focusPage()

proc openBar*() =
  let t = currentTab()
  if t == nil: return
  if shownFor != t:
    if shownFor != nil: endFind(shownFor)
    shownFor = t
    scriptDefinedFor = ""
    kit.`visible=`(bar, true)
    if query().len > 0: search(t)
  kit.focus(entry)
  kit.selectAll(entry)

proc nextOrOpen(forward: bool) =
  if shownFor == nil or shownFor != currentTab():
    openBar()
  else: step(forward)

proc onEntryKey(e: kit.KeyEvent): bool =
  case e.code
  of 0x0D:                                 # Enter, Shift+Enter
    step((e.mods and kit.modShift) == 0)
    true
  of 0x1B:                                 # Esc
    closeBar()
    true
  else: false

proc buildBar() =
  entry = kit.entry("Find in page", onChange = proc (text: string) = search(shownFor))
  entry.onEntryKey = onEntryKey
  discard kit.sized(entry, 260)
  countLabel = kit.label("")
  discard kit.sized(countLabel, 90)
  caseButton = kit.toggle("Aa", onToggle = proc (on: bool) = search(shownFor))
  kit.`tooltip=`(caseButton, "Match case")
  bar = kit.row(entry, countLabel,
    kit.iconButton("keyboard_arrow_up", "Previous match (Shift+Enter)", proc () = step(false)),
    kit.iconButton("keyboard_arrow_down", "Next match (Enter)", proc () = step(true)),
    caseButton, kit.spacer(),
    kit.iconButton("close", "Close (Esc)", closeBar, 16))
  bar.spacing = 4
  kit.addClass(bar, "webby-find-bar")
  kit.`visible=`(bar, false)
  kit.add(findSlot, bar)

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"find\""): return false
  let j = try: parseJson(text) except CatchableError: return true
  scriptCurrent = j{"current"}.getInt
  scriptTotal = j{"total"}.getInt
  if t == shownFor: showCount(scriptCurrent, scriptTotal)
  true

proc install*() =
  windowHooks.add proc () =
    buildBar()
    loadCss(".webby-find-bar { border-top: 1px solid alpha(currentColor, 0.15); padding: 2px 0; }")
    addMenuItem("Find in page…", openBar, "Ctrl+F", mgPage)
  addShortcut(modCtrl, 0x66, openBar)                            # Ctrl+F
  addShortcut(0, 0xffc0, proc () = nextOrOpen(true))             # F3
  addShortcut(modShift, 0xffc0, proc () = nextOrOpen(false))     # Shift+F3
  addShortcut(modCtrl, 0x67, proc () = nextOrOpen(true))         # Ctrl+G
  addShortcut(modCtrl or modShift, 0x67, proc () = nextOrOpen(false))  # Ctrl+Shift+G
  addKeyHandler(0, 0xff1b, proc (): bool =                       # Esc (page focused) closes the bar
    result = shownFor != nil
    if result: closeBar())
  findHooks.add proc (t: Tab) =
    if t == shownFor: showCount(t.findCurrent, t.findTotal)
  pageMessageHooks.add onMessage
  activeTabHooks.add proc (t: Tab) =
    if shownFor != nil and shownFor != t: closeBar()
  tabClosedHooks.add proc (t: Tab) =
    if t == shownFor:
      shownFor = nil
      kit.`visible=`(bar, false)
  navigationHooks.add proc (t: Tab) =
    # A new page: search it again so the count and highlights match what shows.
    if t == shownFor:
      scriptDefinedFor = ""
      if query().len > 0: search(t)
