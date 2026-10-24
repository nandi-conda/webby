## Updates for the AppImage: when webby runs from webby-x86_64.AppImage ($APPIMAGE, set by the AppImage runtime),
## it looks at the rolling `appimage` GitHub release (scripts/build_appimage.sh, .github/workflows/publish.yml)
## half a minute after it starts and every 6 hours. A newer version is downloaded with zsync2 (bundled in the
## AppImage), which fetches only the blocks that changed and uses the current file for the rest, then it replaces
## the AppImage file. This webby keeps running from its own mount; the new one starts next time, or now through
## ⋮ > Help > Restart to update. ⋮ > Help > Check for updates asks at once.
##
## Conda installs update with `pixi global update webby` instead, so this does nothing there.

import std/[json, os, strutils]
import ../browser
from about import buildInfo
from nimkit/core as kit import nil
import nimkit/services

const
  releaseApi = "https://api.github.com/repos/nandi-conda/webby/releases/tags/appimage"
  releasePage = "https://github.com/nandi-conda/webby/releases/tag/appimage"
  zsyncUrl = "https://github.com/nandi-conda/webby/releases/download/appimage/webby-x86_64.AppImage.zsync"
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

proc download(version: string) =
  let appImage = getEnv("APPIMAGE")
  let zsync2 = getAppDir() / "zsync2" / "bin" / "zsync2"
  if not fileExists(zsync2): return
  let dir = appImage.parentDir
  # The new file is built next to the AppImage, then renamed over it (the running one keeps its open copy).
  let part = dir / "." & appImage.extractFilename & ".update"
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
  if manualCheck: kit.toast("Downloading Webby " & version & "…")
  let ok = spawn(@[zsync2, "-q", "-i", appImage, "-o", part, zsyncUrl], proc (ok: bool) =
    if not ok or not fileExists(part):
      state = idle
      try: removeFile(part) except CatchableError: discard
      if manualCheck: kit.toast("Could not download Webby " & version)
      return
    try:
      setFilePermissions(part, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
                                fpOthersExec})
      moveFile(part, appImage)
    except CatchableError as e:
      state = idle
      kit.toast("Could not update Webby: " & e.msg)
      return
    state = ready
    kit.toast("Webby " & version & " is ready. It starts next time, or now with ⋮ > Help > Restart to update."))
  if not ok:
    state = idle
    if manualCheck: kit.toast("Could not start the download")

proc check(manual = false) =
  if state in {checking, downloading}: return
  if state == ready:
    if manual: kit.toast("Webby " & newVersion & " is ready: ⋮ > Help > Restart to update")
    return
  manualCheck = manual
  state = checking
  let current = buildInfo().version
  request("GET", releaseApi, proc (r: Response) =
    state = idle
    if r.status != 200:
      if manualCheck: kit.toast("Could not check for updates (" & (if r.error.len > 0: r.error else: $r.status) & ")")
      return
    var latest = ""
    try: latest = parseJson(r.body){"name"}.getStr.strip
    except CatchableError: discard
    if latest.len == 0 or not newer(latest, current):
      if manualCheck: kit.toast("Webby is up to date (" & current & ")")
      return
    download(latest),
    headers = @[("Accept", "application/vnd.github+json")])

proc restart() =
  ## Quits (the quit hooks save the tabs, which the new one opens), then starts the AppImage again.
  let appImage = getEnv("APPIMAGE")
  shutdownHooks.add proc () =
    # A moment's wait, so this webby's helpers are gone before the new one starts on the same profile.
    discard spawn(@["/bin/sh", "-c", "sleep 1; exec \"$0\"", appImage], proc (ok: bool) = discard)
  browser.quit()

proc install*() =
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
