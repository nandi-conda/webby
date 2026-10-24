## Bug reports, like Jam's browser extension: ⋮ > Report a bug (Ctrl+Shift+X) takes a screenshot of the page or
## records the tab, and adds what the page did (console messages and errors, network requests, clicks, typing and
## navigations, from scripts/bug_capture.js), the page's address and webby's version. The report is saved as a
## folder (the media, report.json and a report.html to look through it) under <download folder>/webby-bug-reports,
## whose path goes on the clipboard: its report.html shows everything with no server or account.
##
## A recording is of the page's own frames, which webby already has: they go to the webby-tabrec helper
## (nim/tabrec/, next to the app), which encodes WebM. No screen picker, no portal.

import std/[json, monotimes, os, osproc, streams, strutils, tables, times, uri]
import std/posix except Timer
import ../browser
import about, downloads
import bugreport/[enginelog, events, replay, system]
import adblock/store as adblockStore
from nimkit/core as kit import nil

const
  captureScript = staticRead("../scripts/bug_capture.js")
  reportPage = staticRead("bugreport/report.html")
  frameMs = 66                    ## up to 15 frames a second, when the page changes
  pollMs = 2000                   ## how often a recording collects what the page did
  maxRecordingMs = 10 * 60_000

{.push cdecl, importc.}
proc cairo_image_surface_create_for_data(data: pointer, format, width, height, stride: cint): pointer
proc cairo_surface_write_to_png_stream(surface: pointer, write: proc (closure: pointer, data: ptr char,
  length: cuint): cint {.cdecl.}, closure: pointer): cint
proc cairo_surface_destroy(surface: pointer)
{.pop.}

type
  Report = ref object
    video: bool
    media, mediaType, poster: string
    width, height, durationMs: int
    startedAt: int64                ## ms since the epoch: the screenshot's moment or the recording's start
    url, pageTitle: string
    viewport: tuple[width, height: int, dpr: float]
    userAgent, language: string
    captured: Captured
    title, notes, folder: string
    sampler: Sampler
    replayed: bool                  ## a video from instant replay, not a recording

  Recording = ref object
    report: Report
    process: Process
    inFd: cint
    path: string
    width, height: int
    started: MonoTime
    lastTab: Tab
    lastSerial: uint64
    lastFrameMs: int
    frames: int
    frameTimer, pollTimer: Timer
    stopping: bool

var
  waiting: Table[int, proc (dump: JsonNode)]
  nextDump = 1
  recording: Recording
  bar, barLabel, barStop, barCancel: kit.Widget
  recentNavigations: seq[JsonNode]   ## loads and tab switches of the last minutes, for instant replay reports
  recentSystem: seq[JsonNode]        ## memory/CPU every 10 s over the last minutes, likewise
  recentSampler = newSampler()

proc nowMs(): int64 = (epochTime() * 1000).int64

# ---------------------------------------------------------------------------------------------------------------
# Settings

proc showSettings() =
  let box = kit.column()
  box.spacing = 6
  discard kit.sized(box, 440)
  if incognito: kit.add(box, kit.label("Instant replay is off in incognito windows."))
  else:
    kit.add(box, kit.check("Keep the last 5 minutes of the tab for bug reports (instant replay)", replay.enabled(),
      proc (on: bool) = replay.setEnabled(on)))
  discard kit.dialog("Bug report settings", box, @["Close"])

# ---------------------------------------------------------------------------------------------------------------
# What the page did

proc script(t: Tab): string =
  if not (t.url.startsWith("http://") or t.url.startsWith("https://") or t.url.startsWith("file:")): return ""
  captureScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))

proc requestDump(t: Tab, c: Captured, done: proc (dump: JsonNode)) =
  ## Asks the tab's page for its entries newer than what `c` has; done(nil) if it doesn't answer in 3 s.
  if t == nil or t.closed or t.view == nil or script(t).len == 0:
    done(nil)
    return
  let id = nextDump
  inc nextDump
  waiting[id] = done
  var since = newJObject()
  for doc, s in c.since: since[doc] = %s
  t.runJs("window.__webbyBug && window.__webbyBug.dump(" & $id & ", " & $since & ")")
  wake()
  discard after(3000, proc () =
    if id in waiting:
      let d = waiting[id]
      waiting.del id
      d(nil))

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"bugDump\""): return false
  let m = try: parseJson(text) except CatchableError: return true
  let id = m{"id"}.getInt
  if id in waiting:
    let d = waiting[id]
    waiting.del id
    d(m)
  true

proc tabId(t: Tab): int = tabs.find(t) + 1

proc collect(r: Report, t: Tab, done: proc ()) =
  requestDump(t, r.captured, proc (dump: JsonNode) =
    if dump != nil:
      r.captured.addDump(dump, tabId(t))
      if r.userAgent.len == 0: r.userAgent = dump{"userAgent"}.getStr
      if r.language.len == 0: r.language = dump{"language"}.getStr
      let v = dump{"viewport"}
      if v != nil and r.viewport.width == 0:
        r.viewport = (v{"width"}.getInt, v{"height"}.getInt, v{"dpr"}.getFloat(1.0))
    done())

# ---------------------------------------------------------------------------------------------------------------
# Pictures

proc pngWrite(closure: pointer, data: ptr char, length: cuint): cint {.cdecl.} =
  let s = cast[ptr string](closure)
  let at = s[].len
  s[].setLen(at + length.int)
  if length > 0: copyMem(addr s[][at], data, length.int)
  0   # CAIRO_STATUS_SUCCESS

proc encodePng(pixels: pointer, width, height, stride: int): string =
  ## Ladybird's frames are premultiplied BGRA, which is cairo's ARGB32 on little-endian.
  let surface = cairo_image_surface_create_for_data(pixels, 0, width.cint, height.cint, stride.cint)
  discard cairo_surface_write_to_png_stream(surface, pngWrite, addr result)
  cairo_surface_destroy(surface)

proc frameOf(t: Tab): tuple[pixels: pointer, width, height: int] =
  if t == nil or t.view == nil: return
  let px = webby_view_frame_pixels(t.view)
  let w = webby_view_frame_width(t.view).int
  let h = webby_view_frame_height(t.view).int
  if px == nil or w <= 0 or h <= 0: return
  (px, w, h)

proc screenshot(t: Tab): tuple[png: string, width, height: int] =
  let f = frameOf(t)
  if f.pixels == nil: return
  var copy = newString(f.width * f.height * 4)   # the engine may draw a new frame while cairo reads
  copyMem(addr copy[0], f.pixels, copy.len)
  (encodePng(addr copy[0], f.width, f.height, f.width * 4), f.width, f.height)

# ---------------------------------------------------------------------------------------------------------------
# Saving and uploading

proc host(url: string): string =
  try: parseUri(url).hostname except CatchableError: ""

proc osName(): string =
  try:
    for line in lines("/etc/os-release"):
      if line.startsWith("PRETTY_NAME="): return line[12 .. ^1].strip(chars = {'"'})
  except CatchableError: discard
  "Linux"

proc kernel(): string =
  var u: Utsname
  if uname(u) == 0: $cast[cstring](addr u.release) else: ""

proc reportJson(r: Report): JsonNode =
  let (console, network, actions) = r.captured.sorted
  let b = buildInfo()
  %*{
    "title": r.title, "notes": r.notes, "createdAt": r.startedAt, "startedAt": r.startedAt, "video": r.video,
    "media": (if r.video: "recording.webm" else: "screenshot.png"), "durationMs": r.durationMs,
    "width": r.width, "height": r.height,
    "page": {"url": r.url, "title": r.pageTitle},
    "viewport": {"width": r.viewport.width, "height": r.viewport.height, "dpr": r.viewport.dpr},
    "browser": "Webby " & b.version & " (" & b.commit & ")", "engine": b.runtime,
    "userAgent": r.userAgent, "language": r.language, "os": osName() & " (Linux " & kernel() & ")",
    "console": console, "network": network, "actions": actions,
    "engineLog": r.captured.engine, "system": r.captured.system, "state": r.captured.state}

proc save(r: Report): string =
  ## Writes the report's folder (once; later calls rewrite report.json/html) and returns it.
  if r.folder.len == 0:
    let stamp = now().format("yyyy-MM-dd-HHmmss")
    var name = stamp & "-" & host(r.url).replace('.', '-')
    name = name.strip(chars = {'-'})
    r.folder = downloadsDir() / "webby-bug-reports" / name
    createDir(r.folder)
    writeFile(r.folder / (if r.video: "recording.webm" else: "screenshot.png"), r.media)
    if r.video and r.poster.len > 0: writeFile(r.folder / "poster.png", r.poster)
  let j = r.reportJson
  writeFile(r.folder / "report.json", j.pretty)
  writeFile(r.folder / "report.html", reportPage.replace("/*REPORT*/null", ($j).replace("</", "<\\/")))
  r.folder

proc formatClock(ms: int): string =
  let s = ms div 1000
  $(s div 60) & ":" & align($(s mod 60), 2, '0')

proc summary(r: Report): string =
  let (errors, failed) = r.captured.errorCount
  let (console, network, actions) = r.captured.sorted
  proc n(count: int, what: string): string = $count & " " & what & (if count == 1: "" else: "s")
  var parts = @[(if r.replayed: "Replay of the last " & formatClock(r.durationMs)
                elif r.video: "Recording of " & $(r.durationMs div 1000) & " s" else: "Screenshot")]
  parts.add n(console.len, "console message") & (if errors > 0: " (" & n(errors, "error") & ")" else: "")
  parts.add n(network.len, "request") & (if failed > 0: " (" & $failed & " failed)" else: "")
  parts.add n(actions.len, "action")
  var engineErrors = 0
  for e in r.captured.engine:
    if e{"level"}.getStr == "error": inc engineErrors
  parts.add n(r.captured.engine.len, "engine log line") &
    (if engineErrors > 0: " (" & n(engineErrors, "error") & ")" else: "")
  parts.join(" · ")

proc showBar(text: string, recordingControls: bool)
proc hideBar()

proc writeReport(r: Report): string =
  ## Saves the report's folder (rewriting report.json/html, so title and notes go in) and returns its path, which
  ## also goes on the clipboard, or "" after telling why it failed.
  try:
    result = save(r)
    copyText(result)
  except CatchableError as e:
    kit.alert("Couldn't save the report", e.msg)
    result = ""

proc discardReport(r: Report) =
  if r.folder.len == 0: return
  try: removeDir(r.folder)
  except CatchableError as e: kit.toast("Couldn't delete the report: " & e.msg)

proc showDetails(r: Report) =
  ## The report is saved as soon as it's taken, with its folder's path on the clipboard; the dialog adds a title
  ## and notes or throws it away.
  r.title = "Bug on " & (if host(r.url).len > 0: host(r.url) else: r.pageTitle)
  let folder = writeReport(r)
  if folder.len == 0: return
  kit.toast("Bug report saved, its folder's path is on the clipboard")
  let box = kit.column()
  box.spacing = 6
  discard kit.sized(box, 460)
  let title = kit.entry("Title", r.title)
  let notes = kit.entry("What went wrong? (optional)")
  kit.add(box, kit.addClass(kit.label(r.summary), "dim"))
  kit.add(box, kit.label("Title"))
  kit.add(box, title)
  kit.add(box, kit.label("Notes"))
  kit.add(box, notes)
  kit.add(box, kit.addClass(kit.addClass(kit.label("Saved in " &
    folder.replace(getHomeDir().strip(leading = false, chars = {'/'}), "~") & "; the path is on the clipboard. " &
    "Its report.html shows the " & (if r.video: "recording" else: "screenshot") &
    " with the console, network, actions and engine log."), "dim"), "small"))
  var d: kit.Dialog
  d = kit.dialog("Report a bug", box, @["Delete", "Show in folder", "Save"], destructive = 0, onResult = proc (i: int) =
    if i == 0:
      discardReport(r)
      return
    if i notin [1, 2]: return   # closed: the report stays as first written
    let newTitle = kit.text(title).strip
    if newTitle.len > 0: r.title = newTitle
    r.notes = kit.text(notes).strip
    if writeReport(r).len == 0: return
    if i == 1: showInFolder(folder / "report.html")
    elif i == 2: kit.toast("Bug report saved, its folder's path is on the clipboard"))
  notes.onSubmit = proc (t: string) = kit.dialogResult(d, 2)
  kit.focus(notes)

proc webbyState(): JsonNode =
  ## Webby itself when the report begins: build, settings and tabs (addresses scrubbed like the engine log).
  let b = buildInfo()
  var tabList = newJArray()
  var lines: seq[string]
  for i, t in tabs:
    let state = (if t == currentTab(): "active" elif t.view == nil: "asleep" else: "open") &
      (if t.pinned: ", pinned" else: "") & (if t.loading: ", loading" else: "")
    tabList.add %*{"index": i + 1, "title": t.title, "url": scrub(t.url), "state": state}
    lines.add $(i + 1) & ". " & (if t.title.len > 0: t.title & " " else: "") & "<" & scrub(t.url) & "> (" & state & ")"
  let session = getEnv("XDG_SESSION_TYPE", if getEnv("WAYLAND_DISPLAY").len > 0: "wayland" else: "x11")
  let desktop = getEnv("XDG_CURRENT_DESKTOP")
  let settings = %*{"adBlocking": adblockStore.enabled(), "incognito": incognito, "session": session,
    "desktop": desktop, "gtkTheme": getEnv("GTK_THEME"), "ladybirdArgs": getEnv("WEBBY_LADYBIRD_ARGS")}
  %*{"t": nowMs(), "kind": "state", "browser": b.version, "commit": b.commit, "engine": b.runtime,
     "settings": settings, "tabs": tabList,
     "text": "Webby " & b.version & " (" & b.commit & "), engine " & b.runtime & "; ad blocking " &
       (if adblockStore.enabled(): "on" else: "off") & (if incognito: "; incognito" else: "") & "; " & session &
       (if desktop.len > 0: " on " & desktop else: "") & "; " & $tabs.len & " tab" & (if tabs.len == 1: "" else: "s") &
       ":\n" & lines.join("\n")}

proc newReport(t: Tab, video: bool): Report =
  result = Report(video: video, startedAt: nowMs(), url: t.url, pageTitle: t.title, captured: newCaptured(),
    sampler: newSampler())
  result.captured.addNavigation(result.startedAt, t.url, t.title, tabId(t), "tab")
  result.captured.state = webbyState()
  result.captured.system.add result.sampler.sample

proc addInternals(r: Report) =
  ## The engine's log over the report's span (from its first page entry, at most 30 minutes back) and a last
  ## memory/CPU sample.
  var first = r.startedAt
  for list in [r.captured.console, r.captured.network, r.captured.actions]:
    for e in list: first = min(first, e{"t"}.getBiggestInt(first))
  first = max(first - 2000, r.startedAt - 30 * 60_000)
  if r.video: r.captured.system.add r.sampler.sample
  # The engine prints the page's console too ("(js error) ..."); keep only what the page capture missed (messages
  # from before it was in place, errors thrown from timers).
  proc plain(s: string): string = s.multiReplace(("\"", ""), (" ", ""))
  var pageMessages: seq[(int64, string)]
  for e in r.captured.console:
    var args: seq[string]
    for a in e{"args"}.getElems: args.add a.getStr
    pageMessages.add (e{"t"}.getBiggestInt, plain(args.join(" ")))
  r.captured.engine = @[]
  for e in enginelog.entries(first, nowMs()):
    let text = e{"text"}.getStr
    if text.startsWith("(js "):
      let message = plain(text[text.find(')') + 1 .. ^1])
      var dup = false
      for (t, m) in pageMessages:
        if m == message and abs(t - e{"t"}.getBiggestInt) < 3000: dup = true
      if dup: continue
    r.captured.engine.add e

proc takeScreenshot() =
  let t = currentTab()
  if t == nil: return
  let shot = screenshot(t)
  if shot.png.len == 0:
    kit.toast("This tab has nothing to show yet")
    return
  let r = newReport(t, false)
  (r.media, r.width, r.height) = shot
  r.mediaType = "image/png"
  collect(r, t, proc () = (r.addInternals; showDetails(r)))

# ---------------------------------------------------------------------------------------------------------------
# Recording the tab

proc tabrecPath(): string = getAppDir() / "webby-tabrec"

proc sendAll(fd: cint, data: pointer, n: int): bool =
  var done = 0
  while done < n:
    let w = posix.write(fd, cast[pointer](cast[int](data) + done), n - done)
    if w < 0:
      if errno == EINTR: continue
      return false
    done += w
  true

proc elapsed(rec: Recording): int = (getMonoTime() - rec.started).inMilliseconds.int

proc sendFrame(rec: Recording, t: Tab, force: bool) =
  let f = frameOf(t)
  if f.pixels == nil: return
  let serial = webby_view_frame_serial(t.view)
  let ms = rec.elapsed
  if not force and t == rec.lastTab and serial == rec.lastSerial and ms - rec.lastFrameMs < 1000: return
  rec.lastTab = t
  rec.lastSerial = serial
  rec.lastFrameMs = ms
  let header = "F " & $ms & "\n"
  var ok = sendAll(rec.inFd, header.cstring, header.len)
  if f.width == rec.width and f.height == rec.height:
    ok = ok and sendAll(rec.inFd, f.pixels, f.width * f.height * 4)
  else:
    # The window changed size: the frame is cut or padded to the recording's size.
    var buf = newString(rec.width * rec.height * 4)
    let rowBytes = min(f.width, rec.width) * 4
    for y in 0 ..< min(f.height, rec.height):
      copyMem(addr buf[y * rec.width * 4], cast[pointer](cast[int](f.pixels) + y * f.width * 4), rowBytes)
    ok = ok and sendAll(rec.inFd, addr buf[0], buf.len)
  if ok: inc rec.frames

proc finishRecording(dropIt: bool)

proc stopRecording*() = finishRecording(false)

proc startRecording() =
  if recording != nil: return
  let t = currentTab()
  if t == nil: return
  if not fileExists(tabrecPath()):
    hideBar()
    kit.alert("Recording isn't available", "webby-tabrec is missing next to Webby (" & tabrecPath() & ").")
    return
  let f = frameOf(t)
  if f.pixels == nil:
    hideBar()
    kit.toast("This tab has nothing to show yet")
    return
  let rec = Recording(report: newReport(t, true), width: f.width, height: f.height, inFd: -1)
  replay.paused = true
  rec.path = getTempDir() / ("webby-recording-" & $getpid() & "-" & $nowMs() & ".webm")
  try:
    rec.process = startProcess(tabrecPath(), args = [$f.width, $f.height, rec.path], options = {poStdErrToStdOut})
  except CatchableError as e:
    hideBar()
    kit.alert("Couldn't start recording", e.msg)
    return
  rec.inFd = rec.process.inputHandle.cint
  rec.started = getMonoTime()
  rec.report.startedAt = nowMs()
  let png = screenshot(t)
  rec.report.poster = png.png
  recording = rec
  sendFrame(rec, t, true)
  rec.frameTimer = every(frameMs, proc () =
    if recording != rec or rec.stopping: return
    let ms = rec.elapsed
    if ms >= maxRecordingMs:
      stopRecording()
      return
    let cur = currentTab()
    if cur != nil and cur != rec.lastTab:
      rec.report.captured.addNavigation(nowMs(), cur.url, cur.title, tabId(cur), "tab")
    if cur != nil: sendFrame(rec, cur, false)
    kit.`text=`(barLabel, "● Recording this tab  " & formatClock(ms)))
  rec.pollTimer = every(pollMs, proc () =
    if recording == rec and not rec.stopping:
      rec.report.captured.system.add rec.report.sampler.sample
      collect(rec.report, currentTab(), proc () = discard))
  showBar("● Recording this tab  0:00", true)

proc finishRecording(dropIt: bool) =
  let rec = recording
  if rec == nil or rec.stopping: return
  rec.stopping = true
  cancel(rec.frameTimer)
  cancel(rec.pollTimer)
  let endMs = rec.elapsed
  let tail = "E " & $endMs & "\n"
  discard sendAll(rec.inFd, tail.cstring, tail.len)
  rec.process.inputStream.close()
  showBar(if dropIt: "Stopping the recording…" else: "Finishing the recording…", false)
  let r = rec.report
  r.durationMs = endMs
  # The page's last entries, then the helper's file once it's done.
  collect(r, currentTab(), proc () =
    # The helper's answer is a line on its stdout (its exit code can't be relied on: the engine's process
    # handling may reap it first).
    let outFd = rec.process.outputHandle.cint
    var output = ""
    var waited = 0
    var check: Timer
    check = every(100, proc () =
      waited += 100
      var eof = false
      while true:
        var p = TPollfd(fd: outFd, events: POLLIN)
        if poll(addr p, 1, 0) <= 0: break
        var buf = newString(4096)
        let n = posix.read(outFd, addr buf[0], buf.len)
        if n <= 0:
          eof = true
          break
        output.add buf[0 ..< n]
      let answered = "DONE " in output or "ERROR " in output
      if not answered and not eof and waited < 60_000: return
      cancel(check)
      try: rec.process.close() except CatchableError: discard
      recording = nil
      replay.paused = false
      hideBar()
      if dropIt:
        removeFile(rec.path)
        return
      if "DONE " notin output or not fileExists(rec.path):
        kit.alert("The recording failed", if output.strip.len > 0: output.strip else: "webby-tabrec stopped without a word")
        return
      for line in output.splitLines:
        if line.startsWith("DONE "):
          try: r.durationMs = parseInt(line[5 .. ^1]) except ValueError: discard
      r.media = readFile(rec.path)
      removeFile(rec.path)
      r.mediaType = "video/webm"
      r.width = rec.width and not 1
      r.height = rec.height and not 1
      if r.width > 1920: (r.width, r.height) = (1920, (r.height * 1920 div rec.width) and not 1)
      r.addInternals
      showDetails(r)))

proc showBar(text: string, recordingControls: bool) =
  kit.`text=`(barLabel, text)
  kit.`visible=`(barStop, recordingControls)
  kit.`visible=`(barCancel, recordingControls)
  kit.`visible=`(bar, true)

proc hideBar() = kit.`visible=`(bar, false)

proc buildBar() =
  barLabel = kit.label("")
  barStop = kit.button("Stop", proc () = (if recording == nil: hideBar() else: stopRecording()))
  barCancel = kit.button("Cancel", proc () = (if recording == nil: hideBar() else: finishRecording(true)))
  bar = kit.row(kit.expand(barLabel), barStop, barCancel)
  bar.spacing = 6
  kit.addClass(bar, "webby-info-bar")
  kit.`visible=`(bar, false)
  kit.add(barSlot, bar)

proc takeReplay() =
  let t = currentTab()
  if t == nil: return
  showBar("Preparing the replay…", false)
  replay.take(proc (path: string, startMs, endMs: int64, width, height: int, error: string) =
    hideBar()
    if error.len > 0:
      kit.alert("No replay", error)
      return
    let r = newReport(t, true)
    r.startedAt = startMs
    r.replayed = true
    r.durationMs = int(endMs - startMs)
    try:
      r.media = readFile(path)
      removeFile(path)
    except CatchableError as e:
      kit.alert("No replay", e.msg)
      return
    if r.media.len == 0:
      kit.alert("No replay", "Joining the replay made an empty video")
      return
    r.mediaType = "video/webm"
    (r.width, r.height) = (width, height)
    r.poster = screenshot(t).png
    # Everything held goes along, not only the video's span: the navigations and memory/CPU of the last
    # 30 minutes, and what every open tab's pages captured since they loaded.
    for e in recentNavigations: r.captured.navigations.add e
    r.captured.system = recentSystem & r.captured.system
    collect(r, t, proc () =   # first, so its page info (viewport, user agent) is what the report keeps
      var others: seq[Tab]
      for o in tabs:
        if o.view != nil and o != t: others.add o
      var left = others.len
      if left == 0: (r.addInternals; showDetails(r)); return
      for o in others:   # all at once: a background tab may take until the 3 s timeout to answer
        collect(r, o, proc () =
          dec left
          if left == 0: (r.addInternals; showDetails(r)))))

proc reportBug() =
  if recording != nil:
    stopRecording()
    return
  let t = currentTab()
  if t == nil: return
  let past = replay.span()
  let hasReplay = replay.enabled() and past >= 2000
  let text = kit.label((if hasReplay: "Send what already happened (the last " & formatClock(past) & " of this tab), " &
      "take a screenshot of this page, or record what you do next. " else:
      "Take a screenshot of this page, or record what you do in this tab. ") &
    "Every report gets the page's console messages, network requests and your clicks, and Webby's engine log, " &
    "tabs, memory and CPU.")
  discard kit.sized(text, 440)
  var buttons = @["Cancel", "Record the tab", "Screenshot"]
  if hasReplay: buttons.add "Last " & formatClock(past)
  discard kit.dialog("Report a bug", text, buttons, proc (i: int) =
    # After the dialog is gone, so the page is what gets captured.
    # The bar goes up first, so the recording is of the page at the size it keeps while recording.
    if i == 1:
      showBar("● Recording this tab  0:00", true)
      discard after(400, proc () = (if kit.visible(bar): startRecording()))
    elif i == 2: discard after(150, takeScreenshot)
    elif i == 3: discard after(150, takeReplay))

proc install*() =
  enginelog.start()   # before the engine starts its helpers, so they write into it
  shutdownHooks.add enginelog.stop
  shutdownHooks.add replay.stop
  windowHooks.add proc () =
    replay.start()
    discard every(10_000, proc () =
      if not replay.enabled(): return
      recentSystem.add recentSampler.sample
      if recentSystem.len > 180: recentSystem.delete(0)   # 30 minutes
      while recentNavigations.len > 0 and recentNavigations[0]{"t"}.getBiggestInt < nowMs() - 30 * 60_000:
        recentNavigations.delete(0))
  proc remember(t: Tab, how: string) =
    if t == nil or t.loading or t.url.len == 0: return
    if recentNavigations.len > 0 and recentNavigations[^1]{"url"}.getStr == t.url and
        recentNavigations[^1]{"tab"}.getInt == tabId(t): return
    recentNavigations.add %*{"t": nowMs(), "kind": "navigation", "url": t.url, "title": t.title, "tab": tabId(t),
                             "how": how}
  tabStateHooks.add proc (t: Tab) = remember(t, "load")
  activeTabHooks.add proc (t: Tab) = remember(t, "tab")
  pageScriptHooks.add script
  pageMessageHooks.add onMessage
  windowHooks.add proc () =
    buildBar()
    addMenuSeparator()
    addMenuItem("Report a bug…", reportBug, shortcutText(modCtrl or modShift, 0x78))
    addMenuItem("Bug report settings…", proc () = showSettings())
  addShortcut(modCtrl or modShift, 0x78, reportBug)   # Ctrl+Shift+X
  tabStateHooks.add proc (t: Tab) =
    let rec = recording
    if rec != nil and not rec.stopping and not t.loading:
      rec.report.captured.addNavigation(nowMs(), t.url, t.title, tabId(t), "load")
  shutdownHooks.add proc () =
    if recording != nil:
      try: recording.process.terminate() except CatchableError: discard
