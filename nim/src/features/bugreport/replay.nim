## Instant replay for bug reports: webby keeps the last five minutes of the active tab, so a bug that already
## happened can go into a report without recording it again (⋮ > Report a bug > Last M:SS).
##
## The frames go to webby-tabrec as they change (at most ~3 a second, scaled to 960 px wide) in 30-second pieces,
## each its own WebM in the runtime directory; pieces older than five minutes are deleted. Taking the replay ends the
## current piece and joins the kept ones into one WebM (webby-tabrec --join). Cost: nothing while the page is
## still; while it changes, one encoder process (~6% of a core at 1320×900 in measurements) and a few MB of files.
## Off in incognito windows. The choice is <profile>/instant_replay.json ({"enabled": bool}), on by default.

import std/[json, monotimes, os, osproc, strutils, times]
import std/posix except Timer
import ../../[base, browser, ffi]
import nimkit/services

const
  pieceMs = 30_000
  keepMs = 5 * 60_000            ## the pieces live in tmpfs (RAM): a few MB a minute, ~20 MB a minute of video playback
  frameGapMs = 333
  replayWidth = 960

type
  Piece = ref object
    path: string
    process: Process
    inFd: cint
    started: MonoTime
    startMs, endMs: int64          ## wall clock, ms since the epoch
    width, height: int             ## the frames'
    frames: int
    ending, done, failed: bool
    output: string

var
  pieces: seq[Piece]
  current: Piece
  lastTab: Tab
  lastSerial: uint64
  lastSentMs: int64
  ticker: Timer
  enabledCache = -1
  paused*: bool                  ## a recording is running

proc nowMs(): int64 = (epochTime() * 1000).int64

proc tabrecPath(): string = getAppDir() / "webby-tabrec"

proc dir(): string =
  let runtime = getEnv("XDG_RUNTIME_DIR")
  (if runtime.len > 0 and dirExists(runtime): runtime / "webby" else: getTempDir() / "webby-" & $getuid()) /
    "replay-" & $getCurrentProcessId()

proc enabled*(): bool =
  if enabledCache < 0:
    let j = readJsonFile(profileFile("instant_replay.json"))
    enabledCache = if j != nil and j{"enabled"} != nil and j{"enabled"}.kind == JBool: ord(j{"enabled"}.getBool) else: 1
  enabledCache == 1 and not incognito and fileExists(tabrecPath())

proc outSize(w, h: int): (int, int) =
  if w <= replayWidth: (w and not 1, h and not 1)
  else: (replayWidth, (h * replayWidth div w) and not 1)

proc writeAll(fd: cint, data: pointer, n: int): bool =
  var done = 0
  while done < n:
    let w = posix.write(fd, cast[pointer](cast[int](data) + done), n - done)
    if w < 0:
      if errno == EINTR: continue
      return false
    done += w
  true

proc readOutput(p: Piece) =
  ## Whatever webby-tabrec printed so far (DONE or ERROR once the piece is finished), without waiting.
  if p.process == nil: return
  let fd = p.process.outputHandle.cint
  while true:
    var pfd = TPollfd(fd: fd, events: POLLIN)
    if poll(addr pfd, 1, 0) <= 0: break
    var buf = newString(4096)
    let n = posix.read(fd, addr buf[0], buf.len)
    if n <= 0:
      if "DONE" notin p.output: p.failed = true
      p.done = true
      break
    p.output.add buf[0 ..< n]
  if "DONE" in p.output or "ERROR" in p.output:
    p.done = true
    p.failed = "DONE" notin p.output
  if p.done:
    try: p.process.close() except CatchableError: discard
    p.process = nil

proc endPiece() =
  let p = current
  current = nil
  if p == nil: return
  p.ending = true
  p.endMs = nowMs()
  let tail = "E " & $(p.endMs - p.startMs) & "\n"
  discard writeAll(p.inFd, tail.cstring, tail.len)
  try: p.process.inputStream.close() except CatchableError: discard

proc drop(p: Piece) =
  if p.process != nil:
    try: p.process.terminate(); p.process.close() except CatchableError: discard
    p.process = nil
  try: removeFile(p.path) except CatchableError: discard

proc startPiece(w, h: int): Piece =
  try: createDir(dir()) except CatchableError: return nil
  let p = Piece(path: dir() / ("piece-" & $nowMs() & ".webm"), width: w, height: h, inFd: -1)
  try:
    p.process = startProcess(tabrecPath(), args = [$w, $h, p.path, $replayWidth], options = {poStdErrToStdOut})
  except CatchableError: return nil
  p.inFd = p.process.inputHandle.cint
  p.started = getMonoTime()
  p.startMs = nowMs()
  pieces.add p
  p

proc sendFrame(p: Piece, pixels: pointer) =
  var pfd = TPollfd(fd: p.inFd, events: POLLOUT)
  if poll(addr pfd, 1, 0) <= 0: return    # the encoder is behind: skip this frame rather than wait
  let header = "F " & $(nowMs() - p.startMs) & "\n"
  if writeAll(p.inFd, header.cstring, header.len) and writeAll(p.inFd, pixels, p.width * p.height * 4):
    inc p.frames
  else:
    p.failed = true

proc tick() =
  for p in pieces:
    if p.ending and not p.done: readOutput(p)
  # Pieces that ended more than two minutes ago go.
  var kept: seq[Piece]
  for p in pieces:
    if p.ending and (p.done or nowMs() - p.endMs > 60_000) and nowMs() - p.endMs > keepMs: drop(p)
    elif p.done and p.failed: drop(p)
    else: kept.add p
  pieces = kept
  if paused or not enabled():
    if current != nil: endPiece()
    return
  let t = currentTab()
  if t == nil or t.view == nil: return
  let px = webby_view_frame_pixels(t.view)
  let w = webby_view_frame_width(t.view).int
  let h = webby_view_frame_height(t.view).int
  if px == nil or w < 16 or h < 16: return
  let serial = webby_view_frame_serial(t.view)
  if current != nil and (current.width != w or current.height != h or current.failed or
      nowMs() - current.startMs >= pieceMs):
    endPiece()
  let fresh = current == nil
  if not fresh and t == lastTab and serial == lastSerial: return
  if not fresh and nowMs() - lastSentMs < frameGapMs: return
  if fresh:
    current = startPiece(w, h)
    if current == nil: return
  lastTab = t
  lastSerial = serial
  lastSentMs = nowMs()
  current.sendFrame(px)

proc start*() =
  # Pieces left by webby processes that are gone (killed before they could clean up).
  try:
    for d in walkDirs(dir().parentDir / "replay-*"):
      if not dirExists("/proc" / d.extractFilename["replay-".len .. ^1]): removeDir(d)
  except CatchableError: discard
  if ticker == nil: ticker = every(100, tick)

proc stop*() =
  if current != nil: endPiece()
  for p in pieces: drop(p)
  pieces = @[]
  try: removeDir(dir()) except CatchableError: discard

proc setEnabled*(on: bool) =
  enabledCache = ord(on)
  if not incognito:
    try: writeJsonFile(profileFile("instant_replay.json"), %*{"enabled": on}) except CatchableError: discard
  if not on:
    if current != nil: endPiece()

proc span*(): int =
  ## How many ms of replay there are now.
  var first = nowMs()
  for p in pieces:
    if not p.failed and p.frames > 0: first = min(first, p.startMs)
  int(nowMs() - max(first, nowMs() - keepMs))

proc take*(done: proc (path: string, startMs, endMs: int64, width, height: int, error: string)) =
  ## Ends the current piece and joins everything kept (up to five minutes) into one WebM (a temporary file the caller removes).
  endPiece()
  let wanted = pieces
  var waited = 0
  var check: Timer
  check = every(100, proc () =
    waited += 100
    var pending = false
    for p in wanted:
      if not p.done:
        readOutput(p)
        if not p.done: pending = true
    if pending and waited < 20_000: return
    cancel(check)
    var use: seq[Piece]
    for p in wanted:
      if p.done and not p.failed and p.frames > 0 and fileExists(p.path) and nowMs() - p.endMs <= keepMs + pieceMs:
        use.add p
    if use.len == 0:
      done("", 0, 0, 0, 0, "There's no replay yet: it starts once a page has been shown for a moment.")
      return
    let (w, h) = outSize(use[^1].width, use[^1].height)
    let output = getTempDir() / ("webby-replay-" & $getCurrentProcessId() & "-" & $nowMs() & ".webm")
    var args = @["--join", output, $w, $h]
    for p in use: args.add p.path
    var joiner: Process
    try: joiner = startProcess(tabrecPath(), args = args, options = {poStdErrToStdOut})
    except CatchableError as e:
      done("", 0, 0, 0, 0, "Couldn't join the replay: " & e.msg)
      return
    let job = Piece(process: joiner)
    var joinWait = 0
    var joinCheck: Timer
    joinCheck = every(100, proc () =
      joinWait += 100
      readOutput(job)
      if not job.done and joinWait < 120_000: return
      cancel(joinCheck)
      if job.done and not job.failed and fileExists(output):
        done(output, use[0].startMs, use[^1].endMs, w, h, "")
      else:
        if job.process != nil:
          try: job.process.terminate(); job.process.close() except CatchableError: discard
        done("", 0, 0, 0, 0, "Joining the replay failed: " & job.output.strip)))
