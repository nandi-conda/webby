## Screen recording for pages, which Ladybird can't do: the page script (scripts/screen_capture.js) provides
## navigator.mediaDevices.getDisplayMedia() and MediaRecorder, and each shared screen is a webby-screencast helper
## (nim/screencast/) that asks the desktop's ScreenCast portal (its own picker is the consent; on X11, without a
## portal to ask, the site permission bar asks) and encodes WebM, which comes back here and goes to the page.
## Recording sites such as Jam (recorder.jam.dev) work with it.

import std/[os, posix, strutils, tables, base64]
import ../../browser
import permissions

const captureScript = staticRead("../../scripts/screen_capture.js")

proc g_spawn_async_with_pipes(dir: cstring, argv, envp: cstringArray, flags: cint, setup, data: pointer,
  pid: ptr cint, stdinFd, stdoutFd, stderrFd: ptr cint, err: pointer): cint {.importc, cdecl.}
proc g_child_watch_add(pid: cint, fn, data: pointer): cuint {.importc, cdecl.}
proc g_spawn_close_pid(pid: cint) {.importc, cdecl.}
proc g_unix_fd_add(fd: cint, condition: cuint, fn, data: pointer): cuint {.importc, cdecl.}
proc g_source_remove(id: cuint): cint {.importc, cdecl.}
proc g_timeout_add(ms: cuint, fn, data: pointer): cuint {.importc, cdecl.}

const
  gIoIn = 1.cuint
  gIoErr = 8.cuint
  gIoHup = 16.cuint

type Capture = ref object
  key: int
  tab: Tab
  pageId: int          ## the page's id for it (its getDisplayMedia request's)
  origin: string
  pid: cint
  inFd, outFd: cint
  watch: cuint
  buf: string          ## read from the helper, not parsed yet
  pending: string      ## WebM not passed to the page yet
  flushTimer: cuint
  ready: bool          ## READY came: the page has its stream
  microphone: bool     ## records the microphone alone (--audio), for a recorder the page already started
  idle: bool           ## the tab was seen done loading since; loading again is a new document
  done: bool

var
  captures: Table[int, Capture]
  nextKey = 1

proc helperPath(): string = getAppDir() / "webby-screencast"

proc available(): bool = fileExists(helperPath())

proc script(t: Tab): string =
  if secureOrigin(t.url).len == 0 or not available(): return ""
  captureScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))

proc callPage(c: Capture, js: string) =
  if c.tab.closed or secureOrigin(c.tab.url) != c.origin: return
  c.tab.runJs("window.__webbyCapture && window.__webbyCapture." & js)
  wake()

proc flush(c: Capture) =
  ## Passes the WebM read so far to the page. The muxer writes in small pieces (one per sound frame, dozens a
  ## second), and a page call for each kept Jam's page so busy that it gave up recording or got killed as hung.
  if c.pending.len == 0: return
  callPage(c, "data(" & $c.pageId & ", '" & encode(c.pending) & "')")
  c.pending = ""

proc command(c: Capture, line: string) =
  if c.done or c.inFd < 0: return
  let s = line & "\n"
  discard posix.write(c.inFd, s.cstring, s.len)

proc finish(c: Capture) =
  ## The helper is gone or should go: closing its stdin ends the sharing (and the portal session).
  if c.done: return
  c.done = true
  flush(c)
  if c.flushTimer != 0: discard g_source_remove(c.flushTimer)
  c.flushTimer = 0
  if c.watch != 0: discard g_source_remove(c.watch)
  c.watch = 0
  if c.inFd >= 0: discard posix.close(c.inFd)
  if c.outFd >= 0: discard posix.close(c.outFd)
  c.inFd = -1
  c.outFd = -1
  if c.microphone: callPage(c, "stopped(" & $c.pageId & ")")   # no-op when the page ended it
  elif c.ready: callPage(c, "ended(" & $c.pageId & ")")
  else: callPage(c, "denied(" & $c.pageId & ", 'NotReadableError', 'Could not share the screen')")
  captures.del c.key

proc handle(c: Capture, line: string) =
  let parts = line.split(' ')
  case parts[0]
  of "READY":
    c.ready = true
    if c.microphone: return
    let w = (try: parseInt(parts[1]) except CatchableError: 0)
    let h = (try: parseInt(parts[2]) except CatchableError: 0)
    callPage(c, "granted(" & $c.pageId & ", " & $w & ", " & $h & ", " & $(%parts[^1]) & ")")
  of "CANCELLED":
    callPage(c, "denied(" & $c.pageId & ", 'NotAllowedError', 'Permission denied')")
    c.ready = false
    c.pageId = -1
  of "ERROR":
    let text = line.substr(6)
    stderr.writeLine "webby: screen sharing: ", text
    if c.ready: callPage(c, "error(" & $c.pageId & ", " & $(%text) & ")")
    else: callPage(c, "denied(" & $c.pageId & ", 'NotReadableError', " & $(%text) & ")")
  of "STOPPED": callPage(c, "stopped(" & $c.pageId & ")")
  of "ENDED": callPage(c, "ended(" & $c.pageId & ")")
  else: discard

proc parse(c: Capture) =
  ## Handles the complete messages in c.buf; WebM bytes wait in c.pending for the next flush.
  var i = 0
  while true:
    let nl = c.buf.find('\n', i)
    if nl < 0: break
    let line = c.buf[i ..< nl]
    if line.startsWith("DATA "):
      let n = (try: parseInt(line.substr(5)) except CatchableError: -1)
      if n < 0 or nl + 1 + n > c.buf.len: break
      c.pending.add c.buf[nl + 1 ..< nl + 1 + n]
      i = nl + 1 + n
    else:
      flush(c)
      handle(c, line)
      i = nl + 1
  c.buf = c.buf.substr(i)
  if c.pending.len >= 4 shl 20: flush(c)

proc onOutput(fd: cint, condition: cuint, data: pointer): cint {.cdecl.} =
  let c = captures.getOrDefault(cast[int](data))
  if c == nil or c.done: return 0
  var chunk = newString(1 shl 20)
  let n = posix.read(fd, chunk.cstring, chunk.len)
  if n > 0:
    chunk.setLen n
    c.buf.add chunk
    parse(c)
    return 1
  if n < 0 and errno in [EINTR, EAGAIN]: return 1
  c.watch = 0
  finish(c)
  0

proc start(t: Tab, origin: string, pageId: int, mode: string): Capture =
  let c = Capture(key: nextKey, tab: t, pageId: pageId, origin: origin, inFd: -1, outFd: -1, idle: not t.loading,
    microphone: mode == "--audio")
  inc nextKey
  let argv = allocCStringArray([helperPath(), mode])
  defer: deallocCStringArray(argv)
  # G_SPAWN_DO_NOT_REAP_CHILD; the helper's stderr is webby's.
  if g_spawn_async_with_pipes(nil, argv, nil, 2, nil, nil, addr c.pid, addr c.inFd, addr c.outFd, nil, nil) == 0:
    callPage(c, "denied(" & $pageId & ", 'NotReadableError', 'Could not start screen sharing')")
    return nil
  discard g_child_watch_add(c.pid, proc (pid, status: cint, d: pointer) {.cdecl.} = g_spawn_close_pid(pid), nil)
  captures[c.key] = c
  c.flushTimer = g_timeout_add(500, proc (data: pointer): cint {.cdecl.} =
    let c = captures.getOrDefault(cast[int](data))
    if c == nil or c.done: return 0
    flush(c)
    1, cast[pointer](c.key))
  c.watch = g_unix_fd_add(c.outFd, gIoIn or gIoHup or gIoErr, onOutput, cast[pointer](c.key))
  c

proc find(t: Tab, pageId: int): Capture =
  for c in captures.values:
    if c.tab == t and c.pageId == pageId: return c

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"capture"): return false
  let m = try: parseJson(text) except CatchableError: return false
  let origin = secureOrigin(t.url)
  if origin.len == 0: return true
  case m{"type"}.getStr
  of "captureRequest":
    let id = m{"id"}.getInt
    # Wayland has only the portal (whose picker asks); on X11 the whole screen is shared once the site may.
    if getEnv("WAYLAND_DISPLAY").len > 0: discard start(t, origin, id, "--portal")
    else:
      askPermission(t, origin, "display-capture", proc (allowed: bool) =
        if t.closed or secureOrigin(t.url) != origin: return
        if allowed: discard start(t, origin, id, "--x11")
        else: t.runJs("window.__webbyCapture && window.__webbyCapture.denied(" & $id &
          ", 'NotAllowedError', 'Permission denied')"))
  of "captureMicrophone":
    # The page holds a live microphone track (the engine asked for it), so no question here.
    let c = start(t, origin, m{"capture"}.getInt, "--audio")
    if c != nil: command(c, "start 0 1")
  of "captureStart":
    let c = find(t, m{"capture"}.getInt)
    if c != nil: command(c, "start " & $int(m{"systemAudio"}.getBool) & " " & $int(m{"microphone"}.getBool))
  of "capturePause", "captureResume", "captureStop":
    let c = find(t, m{"capture"}.getInt)
    if c != nil: command(c, m{"type"}.getStr.substr(7).toLowerAscii)
  of "captureEnd":
    let c = find(t, m{"capture"}.getInt)
    if c != nil: finish(c)
  else: return false
  true

proc endFor(t: Tab, keep: string) =
  ## Stops the tab's sharing unless its page is still on `keep` (an origin; "" stops all).
  var gone: seq[Capture]
  for c in captures.values:
    if c.tab == t and (keep.len == 0 or c.origin != keep): gone.add c
  for c in gone: finish(c)

proc onTabState(t: Tab) =
  ## A capture belongs to one document. Another one loading in the tab (a reload, or Ladybird replacing a page
  ## process it killed as hung) can't use it, so the sharing ends instead of running on unseen.
  endFor(t, secureOrigin(t.url))
  var gone: seq[Capture]
  for c in captures.values:
    if c.tab != t: continue
    if not t.loading: c.idle = true
    elif c.idle: gone.add c
  for c in gone: finish(c)

proc install*() =
  pageScriptHooks.add script
  pageMessageHooks.add onMessage
  tabStateHooks.add onTabState
  tabClosedHooks.add proc (t: Tab) = endFor(t, "")
  shutdownHooks.add proc () =
    var all: seq[Capture]
    for c in captures.values: all.add c
    for c in all: finish(c)
