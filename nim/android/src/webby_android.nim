## webby-nim for Android: the browser core as a shared library (libwebbynim.so) under a thin Java shell
## (nim/android/java). Java owns the Android widgets (toolbar, URL field, tab list, dialogs) and forwards input; this
## module owns everything else: Ladybird (libwebby.so, the same native runtime as the Flutter APK), tabs, the pump,
## frames, touch gestures and the on-screen keyboard. Frames go straight from Ladybird's buffer into the page's
## Surface (glue.c), with no Flutter engine or GPU texture copy in between.
##
## Everything runs on Android's main thread: Java calls in through glue.c's native methods, and the pump is a timerfd
## on the main looper. Nim tells Java about changes with MainActivity's static on* methods (glue_call), passing JSON.

{.compile: "glue.c".}
{.passL: "-landroid -llog".}

import std/[dynlib, json, math, monotimes, os, random, strutils, times]
import ../../src/ffi

proc glue_log(text: cstring) {.importc, cdecl.}
proc glue_call(name, arg: cstring) {.importc, cdecl.}
proc glue_schedule(ms: cint) {.importc, cdecl.}
proc glue_blit(pixels: pointer, w, h: cint): cint {.importc, cdecl.}

proc dlerror(): cstring {.importc, header: "<dlfcn.h>".}

proc log(text: string) = glue_log(text.cstring)
proc call(name, arg: string) = glue_call(name.cstring, arg.cstring)

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

# The start page (app/lib/src/home_page.dart), drawn into about:blank tabs. No bookmarks here yet, so it shows just
# the search/address box.
const homePageScript = block:
  let dart = staticRead("../../../app/lib/src/home_page.dart")
  let head = "const homePageSource = r'''"
  let start = dart.find(head) + head.len
  dart[start ..< dart.find("''';", start)].replace("__WEBBY_HOME_DATA__", "{}")

const homePage = "about:blank"

type
  Tab = ref object
    id: int
    view: View
    url, title: string
    loading, canBack, canForward: bool
    messagePrefix: string
    frameSerial, stateSerial: uint64
    lastCompat: MonoTime
    dialogJson: string
    imeJson: string
    closed: bool

var
  tabs: seq[Tab]
  active = -1
  nextTabId = 1
  density = 1.0
  dark = false
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

proc current(): Tab = (if active in 0 ..< tabs.len: tabs[active] else: nil)

proc wake() =
  quietTicks = 0
  if pumping: wokeInPump = true
  else: glue_schedule(4)

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
    writeFile(tabsFile() & ".tmp", $(%*{"tabs": urls, "active": active}))
    moveFile(tabsFile() & ".tmp", tabsFile())
  except CatchableError as e: log "saving tabs: " & e.msg

# ---------------------------------------------------------------------------------------------------------------
# State for Java

proc sendState() =
  var list = newJArray()
  proc shown(url: string): string = (if url == "about:blank": "" else: url)
  for t in tabs: list.add %*{"id": t.id, "title": (if t.url == "about:blank": "New tab" else: t.title), "url": shown(t.url), "loading": t.loading}
  let t = current()
  let state = $(%*{
    "tabs": list, "active": active, "ready": initialTabsOpen,
    "url": (if t != nil: shown(t.url) else: ""), "title": (if t != nil: t.title else: ""),
    "loading": t != nil and t.loading, "canBack": t != nil and t.canBack, "canForward": t != nil and t.canForward})
  if state != lastState:
    lastState = state
    call("onState", state)

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

proc activate(i: int) =
  if i notin 0 ..< tabs.len: return
  if active in 0 ..< tabs.len and active != i:
    webby_view_set_focus(tabs[active].view, 0)
    webby_view_set_visible(tabs[active].view, 0)
    webby_view_collect_garbage(tabs[active].view)
  active = i
  let t = tabs[i]
  applySize(t)
  webby_view_set_visible(t.view, shown.cint)
  webby_view_set_focus(t.view, 1)
  needsBlit = true
  blitActive()
  sendState()
  sendIme()
  wake()

proc adopt(view: View, focus: bool, at = -1): Tab =
  let t = Tab(id: nextTabId, view: view, lastCompat: getMonoTime(), messagePrefix: randomPrefix())
  inc nextTabId
  webby_view_set_message_prefix(view, t.messagePrefix.cstring)
  webby_view_set_color_scheme(view, (if dark: colorSchemeDark else: colorSchemeLight).cint)
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

proc openTab(url: string, focus = true, at = -1): Tab =
  result = adopt(newView(), focus, at)
  webby_view_load(result.view, (if url.len > 0: url else: homePage).cstring)
  wake()

proc closeTab(i: int) =
  if i notin 0 ..< tabs.len: return
  let t = tabs[i]
  t.closed = true
  tabs.delete(i)
  webby_view_destroy(t.view)
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

proc tabIndex(id: int): int =
  for i, t in tabs:
    if t.id == id: return i
  -1

# ---------------------------------------------------------------------------------------------------------------
# Page scripts and requests

proc runJs(t: Tab, js: string) =
  if not t.closed: webby_view_run_javascript(t.view, js.cstring)

proc runPageScripts(t: Tab) =
  t.lastCompat = getMonoTime()
  # As on the desktop: skip the about:blank document a new navigation is leaving (prompt() there wedges loads).
  let (open, close) = if t.url == "about:blank": ("", "") else: ("if (location.href !== 'about:blank') {\n", "\n}")
  t.runJs(open & pageCompatScript & close)
  t.runJs(open & contextMenuScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix)) & close)
  if t.url == "about:blank": t.runJs(homePageScript)

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
  # Passkeys, file inputs and site permissions have no Android UI here yet: decline them.
  if str(webby_view_webauthn_prompt(t.view)).len > 0: webby_view_webauthn_respond(t.view, 0, 0)
  if str(webby_view_file_picker_request(t.view)).len > 0: webby_view_file_picker_respond(t.view, "[]")
  let perm = str(webby_view_permission_request(t.view))
  if perm.len > 0:
    try: webby_view_permission_respond(t.view, uint64(parseJson(perm){"id"}.getBiggestInt), 0)
    except CatchableError: discard

proc pageMessage(t: Tab, msg: string) =
  try:
    let j = parseJson(msg)
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

proc pump(): int =
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
    if not t.closed and pumpTab(t, t == current()): busy = true
  stepTouch()
  if touchActive(): busy = true
  if needsBlit: blitActive()
  pumping = false
  quietTicks =
    if busy or wokeInPump: 0
    elif events: (if quietTicks >= 80: 40 else: min(quietTicks + 1, 79))
    else: quietTicks + 1
  if quietTicks < 60: 4 elif quietTicks < 80: 16 elif quietTicks < 100: 50 else: 100

# ---------------------------------------------------------------------------------------------------------------
# Exports for glue.c

proc openInitialTabs() =
  ## Once Ladybird runs and the page's size is known: the saved tabs, or the home page.
  if not started or viewW <= 0 or tabs.len > 0: return
  var urls: seq[string]
  var act = 0
  try:
    let j = parseJson(readFile(tabsFile()))
    for u in j{"tabs"}: urls.add u.getStr
    act = j{"active"}.getInt
  except CatchableError: discard
  if urls.len == 0: urls = @[homePage]
  for u in urls: discard openTab(u, focus = false)
  activate(clamp(act, 0, tabs.high))
  initialTabsOpen = true
  sendState()

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
  discard openTab($url, focus != 0, at)
  saveTabs()

proc nim_close_tab(i: cint) {.exportc, cdecl.} = closeTab(i.int)
proc nim_select_tab(i: cint) {.exportc, cdecl.} = activate(i.int)

proc nim_load(text: cstring) {.exportc, cdecl.} =
  let t = current()
  if t == nil: discard openTab($text)
  else:
    webby_view_load(t.view, text)
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
  if i < 0: return
  webby_view_dialog_respond(tabs[i].view, uint64(id), ok, text)
  wake()

proc nim_set_focus(on: cint) {.exportc, cdecl.} =
  let t = current()
  if t != nil: webby_view_set_focus(t.view, on)
  wake()

proc nim_color_scheme(scheme: cint) {.exportc, cdecl.} =
  dark = scheme == colorSchemeDark
  for t in tabs: webby_view_set_color_scheme(t.view, scheme)
  wake()

proc nim_trim_memory(level: cint) {.exportc, cdecl.} =
  for t in tabs: webby_view_collect_garbage(t.view)
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
