## Updates for the AppImage: when webby runs from webby-x86_64.AppImage ($APPIMAGE, set by the AppImage runtime),
## it looks at the rolling `appimage` release on the fileapi forge (nandi.uk/webby, built by .forge/jobs.toml with
## scripts/forge_appimage.py) half a minute after it starts and every 6 hours. A newer version is downloaded with
## zsync2 (bundled in the AppImage), which fetches only the blocks that changed and uses the current file for the
## rest, when the forge answers byte ranges; otherwise the whole file is downloaded. Then it replaces the AppImage
## file. This webby keeps running from its own mount; the new one starts next time, or now through
## ⋮ > Help > Restart to update. ⋮ > Help > Check for updates asks at once.
##
## Conda installs update with `pixi global update webby` (or `pixi install` in a checkout) instead. That replaces the
## engine's files under a webby that is still running: pages then open in helpers from the new version while
## the long-lived ones keep the old, which can't talk to each other reliably. webby notices the engine's files
## changing and asks to restart; ⋮ > Help > Restart to finish updating does the same.

import std/[json, os, strutils, times]
import ../browser
from ../ffi import ladybirdPrefix
from about import buildInfo
from nimkit/core as kit import nil
import nimkit/services
import updatebar, updatefetch
from nimkit/backend/gio_http import gioStream

const
  # -d:webbyUpdateApi=... tests against a local server (a JSON file with "name" and
  # "assets": [{"name", "download_url"}]).
  releaseApi {.strdefine: "webbyUpdateApi".} =
    "https://fileapi.fastapicloud.dev/api/forge/repos/nandi.uk/webby/releases/appimage"
  fileName = "webby-x86_64.AppImage"
  releasePage = "https://fileapi.fastapicloud.dev/forge/nandi.uk/webby/-/releases"
  checkEveryMs = 6 * 60 * 60 * 1000

type State = enum idle, checking, downloading, ready

var
  state = idle
  newVersion = ""      ## the version being downloaded, or downloaded
  manualCheck = false  ## say how a check went (from the menu), not only when there's something new

proc g_spawn_async(dir: cstring, argv, envp: cstringArray, flags: cint, setup, data: pointer, pid: ptr cint,
  err: pointer): cint {.importc, cdecl.}
proc g_child_watch_add(pid: cint, fn, data: pointer): cuint {.importc, cdecl.}
proc g_spawn_close_pid(pid: cint) {.importc, cdecl.}

proc newer(a, b: string): bool =
  ## Whether version `a` (e.g. 2026.10.24.483) comes after `b`, comparing the numbers part by part.
  let x = a.split('.')
  let y = b.split('.')
  for i in 0 ..< max(x.len, y.len):
    let p = (if i < x.len: (try: parseInt(x[i]) except ValueError: -1) else: 0)
    let q = (if i < y.len: (try: parseInt(y[i]) except ValueError: -1) else: 0)
    if p != q: return p > q

proc spawn(args: seq[string], onExit: proc (ok: bool)): bool =
  var exitHook {.global.}: proc (ok: bool)
  exitHook = onExit
  let argv = allocCStringArray(args)
  var pid: cint
  # G_SPAWN_DO_NOT_REAP_CHILD (2), so the child watch gets its exit status.
  result = g_spawn_async(nil, argv, nil, 2, nil, nil, addr pid, nil) != 0
  deallocCStringArray(argv)
  if result:
    discard g_child_watch_add(pid, proc (pid, status: cint, d: pointer) {.cdecl.} =
      g_spawn_close_pid(pid)
      let hook = exitHook
      shielded("update", proc () = hook(status == 0)), nil)

proc restart()

proc download(version, fileAsset, zsyncAsset: string) =
  let appImage = getEnv("APPIMAGE")
  let zsync2 = getAppDir() / "zsync2" / "bin" / "zsync2"
  if not fileExists(zsync2): return
  let dir = appImage.parentDir
  # The new file is built next to the AppImage, then renamed over it (the running one keeps its open copy).
  let part = dir / "." & appImage.extractFilename & ".update"
  let zsyncFile = part & ".zsync"
  try:
    writeFile(part, "")
    removeFile(part)
  except CatchableError:
    # The folder isn't writable (e.g. /opt): only say there is a newer version.
    kit.toast("Webby " & version & " is out. It can't update itself from " & dir & ".")
    if manualCheck: discard openTab(releasePage)
    return
  state = downloading
  newVersion = version
  let downloadingText = "Downloading Webby " & version
  updatebar.show(downloadingText & "…", reopen = true)
  # zsync2's progress ("\r####------ 43.2%") goes to this file, which the bar reads twice a second.
  let progressLog = part & ".log"
  var poll: Timer
  proc stopPolling() =
    cancel(poll)
    try: removeFile(progressLog) except CatchableError: discard
  proc failed(why: string) =
    log("webby: could not download " & version & ": " & why)
    state = idle
    stopPolling()
    updatebar.hide()
    for f in [part, zsyncFile]:
      try: removeFile(f) except CatchableError: discard
    if manualCheck: kit.toast("Could not download Webby " & version)
  proc finished(ok: bool) =
    stopPolling()
    try: removeFile(zsyncFile) except CatchableError: discard
    if not ok or not fileExists(part): (failed("zsync2 failed"); return)
    try:
      setFilePermissions(part, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
                                fpOthersExec})
      moveFile(part, appImage)
    except CatchableError as e:
      state = idle
      updatebar.hide()
      kit.toast("Could not update Webby: " & e.msg)
      return
    state = ready
    log("webby: updated " & appImage & " to " & version)
    updatebar.show("Webby " & version & " is ready. It starts next time you open Webby.", buttonText = "Restart",
      onButton = restart, reopen = true)
  proc zsync(fileUrl: string) =
    # Not -q, so it prints its progress; sh sends that to the log.
    let args = @["/bin/sh", "-c", "log=$1; shift; exec \"$@\" >\"$log\" 2>&1", "sh", progressLog,
                 zsync2, "-i", appImage, "-o", part, "-u", fileUrl, zsyncFile]
    if not spawn(args, finished):
      failed("could not start zsync2")
      return
    poll = every(500, proc () =
      let fraction = try: lastPercent(readFile(progressLog)) except CatchableError: -1.0
      if state == downloading and fraction >= 0: updatebar.show(downloadingText, fraction))
  proc whole(fileUrl: string) =
    ## The forge doesn't answer byte ranges (zsync2 needs them): the whole file, straight to `part`.
    var f: File
    if not open(f, part, fmWrite): (failed("can't write " & part); return)
    var size, got = 0'i64
    var shown = -1
    gioStream(fileUrl, @[], proc (r: Response): bool =
      size = (try: parseBiggestInt(r.header("content-length")) except ValueError: 0)
      r.status == 200,
    proc (data: string) =
      try: f.write(data)
      except IOError: discard
      got += data.len
      if size > 0:
        let permille = int(got * 1000 div size)
        if permille != shown:
          shown = permille
          updatebar.show(downloadingText, permille / 1000),
    proc (r: Response) =
      f.close()
      if r.status != 200 or r.error.len > 0 or (size > 0 and got != size):
        failed("file: " & $r.status & " " & r.error & " (" & $got & " of " & $size & " bytes)")
      else: finished(true))
  # The .zsync (block checksums of the new file), then whether the file's address answers a byte range.
  getRetrying(zsyncAsset, @[], proc (r: Response) =
    if r.status != 200: (failed("zsync file: " & $r.status & " " & r.error); return)
    try: writeFile(zsyncFile, r.body)
    except CatchableError as e: (failed(e.msg); return)
    var ranges = false
    gioStream(fileAsset, @[("Range", "bytes=0-0")], proc (r: Response): bool =
      ranges = r.status == 206
      false,
    proc (data: string) = discard,
    proc (r: Response) =
      if r.status == 0: (failed("file: " & r.error); return)
      if ranges: zsync(fileAsset) else: whole(fileAsset)))

proc check(manual = false) =
  if state in {checking, downloading}: return
  if state == ready:
    if manual: kit.toast("Webby " & newVersion & " is ready: ⋮ > Help > Restart to update")
    return
  manualCheck = manual
  state = checking
  let current = buildInfo().version
  getRetrying(releaseApi, @[], proc (r: Response) =
    state = idle
    if r.status != 200:
      log("webby: update check failed: " & $r.status & " " & r.error)
      if manualCheck: kit.toast("Could not check for updates (" & failureText(r) & ")")
      return
    var latest, fileAsset, zsyncAsset = ""
    try:
      let release = parseJson(r.body)
      # The title is "webby AppImage <version>".
      for word in release{"name"}.getStr.splitWhitespace:
        if word.len > 0 and word[0] in Digits: latest = word
      for a in release{"assets"}.getElems:
        if a{"name"}.getStr == fileName: fileAsset = a{"download_url"}.getStr
        elif a{"name"}.getStr == fileName & ".zsync": zsyncAsset = a{"download_url"}.getStr
    except CatchableError: discard
    log("webby: update check: latest " & latest & ", this is " & current)
    if latest.len == 0 or fileAsset.len == 0 or zsyncAsset.len == 0 or not newer(latest, current):
      if manualCheck: kit.toast("Webby is up to date (" & current & ")")
      return
    download(latest, fileAsset, zsyncAsset))

proc restart() =
  ## Quits (the quit hooks save the tabs, which the new one opens), then starts the AppImage again.
  let appImage = getEnv("APPIMAGE")
  shutdownHooks.add proc () =
    # A moment's wait, so this webby's helpers are gone before the new one starts on the same profile.
    discard spawn(@["/bin/sh", "-c", "sleep 1; exec \"$0\"", appImage], proc (ok: bool) = discard)
  browser.quit()

type FileId = tuple[dev: int64, ino: int64, mtime: int64]

proc fileId(path: string): FileId =
  try:
    let info = getFileInfo(path)
    (int64(info.id.device), int64(info.id.file), info.lastWriteTime.toUnix)
  except OSError: (0'i64, 0'i64, 0'i64)

var
  engineFiles: seq[(string, FileId)]  ## the engine files as they were at start
  engineChanged = false

proc restartSelf() =
  ## Quits (the quit hooks save the tabs, which the new one opens), then starts this program again with the same
  ## options (--incognito, --app=...; not the URLs, whose tabs come back anyway) and environment (the conda
  ## launcher's settings are already in it).
  var args = @["/bin/sh", "-c", "sleep 1; exec \"$0\" \"$@\"", getAppFilename()]
  for a in commandLineParams():
    if a.startsWith("--"): args.add a
  shutdownHooks.add proc () = discard spawn(args, proc (ok: bool) = discard)
  browser.quit()

proc checkEngine() =
  if engineChanged: return
  for (path, id) in engineFiles:
    if fileId(path) != id:
      engineChanged = true
      kit.confirm("Webby was updated",
        "Its engine changed on disk while it was running. Pages can misbehave until it restarts. " &
        "Your tabs come back.", ok = "Restart",
        onResult = proc (ok: bool) = (if ok: restartSelf()))
      return

proc watchEngine() =
  let prefix = ladybirdPrefix()
  for rel in ["lib/libwebby.so", "libexec/WebContent"]:
    let path = prefix / rel
    if fileExists(path): engineFiles.add((path, fileId(path)))
  if engineFiles.len == 0: return
  windowHooks.add proc () =
    addMenuHook(mgHelp, proc (items: var seq[kit.MenuItem]) =
      if engineChanged: items.add kit.menuItem("Restart to finish updating", restartSelf))
  startupHooks.add proc () =
    discard every(60_000, checkEngine)

proc install*() =
  # An AppImage's engine sits in its own mount, which an update leaves alone.
  if getEnv("APPIMAGE").len == 0: watchEngine()
  if getEnv("APPIMAGE").len == 0 or appUrl.len > 0 or incognito: return
  windowHooks.add proc () =
    addMenuHook(mgHelp, proc (items: var seq[kit.MenuItem]) =
      if state == ready:
        items.add kit.menuItem("Restart to update to " & newVersion, restart)
      else:
        items.add kit.menuItem("Check for updates", proc () = check(manual = true)))
  startupHooks.add proc () =
    discard after(30_000, proc () = check())
    discard every(checkEveryMs, proc () = check())
