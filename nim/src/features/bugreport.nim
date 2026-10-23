## Bug reports, like Jam's browser extension: ⋮ > Report a bug (Ctrl+Shift+X) takes a screenshot of the page or
## records the tab, and adds what the page did (console messages and errors, network requests, clicks, typing and
## navigations, from scripts/bug_capture.js), the page's address and webby's version. The report is saved as a
## folder (the media, report.json and a report.html to look through it) under Downloads/webby-bug-reports, and can
## go up to Jam as a Jam with all of it on its timeline (bugreport/jam.nim). The Jam token is a secret in the
## password vault, set in ⋮ > Jam settings.
##
## A recording is of the page's own frames, which webby already has: they go to the webby-tabrec helper
## (nim/tabrec/, next to the app), which encodes WebM. No screen picker, no portal.

import std/[json, monotimes, os, osproc, streams, strutils, tables, times, uri]
import std/posix except Timer
import ../browser
import about, downloads
import bugreport/[events, jam]
from nimkit/core as kit import nil

const
  captureScript = staticRead("../scripts/bug_capture.js")
  reportPage = staticRead("bugreport/report.html")
  tokenSecret = "jam-token"
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
    title, notes, jamUrl, folder: string

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
  memoryToken: string            ## without a vault, the token lives until Webby quits

proc nowMs(): int64 = (epochTime() * 1000).int64

# ---------------------------------------------------------------------------------------------------------------
# The Jam token

proc token(): string =
  if getSecret != nil: getSecret(tokenSecret) else: memoryToken

proc showJamSettings(onSaved: proc () = nil) =
  if incognito and setSecret != nil:
    kit.alert("Set the Jam token in a normal window.")
    return
  let has = token().len > 0
  let box = kit.column()
  box.spacing = 6
  discard kit.sized(box, 440)
  let entry = kit.entry("jam_pat_…")
  kit.`password=`(entry, true)
  let show = kit.check("Show token", false, proc (on: bool) = kit.`password=`(entry, not on))
  let sync = kit.check("Sync this token to my other devices", secretSyncs == nil or secretSyncs(tokenSecret))
  let where = if setSecret != nil: "It is kept encrypted in the password vault." else:
    "The password vault isn't available, so the token is kept in memory until Webby quits."
  let help = kit.richLabel("Bug reports go to Jam with a personal access token. Make one at <a href=\"" & tokenSite &
    "\">" & kit.escapeRich(tokenSite) & "</a> with the <tt>mcp:read</tt> and <tt>mcp:write</tt> scopes; it starts " &
    "with <tt>jam_pat_</tt>. " & kit.escapeRich(where))
  help.onLink = proc (url: string): bool = (discard openTab(url); true)
  kit.add(box, kit.label(if has: "New Jam token (one is saved)" else: "Jam token"))
  kit.add(box, entry)
  kit.add(box, show)
  if setSecret != nil: kit.add(box, sync)
  kit.add(box, kit.addClass(kit.addClass(help, "dim"), "small"))
  var d: kit.Dialog
  d = kit.dialog("Jam settings", box, @["Remove token", "Cancel", "Save"], destructive = 0, onResult = proc (r: int) =
    if r notin [0, 2]: return
    let text = kit.text(entry).strip
    let value = if r == 0: "" elif text.len > 0: text else: token()
    if r == 2 and value.len == 0:
      kit.showDialog(d)
      kit.focus(entry)
      return
    if r == 2 and text.len > 0 and not text.startsWith("jam_"):
      kit.toast("That doesn't look like a Jam token (jam_pat_…), saved anyway")
    if setSecret != nil: setSecret(tokenSecret, value, kit.checked(sync))
    else: memoryToken = value
    if r == 2 and onSaved != nil: onSaved())
  entry.onSubmit = proc (t: string) = kit.dialogResult(d, 2)
  kit.focus(entry)

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
    "jam": r.jamUrl, "console": console, "network": network, "actions": actions}

proc save(r: Report): string =
  ## Writes the report's folder (once; later calls rewrite report.json/html, e.g. with the Jam link) and returns it.
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

proc summary(r: Report): string =
  let (errors, failed) = r.captured.errorCount
  let (console, network, actions) = r.captured.sorted
  proc n(count: int, what: string): string = $count & " " & what & (if count == 1: "" else: "s")
  var parts = @[(if r.video: "Recording of " & $(r.durationMs div 1000) & " s" else: "Screenshot")]
  parts.add n(console.len, "console message") & (if errors > 0: " (" & n(errors, "error") & ")" else: "")
  parts.add n(network.len, "request") & (if failed > 0: " (" & $failed & " failed)" else: "")
  parts.add n(actions.len, "action")
  parts.join(" · ")

proc description(r: Report): string =
  ## The Jam's description: the notes, then what Jam's own fields don't show (webby's build).
  let b = buildInfo()
  result = r.notes.strip
  if result.len > 0: result.add "\n\n"
  result.add "Reported from Webby " & b.version & " (" & b.commit & "), engine " & b.runtime & "."

proc showBar(text: string, recordingControls: bool)
proc hideBar()

proc uploadReport(r: Report) =
  if token().len == 0:
    showJamSettings(proc () = uploadReport(r))
    return
  try: discard save(r)
  except CatchableError as e: kit.toast("Couldn't save the report: " & e.msg)
  let b = buildInfo()
  var u = Upload(token: token(), video: r.video, media: r.media,
    mediaType: (if r.video: "video/webm" else: "image/png"), poster: r.poster, title: r.title,
    description: r.description, url: r.url, width: r.width, height: r.height, durationMs: r.durationMs,
    viewport: (r.viewport.width, r.viewport.height), browser: "Webby", browserVersion: b.version,
    os: osName(), osVersion: kernel())
  if u.width == 0: (u.width, u.height) = (r.viewport.width, r.viewport.height)
  u.events = r.captured.jamEvents(r.startedAt, r.url, (r.viewport.width, r.viewport.height), r.video)
  showBar("Uploading the bug report to Jam…", false)
  jam.upload(u, proc (text: string) = showBar(text, false), proc (ok: bool, url, error: string) =
    hideBar()
    if not ok:
      let where = if r.folder.len > 0: " It is saved in " & r.folder & "." else: ""
      discard kit.dialog("Upload to Jam failed", kit.label(error & where), @["Jam settings", "Close", "Try again"],
        onResult = proc (i: int) =
          if i == 0: showJamSettings(proc () = uploadReport(r))
          elif i == 2: uploadReport(r))
      return
    r.jamUrl = url
    try: discard save(r) except CatchableError: discard
    copyText(url)
    let link = kit.richLabel("<a href=\"" & url & "\">" & kit.escapeRich(url) & "</a>", selectable = true)
    link.onLink = proc (u: string): bool = (discard openTab(u); true)
    kit.toast("Jam link copied")
    discard kit.dialog("Jam made", kit.column(kit.label("The link is on the clipboard."), link),
      @["Close", "Open"], proc (i: int) = (if i == 1: discard openTab(url))))

proc showDetails(r: Report) =
  let box = kit.column()
  box.spacing = 6
  discard kit.sized(box, 460)
  let title = kit.entry("Title", "Bug on " & (if host(r.url).len > 0: host(r.url) else: r.pageTitle))
  let notes = kit.entry("What went wrong? (optional)")
  kit.add(box, kit.addClass(kit.label(r.summary), "dim"))
  kit.add(box, kit.label("Title"))
  kit.add(box, title)
  kit.add(box, kit.label("Notes"))
  kit.add(box, notes)
  let jamNote = if token().len > 0: "Upload to Jam makes a Jam with the " & (if r.video: "video" else: "screenshot") &
    ", console, network and actions, and copies its link." else: "Upload to Jam asks for your Jam token first."
  kit.add(box, kit.addClass(kit.addClass(kit.label("Save keeps it in Downloads/webby-bug-reports. " & jamNote), "dim"), "small"))
  var d: kit.Dialog
  d = kit.dialog("Report a bug", box, @["Discard", "Save", "Upload to Jam"], onResult = proc (i: int) =
    if i notin [1, 2]: return
    r.title = kit.text(title).strip
    if r.title.len == 0: r.title = "Bug on " & host(r.url)
    r.notes = kit.text(notes).strip
    if i == 2: uploadReport(r)
    else:
      try:
        let folder = save(r)
        kit.toast("Saved to " & folder)
        discard openTab("file://" & (folder / "report.html"))
      except CatchableError as e: kit.alert("Couldn't save the report", e.msg))
  notes.onSubmit = proc (t: string) = kit.dialogResult(d, 2)
  kit.focus(notes)

proc newReport(t: Tab, video: bool): Report =
  result = Report(video: video, startedAt: nowMs(), url: t.url, pageTitle: t.title, captured: newCaptured())
  result.captured.addNavigation(result.startedAt, t.url, t.title, tabId(t), "tab")

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
  collect(r, t, proc () = showDetails(r))

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

proc formatClock(ms: int): string =
  let s = ms div 1000
  $(s div 60) & ":" & align($(s mod 60), 2, '0')

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
    if recording == rec and not rec.stopping: collect(rec.report, currentTab(), proc () = discard))
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

proc reportBug() =
  if recording != nil:
    stopRecording()
    return
  let t = currentTab()
  if t == nil: return
  let text = kit.label("Take a screenshot of this page, or record what you do in this tab. Either way the " &
    "report gets the page's console messages, network requests and your clicks.")
  discard kit.sized(text, 420)
  discard kit.dialog("Report a bug", text, @["Cancel", "Record the tab", "Screenshot"], proc (i: int) =
    # After the dialog is gone, so the page is what gets captured.
    # The bar goes up first, so the recording is of the page at the size it keeps while recording.
    if i == 1:
      showBar("● Recording this tab  0:00", true)
      discard after(400, proc () = (if kit.visible(bar): startRecording()))
    elif i == 2: discard after(150, takeScreenshot))

proc install*() =
  pageScriptHooks.add script
  pageMessageHooks.add onMessage
  windowHooks.add proc () =
    buildBar()
    addMenuSeparator()
    addMenuItem("Report a bug…", reportBug, shortcutText(modCtrl or modShift, 0x78))
    addMenuItem("Jam settings…", proc () = showJamSettings())
  addShortcut(modCtrl or modShift, 0x78, reportBug)   # Ctrl+Shift+X
  tabStateHooks.add proc (t: Tab) =
    let rec = recording
    if rec != nil and not rec.stopping and not t.loading:
      rec.report.captured.addNavigation(nowMs(), t.url, t.title, tabId(t), "load")
  shutdownHooks.add proc () =
    if recording != nil:
      try: recording.process.terminate() except CatchableError: discard
