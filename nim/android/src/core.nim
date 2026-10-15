## webby-nim for Android: the browser core as a shared library (libwebbynim.so) under a thin Java shell
## (nim/android/java). Java owns the Android widgets (toolbar, URL field, tab list, dialogs) and forwards input; this
## module owns everything else: Ladybird (libwebby.so, the same native runtime as the Flutter APK), tabs, the pump,
## frames, touch gestures and the on-screen keyboard. Frames go straight from Ladybird's buffer into the page's
## Surface (glue.c), with no Flutter engine or GPU texture copy in between.
##
## Everything runs on Android's main thread: Java calls in through glue.c's native methods, and the pump is a timerfd
## on the main looper. Nim tells Java about changes with MainActivity's static on* methods (glue_call), passing JSON.

import std/[dynlib, json, math, monotimes, os, random, strutils, tables, times]
import ../../src/[base, ffi]
import ../../src/features/omnibox/address
export base, ffi, json, tables

proc glue_log(text: cstring) {.importc, cdecl.}
proc glue_call(name, arg: cstring) {.importc, cdecl.}
proc glue_schedule(ms: cint) {.importc, cdecl.}
proc glue_blit(pixels: pointer, w, h: cint): cint {.importc, cdecl.}
proc glue_call_string(name, arg: cstring): cstring {.importc, cdecl.}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc dlerror(): cstring {.importc, header: "<dlfcn.h>".}

proc log*(text: string) = glue_log(text.cstring)
proc call*(name, arg: string) = glue_call(name.cstring, arg.cstring)

proc callJava*(name, arg: string): (bool, string) =
  ## MainActivity.<name>(String): String, synchronously; (false, "") when it failed or returned null.
  let r = glue_call_string(name.cstring, arg.cstring)
  if r == nil: return (false, "")
  result = (true, $r)
  c_free(r)

proc event*(name: string, data: JsonNode = nil) =
  ## MainActivity.onEvent: {"event": name, ...data}, for features' UI.
  let j = if data == nil: newJObject() else: data.copy
  j["event"] = %name
  call("onEvent", $j)

# The Flutter app's page shims (lib/src/page_compat.dart) and right-click script (lib/src/context_menu.dart), read
# at compile time like the desktop Nim front end does.
const pageCompatScript = block:
  let dart = staticRead("../../../app/lib/src/page_compat.dart")
  let start = dart.find("r'''") + 4
  dart[start ..< dart.rfind("'''")]

proc dartString(dart, head: string): string =
  let start = dart.find(head) + head.len
  result = dart[start ..< dart.find("''';", start)]
  result = result.replace("\\\\", "\x01").replace("\\$", "$").replace("\x01", "\\")

const contextMenuScript = dartString(staticRead("../../../app/lib/src/context_menu.dart"),
  "String contextMenuPageScript(String prefix) => '''")

const homePage* = "about:blank"

type
  Tab* = ref object
    id*: int
    view*: View
    url*, title*: string
    loading*, canBack*, canForward*: bool
    messagePrefix*: string
    frameSerial, stateSerial: uint64
    lastCompat: MonoTime
    dialogJson*: string
    imeJson: string
    webauthnJson*, filePickerJson*, permissionJson*: string
    props*: Table[string, string]  ## per-tab scratch space for features
    closed*: bool
    pinned*: bool            ## kept at the front of the tab list and across restarts
    hiddenSince: MonoTime    ## when it last stopped being the active tab
    ## A tab can be asleep (view = nil, url and title kept): restored tabs until first shown, and background tabs
    ## put to sleep after a while or when Android is short of memory (as the desktop discards hidden tabs).

var
  tabs*: seq[Tab]
  active* = -1
  nextTabId = 1
  density* = 1.0
  dark* = false
  profile = ""
  viewW, viewH = 0            # page area, device pixels
  surfaceAttached = false
  shown = true                # the activity is in the foreground
  needsBlit = false
  lastState = ""
  lastIme = ""
  clipboardSerial: uint64
  quietTicks = 0
  pumping, wokeInPump: bool
  started = false
  initialTabsOpen = false      # the saved tabs are open; links from other apps can open now

  # Hooks for features (nim/android/src/features), the Android side of the desktop front end's (src/browser.nim).
  startupHooks*: seq[proc ()]                     ## Ladybird runs, before the first tabs open
  tabStateHooks*: seq[proc (t: Tab)]              ## url, title or loading changed
  tabClosedHooks*: seq[proc (t: Tab)]
  pageScriptHooks*: seq[proc (t: Tab): string]    ## JS run with the compat shims on every page
  pageTextHooks*: seq[proc (t: Tab, msg: string): bool]       ## raw messages, first; true = handled
  pageMessageHooks*: seq[proc (t: Tab, msg: JsonNode): bool]  ## JSON messages; true = handled
  activeTabHooks*: seq[proc (t: Tab)]             ## another tab became the active one
  stateHooks*: seq[proc (t: Tab, state: JsonNode)]  ## add fields to the state Java gets (t may be nil)
  ## Requests from pages; nil = declined.
  webauthnHandler*: proc (t: Tab, request: JsonNode)
  filePickerHandler*: proc (t: Tab, request: JsonNode)
  permissionHandler*: proc (t: Tab, request: JsonNode)
  ## Native.command(name, json) from Java: the reply is JSON (null when there's nothing to say).
  commands*: Table[string, proc (args: JsonNode): JsonNode]
  timers: seq[tuple[at: MonoTime, id: int, action: proc ()]]
  nextTimerId = 1

proc current*(): Tab = (if active in 0 ..< tabs.len: tabs[active] else: nil)

proc asleep*(t: Tab): bool = t.view == nil

proc wake*() =
  quietTicks = 0
  if pumping: wokeInPump = true
  else: glue_schedule(4)

proc after*(ms: int, action: proc ()): int {.discardable.} =
  ## Runs `action` from the pump in `ms` milliseconds; the id cancels it.
  result = nextTimerId
  inc nextTimerId
  timers.add (getMonoTime() + initDuration(milliseconds = ms), result, action)
  wake()

proc cancelTimer*(id: int) =
  for i in countdown(timers.high, 0):
    if timers[i].id == id: timers.delete(i)

proc runTimers(): int =
  ## Due timers run; the result is how long until the next one (ms), or -1.
  let now = getMonoTime()
  var due: seq[proc ()]
  for i in countdown(timers.high, 0):
    if timers[i].at <= now:
      due.add timers[i].action
      timers.delete(i)
  for i in countdown(due.high, 0):
    try: due[i]()
    except CatchableError as e: log "timer: " & e.msg
  result = -1
  for t in timers:
    let left = int((t.at - getMonoTime()).inMilliseconds)
    result = if result < 0: max(left, 1) else: min(result, max(left, 1))

base.startTimer = after
base.stopTimer = cancelTimer

proc randomPrefix(): string =
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  result = "webby-msg-"
  for _ in 0 ..< 16: result.add chars[rand(chars.high)]
  result.add ':'

# ---------------------------------------------------------------------------------------------------------------
# Saved tabs: <profile>/nim-android-tabs.json, {"tabs": [url...], "active": n}

proc tabsFile(): string = profile / "nim-android-tabs.json"

proc saveTabs() =
  if profile.len == 0 or not started: return
  var urls = newJArray()
  for t in tabs: urls.add %(if t.url.len > 0: t.url else: "about:blank")
  try:
    createDir(profile)
    var pinned = 0
    for t in tabs:
      if t.pinned: inc pinned
    writeFile(tabsFile() & ".tmp", $(%*{"tabs": urls, "active": active, "pinned": pinned}))
    moveFile(tabsFile() & ".tmp", tabsFile())
  except CatchableError as e: log "saving tabs: " & e.msg

# ---------------------------------------------------------------------------------------------------------------
# State for Java

proc sendState*() =
  var list = newJArray()
  proc shown(url: string): string = (if url == "about:blank": "" else: url)
  for t in tabs:
    list.add %*{"id": t.id, "title": (if t.url == "about:blank": "New tab" else: t.title), "url": shown(t.url),
      "loading": t.loading, "pinned": t.pinned}
  let t = current()
  let state = %*{
    "tabs": list, "active": active, "ready": initialTabsOpen,
    "url": (if t != nil: shown(t.url) else: ""), "title": (if t != nil: t.title else: ""),
    "loading": t != nil and t.loading, "canBack": t != nil and t.canBack, "canForward": t != nil and t.canForward}
  for h in stateHooks: h(t, state)
  let text = $state
  if text != lastState:
    lastState = text
    call("onState", text)

proc sendIme() =
  let t = current()
  let json = if t != nil and shown: t.imeJson else: ""
  let enabled = json.len > 0 and (try: parseJson(json){"enabled"}.getBool except CatchableError: false)
  let msg = if enabled: json else: ""
  if msg != lastIme:
    lastIme = msg
    call("onIme", msg)

proc blitActive() =
  let t = current()
  if t == nil or not surfaceAttached: return
  let px = webby_view_frame_pixels(t.view)
  if px == nil: return
  if glue_blit(px, webby_view_frame_width(t.view), webby_view_frame_height(t.view)) != 0: needsBlit = false

# ---------------------------------------------------------------------------------------------------------------
# Tabs

proc applySize(t: Tab) =
  if viewW > 0 and viewH > 0: webby_view_resize(t.view, viewW.cint, viewH.cint, density.cdouble)

proc wakeTab(t: Tab)

proc activate*(i: int) =
  if i notin 0 ..< tabs.len: return
  if active in 0 ..< tabs.len and active != i:
    let old = tabs[active]
    old.hiddenSince = getMonoTime()
    if not old.asleep:
      webby_view_set_focus(old.view, 0)
      webby_view_set_visible(old.view, 0)
      webby_view_collect_garbage(old.view)
  active = i
  let t = tabs[i]
  wakeTab(t)
  applySize(t)
  webby_view_set_visible(t.view, shown.cint)
  webby_view_set_focus(t.view, 1)
  needsBlit = true
  blitActive()
  for h in activeTabHooks: h(t)
  sendState()
  sendIme()
  wake()

proc setUp(t: Tab, view: View) =
  t.view = view
  t.lastCompat = getMonoTime()
  webby_view_set_message_prefix(view, t.messagePrefix.cstring)
  webby_view_set_color_scheme(view, (if dark: colorSchemeDark else: colorSchemeLight).cint)

proc adopt(view: View, focus: bool, at = -1): Tab =
  let t = Tab(id: nextTabId, messagePrefix: randomPrefix(), hiddenSince: getMonoTime())
  inc nextTabId
  setUp(t, view)
  let i = if at in 0 .. tabs.len: at else: tabs.len
  tabs.insert(t, i)
  if i <= active: inc active
  if focus or active < 0: activate(i)
  else:
    applySize(t)
    webby_view_set_visible(view, 0)
  sendState()
  t

proc newView(): View =
  webby_view_create(cint(max(viewW, 720)), cint(max(viewH, 1280)), density.cdouble)

proc openTab*(url: string, focus = true, at = -1): Tab {.discardable.} =
  result = adopt(newView(), focus, at)
  webby_view_load(result.view, (if url.len > 0: url else: homePage).cstring)
  wake()

proc openAsleep*(url: string, at = -1): Tab =
  ## A restored tab: no view (no WebContent process) until it is first shown.
  result = Tab(id: nextTabId, messagePrefix: randomPrefix(), url: url, title: url, hiddenSince: getMonoTime())
  inc nextTabId
  let i = if at in 0 .. tabs.len: at else: tabs.len
  tabs.insert(result, i)
  if active >= 0 and i <= active: inc active

proc wakeTab(t: Tab) =
  if not t.asleep: return
  setUp(t, newView())
  t.frameSerial = 0
  t.stateSerial = 0
  applySize(t)
  webby_view_set_visible(t.view, 0)
  webby_view_load(t.view, (if t.url.len > 0: t.url else: homePage).cstring)
  wake()

proc sleepTab*(t: Tab) =
  ## Frees a background tab's page; it reloads when shown again.
  if t.asleep or t.closed or t == current(): return
  webby_view_destroy(t.view)
  t.view = nil
  t.loading = false
  t.dialogJson = ""
  t.webauthnJson = ""
  t.filePickerJson = ""
  t.permissionJson = ""
  log "tab " & $t.id & " asleep: " & t.url

proc loadIn*(t: Tab, url: string) =
  ## Loads `url` in `t`, awake or not.
  if t.asleep:
    t.url = url
    t.title = url
  else: webby_view_load(t.view, url.cstring)
  wake()

const sleepAfter = initDuration(minutes = 10)

proc sleepIdleTabs*(all = false) =
  ## Background tabs hidden for 10 minutes (all of them when `all`) go to sleep; pinned ones only when `all`.
  let now = getMonoTime()
  for t in tabs:
    if t == current() or t.asleep: continue
    if all or (not t.pinned and now - t.hiddenSince >= sleepAfter): sleepTab(t)

proc saveTabsSoon*() = saveTabs()

proc moveTab*(i, to: int) =
  ## Moves tab `i` to index `to`, keeping the active tab active.
  if i notin 0 ..< tabs.len: return
  let t = tabs[i]
  let cur = current()
  tabs.delete(i)
  tabs.insert(t, clamp(to, 0, tabs.len))
  active = tabs.find(cur)
  saveTabs()
  sendState()

proc setPinned*(i: int, on: bool) =
  ## Pinned tabs come first: pinning moves a tab to the end of the pinned ones, unpinning to just after them.
  if i notin 0 ..< tabs.len or tabs[i].pinned == on: return
  tabs[i].pinned = on
  var n = 0
  for t in tabs:
    if t.pinned and t != tabs[i]: inc n
  moveTab(i, n)

proc closeTab*(i: int) =
  if i notin 0 ..< tabs.len: return
  let t = tabs[i]
  for h in tabClosedHooks: h(t)
  t.closed = true
  tabs.delete(i)
  if not t.asleep: webby_view_destroy(t.view)
  if tabs.len == 0:
    active = -1
    discard openTab(homePage)
    return
  if i < active or active >= tabs.len: dec active
  active = max(active, 0)
  let next = active
  active = -1
  activate(next)
  saveTabs()

proc tabIndex*(id: int): int =
  for i, t in tabs:
    if t.id == id: return i
  -1

# ---------------------------------------------------------------------------------------------------------------
# Page scripts and requests

proc runJs*(t: Tab, js: string) =
  if not t.closed and not t.asleep: webby_view_run_javascript(t.view, js.cstring)

proc runPageScripts(t: Tab) =
  t.lastCompat = getMonoTime()
  # As on the desktop: skip the about:blank document a new navigation is leaving (prompt() there wedges loads).
  let (open, close) = if t.url == "about:blank": ("", "") else: ("if (location.href !== 'about:blank') {\n", "\n}")
  t.runJs(open & pageCompatScript & close)
  t.runJs(open & contextMenuScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix)) & close)
  for h in pageScriptHooks:
    let js = h(t)
    if js.len > 0: t.runJs(js)

proc answerRequests(t: Tab) =
  let d = str(webby_view_dialog(t.view))
  if d != t.dialogJson:
    t.dialogJson = d
    if d.len > 0:
      try:
        let j = parseJson(d)
        j["tab"] = %t.id
        call("onDialog", $j)
      except CatchableError: discard
  # Passkeys, file inputs and site permissions go to their feature, or are declined when none handles them.
  # Each request is handed over once (a request stays pending until answered).
  let wa = str(webby_view_webauthn_prompt(t.view))
  if wa != t.webauthnJson:
    t.webauthnJson = wa
    if wa.len > 0:
      if webauthnHandler == nil: webby_view_webauthn_respond(t.view, 0, 0)
      else:
        try: webauthnHandler(t, parseJson(wa)) except CatchableError as e: log "webauthn: " & e.msg
  let fp = str(webby_view_file_picker_request(t.view))
  if fp != t.filePickerJson:
    t.filePickerJson = fp
    if fp.len > 0:
      if filePickerHandler == nil: webby_view_file_picker_respond(t.view, "[]")
      else:
        try: filePickerHandler(t, parseJson(fp)) except CatchableError as e: log "file picker: " & e.msg
  let perm = str(webby_view_permission_request(t.view))
  if perm != t.permissionJson:
    t.permissionJson = perm
    if perm.len > 0:
      try:
        let j = parseJson(perm)
        if permissionHandler == nil: webby_view_permission_respond(t.view, uint64(j{"id"}.getBiggestInt), 0)
        else: permissionHandler(t, j)
      except CatchableError as e: log "permission: " & e.msg

proc pageMessage(t: Tab, msg: string) =
  for h in pageTextHooks:
    if h(t, msg): return
  try:
    let j = parseJson(msg)
    for h in pageMessageHooks:
      if h(t, j): return
    if j{"type"}.getStr == "contextmenu":
      if j{"prevented"}.getBool: return
      j["tab"] = %t.id
      call("onContextMenu", $j)
  except CatchableError: discard

# ---------------------------------------------------------------------------------------------------------------
# Touch: a tap clicks, a drag scrolls (and flings on release), holding still right-clicks, which the context menu
# script reports back. The same gestures as the Flutter app's web_view.dart.

type Sample = tuple[ms: int64, x, y: float]

var
  touchId = -1
  touchStart, touchLast: tuple[x, y: float]
  touchDownAt: MonoTime
  touchScrolling, touchLongPressed: bool
  samples: seq[Sample]
  scrollAt: tuple[x, y: float]
  scrollDX, scrollDY = 0.0
  lastScrollSent: MonoTime
  flingVX, flingVY = 0.0
  flingLast: MonoTime
  flinging = false

const longPressMs = 500

proc slop(): float = 8.0 * density

proc sendScroll(force = false) =
  let t = current()
  if t == nil or (scrollDX == 0 and scrollDY == 0): return
  if not force and getMonoTime() - lastScrollSent < initDuration(milliseconds = 16): return
  webby_view_wheel_event(t.view, cint(scrollAt.x), cint(scrollAt.y), scrollDX, scrollDY, 1, 0)
  scrollDX = 0
  scrollDY = 0
  lastScrollSent = getMonoTime()

proc click(t: Tab, x, y: float, button: int) =
  let (ix, iy) = (cint(x), cint(y))
  webby_view_mouse_event(t.view, mouseMove, ix, iy, 0, 0, 0, 0)
  webby_view_mouse_event(t.view, mouseDown, ix, iy, button.cint, button.cint, 0, 1)
  webby_view_mouse_event(t.view, mouseUp, ix, iy, button.cint, 0, 0, 1)

proc stepTouch() =
  ## Each pump tick: pending scroll, the fling, and the long-press timer.
  let now = getMonoTime()
  if touchId >= 0 and not touchScrolling and not touchLongPressed and
      now - touchDownAt >= initDuration(milliseconds = longPressMs):
    touchLongPressed = true
    let t = current()
    if t != nil:
      webby_view_set_focus(t.view, 1)
      click(t, touchStart.x, touchStart.y, 2)
  if flinging:
    let dt = (now - flingLast).inMicroseconds.float / 1e6
    if dt >= 0.012:
      flingLast = now
      let decay = pow(0.95, dt / 0.016)
      flingVX *= decay
      flingVY *= decay
      if hypot(flingVX, flingVY) < 60 * density: flinging = false
      else:
        scrollDX += flingVX * dt
        scrollDY += flingVY * dt
  sendScroll()

proc touchActive(): bool = touchId >= 0 or flinging or scrollDX != 0 or scrollDY != 0

proc onTouch(action, pointer: int, x, y: float, ms: int64) =
  let t = current()
  if t == nil: return
  case action
  of 0:   # down
    if touchId >= 0: return
    flinging = false
    touchId = pointer
    touchStart = (x, y)
    touchLast = (x, y)
    touchDownAt = getMonoTime()
    touchScrolling = false
    touchLongPressed = false
    samples = @[(ms, x, y)]
  of 2:   # move
    if pointer != touchId or touchLongPressed: return
    samples.add (ms, x, y)
    while samples.len > 2 and ms - samples[0].ms > 100: samples.delete(0)
    if not touchScrolling and hypot(x - touchStart.x, y - touchStart.y) < slop(): return
    touchScrolling = true
    scrollAt = (x, y)
    scrollDX += touchLast.x - x
    scrollDY += touchLast.y - y
    touchLast = (x, y)
  of 1:   # up
    if pointer != touchId: return
    touchId = -1
    if touchLongPressed: return
    if touchScrolling:
      sendScroll(force = true)
      let s0 = samples[0]
      let dt = (ms - s0.ms).float / 1000
      if dt > 0.005:
        let vx = (x - s0.x) / dt
        let vy = (y - s0.y) / dt
        if hypot(vx, vy) > 200 * density:
          # The page moves with the finger, so it scrolls against the finger's direction.
          flingVX = -vx
          flingVY = -vy
          flingLast = getMonoTime()
          flinging = true
      return
    webby_view_set_focus(t.view, 1)
    click(t, touchStart.x, touchStart.y, 1)
  else:   # cancel
    touchId = -1
  wake()

# ---------------------------------------------------------------------------------------------------------------
# The pump: Ladybird's event loop on the main thread. 4 ms while anything happens, backing off to 100 ms when idle,
# the schedule of the desktop front ends.

proc pumpTab(t: Tab, isActive: bool): bool =
  var busy = t.loading
  let ss = webby_view_state_serial(t.view)
  if ss != t.stateSerial:
    busy = true
    t.stateSerial = ss
    let before = (t.url, t.title, t.loading)
    t.url = str(webby_view_url(t.view))
    t.title = str(webby_view_title(t.view))
    t.loading = webby_view_is_loading(t.view) != 0
    t.canBack = webby_view_can_go_back(t.view) != 0
    t.canForward = webby_view_can_go_forward(t.view) != 0
    t.imeJson = str(webby_view_ime_state(t.view))
    if (t.url, t.title, t.loading) != before:
      runPageScripts(t)
      for h in tabStateHooks: h(t)
      if before[2] and not t.loading: saveTabs()
    answerRequests(t)
    while true:
      let v = webby_view_take_new_view(t.view)
      if v == nil: break
      let i = tabs.find(t)
      discard adopt(v, true, if i >= 0: i + 1 else: -1)
    if webby_view_close_requested(t.view) != 0:
      closeTab(tabs.find(t))
      return true
    if isActive:
      sendState()
      sendIme()
  if t.loading and getMonoTime() - t.lastCompat >= initDuration(milliseconds = 100): runPageScripts(t)
  while true:
    let m = str(webby_view_next_message(t.view))
    if m.len == 0: break
    busy = true
    pageMessage(t, m)
  let fs = webby_view_frame_serial(t.view)
  if fs != t.frameSerial:
    t.frameSerial = fs
    busy = true
    if isActive: needsBlit = true
  busy

proc pump*(): int =
  pumping = true
  wokeInPump = false
  let events = webby_pump() > 0
  var busy = false
  let cs = webby_clipboard_serial()
  if cs != clipboardSerial:
    clipboardSerial = cs
    call("onClipboard", str(webby_clipboard_text()))
  let snapshot = tabs   # a copy: pumpTab may add or close tabs
  for t in snapshot:
    if not t.closed and not t.asleep and pumpTab(t, t == current()): busy = true
  stepTouch()
  if touchActive(): busy = true
  let nextTimer = runTimers()
  if needsBlit: blitActive()
  pumping = false
  quietTicks =
    if busy or wokeInPump: 0
    elif events: (if quietTicks >= 80: 40 else: min(quietTicks + 1, 79))
    else: quietTicks + 1
  result = if quietTicks < 60: 4 elif quietTicks < 80: 16 elif quietTicks < 100: 50 else: 100
  if nextTimer >= 0: result = min(result, nextTimer)

# ---------------------------------------------------------------------------------------------------------------
# Exports for glue.c

proc openInitialTabs() =
  ## Once Ladybird runs and the page's size is known: the saved tabs, or the home page.
  if not started or viewW <= 0 or tabs.len > 0: return
  var urls: seq[string]
  var act, pinned = 0
  try:
    let j = parseJson(readFile(tabsFile()))
    for u in j{"tabs"}: urls.add u.getStr
    act = j{"active"}.getInt
    pinned = j{"pinned"}.getInt
  except CatchableError: discard
  if urls.len == 0: urls = @[homePage]
  for i, u in urls:
    let t = openAsleep(u)
    t.pinned = i < pinned
  activate(clamp(act, 0, tabs.high))
  initialTabsOpen = true
  sendState()
  proc idleCheck() =
    sleepIdleTabs()
    discard after(60_000, idleCheck)
  discard after(60_000, idleCheck)

proc nim_init(prefix, profileDir: cstring, d: cdouble, isDark: cint): cint {.exportc, cdecl.} =
  if started:
    # A new activity in the same process: tell it everything again.
    lastState = ""
    lastIme = ""
    sendState()
    return 0
  log "nim_init: prefix " & $prefix & ", profile " & $profileDir
  randomize()
  density = max(d.float, 1.0)
  dark = isDark != 0
  profile = $profileDir
  # ffi.loadWebbyLib quits the process on failure, where nothing would say why: check first.
  if loadLib("libwebby.so") == nil:
    log "dlopen(libwebby.so) failed: " & $dlerror()
    return -100
  loadWebbyLib("libwebby.so")
  let r = webby_init(prefix)
  if r != 0:
    log "webby_init failed: " & $r
    return r
  started = true
  log "Ladybird started from " & $prefix
  for h in startupHooks:
    try: h() except CatchableError as e: log "startup: " & e.msg
  openInitialTabs()
  wake()
  0

proc nim_pump(): cint {.exportc, cdecl.} =
  if not started: return 100
  pump().cint

proc nim_surface(attached: cint) {.exportc, cdecl.} =
  surfaceAttached = attached != 0
  if surfaceAttached:
    needsBlit = true
    blitActive()
    wake()

proc nim_resize(w, h: cint) {.exportc, cdecl.} =
  if w <= 0 or h <= 0: return
  let changed = w != viewW or h != viewH
  viewW = w
  viewH = h
  let t = current()
  if changed and t != nil: applySize(t)
  openInitialTabs()
  wake()

proc nim_new_tab(url: cstring, focus: cint) {.exportc, cdecl.} =
  if not started: return
  let at = if active >= 0: active + 1 else: -1
  discard openTab(if url[0] == '\0': "" else: addressToUrl($url), focus != 0, at)
  saveTabs()

proc nim_close_tab(i: cint) {.exportc, cdecl.} = closeTab(i.int)
proc nim_select_tab(i: cint) {.exportc, cdecl.} = activate(i.int)

proc nim_load(text: cstring) {.exportc, cdecl.} =
  let t = current()
  let url = addressToUrl($text)
  if url.len == 0: return
  if t == nil: discard openTab(url)
  else:
    webby_view_load(t.view, url.cstring)
    webby_view_set_focus(t.view, 1)
  wake()

proc nim_nav(what: cint) {.exportc, cdecl.} =
  ## 0 back, 1 forward, 2 reload or stop, 3 reload
  let t = current()
  if t == nil: return
  case what
  of 0: webby_view_go_back(t.view)
  of 1: webby_view_go_forward(t.view)
  of 2: (if t.loading: webby_view_stop(t.view) else: webby_view_reload(t.view))
  else: webby_view_reload(t.view)
  wake()

proc nim_touch(action, pointer: cint, x, y: cfloat, ms: int64) {.exportc, cdecl.} =
  onTouch(action.int, pointer.int, x.float, y.float, ms)
  wake()

proc nim_key(down, code, cp, mods: cint) {.exportc, cdecl.} =
  let t = current()
  if t == nil: return
  webby_view_key_event(t.view, down, code, mods, cp.uint32, 0)
  wake()

proc nim_ime_commit(text: cstring, start, length: cint) {.exportc, cdecl.} =
  let t = current()
  if t == nil: return
  webby_view_ime_commit(t.view, text, start, length)
  wake()

proc nim_dialog_respond(tab: cint, id: int64, ok: cint, text: cstring) {.exportc, cdecl.} =
  let i = tabIndex(tab.int)
  if i < 0 or tabs[i].asleep: return
  webby_view_dialog_respond(tabs[i].view, uint64(id), ok, text)
  wake()

proc nim_set_focus(on: cint) {.exportc, cdecl.} =
  let t = current()
  if t != nil: webby_view_set_focus(t.view, on)
  wake()

proc nim_color_scheme(scheme: cint) {.exportc, cdecl.} =
  dark = scheme == colorSchemeDark
  for t in tabs:
    if not t.asleep: webby_view_set_color_scheme(t.view, scheme)
  wake()

proc nim_trim_memory(level: cint) {.exportc, cdecl.} =
  ## ComponentCallbacks2 levels: from TRIM_MEMORY_RUNNING_LOW (10) on, background tabs go to sleep.
  if level >= 10: sleepIdleTabs(all = true)
  for t in tabs:
    if not t.asleep: webby_view_collect_garbage(t.view)
  wake()

proc nim_visible(on: cint) {.exportc, cdecl.} =
  shown = on != 0
  let t = current()
  if t != nil:
    webby_view_set_visible(t.view, on)
    if shown: needsBlit = true
  if not shown: saveTabs()
  sendIme()
  wake()

proc nim_save() {.exportc, cdecl.} = saveTabs()

proc nim_paste(text: cstring) {.exportc, cdecl.} =
  ## Hands the system clipboard to the page, then pastes into the field that was long-pressed.
  let t = current()
  if t == nil: return
  webby_clipboard_set_text(text)
  t.runJs("window.__webbyContextMenu && window.__webbyContextMenu.act('paste', " & $(%($text)) & ");")
  wake()

proc nim_context_action(action, arg: cstring) {.exportc, cdecl.} =
  let t = current()
  if t == nil: return
  case $action
  of "openInNewTab":
    discard openTab($arg, focus = false, at = active + 1)
    saveTabs()
  of "open": nim_load(arg)
  of "setClipboard": webby_clipboard_set_text(arg)
  else:
    t.runJs("window.__webbyContextMenu && window.__webbyContextMenu.act(" & $(%($action)) & ", null);")
  wake()

var commandReply: string

proc nim_command(name, args: cstring): cstring {.exportc, cdecl.} =
  ## Native.command: runs a feature's command with JSON arguments; the JSON reply stays valid until the next call.
  let cmd = commands.getOrDefault($name)
  var reply: JsonNode = nil
  if cmd == nil: log "no command " & $name
  else:
    try:
      let a = if args == nil or args[0] == '\0': newJObject() else: parseJson($args)
      reply = cmd(a)
    except CatchableError as e:
      log "command " & $name & ": " & e.msg
      reply = %*{"error": e.msg}
  commandReply = if reply == nil: "null" else: $reply
  wake()
  commandReply.cstring
