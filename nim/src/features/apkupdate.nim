## Updates for webby on Android. CI (.github/workflows/nim-android-apk.yml) publishes every build as the GitHub
## prerelease webby-nim-android-<version> with webby-nim-android-arm64.apk and its .sha256, all signed with the same
## key (nim/android-kit/debug.keystore), so each one installs over the last.
##
## Half a minute after it starts, and every 6 hours, webby looks for the newest such release. When it is newer than
## this build (about.buildInfo's version, the APK's version name) it asks once per version whether to update;
## ⋮ > Help > Check for updates asks at once. Updating hands the release's asset links to the Java host
## (Updater.java), which downloads and checks the APK and gives it to Android's package installer; Android asks the
## user to confirm, then replaces the app (the open tabs come back as after any restart).

import std/[json, strutils]
import ../browser
from about import buildInfo
from nimkit/core as kit import nil
import nimkit/services

const
  releasesApi {.strdefine: "webbyAndroidReleasesApi".} =
    "https://api.github.com/repos/nandi-conda/webby/releases?per_page=50"
  tagPrefix = "webby-nim-android-"
  apkName = "webby-nim-android-arm64.apk"
  checkEveryMs = 6 * 60 * 60 * 1000
  dismissedKey = "update-dismissed"   ## the version the user said "Later" to: not asked about again

type State = enum idle, checking, available, downloading, installing

var
  state = idle
  latest = ""          ## the newer version found
  apkUrl, shaUrl = ""
  apkSize = 0
  percent = -1
  manualCheck = false

proc newer(a, b: string): bool =
  ## Whether version `a` (e.g. 2026.11.2.160) comes after `b`, comparing the numbers part by part. A local build's
  ## version ("local build", "0.1") loses to any release.
  let x = a.split('.')
  let y = b.split('.')
  for i in 0 ..< max(x.len, y.len):
    let p = (if i < x.len: (try: parseInt(x[i]) except ValueError: -1) else: 0)
    let q = (if i < y.len: (try: parseInt(y[i]) except ValueError: -1) else: 0)
    if p != q: return p > q

proc startUpdate() =
  if state in {downloading, installing}: return
  let r = hostCall("updateInstall", $(%*{"version": latest, "apk": apkUrl, "sha256": shaUrl}))
  case r
  of "ok", "busy":
    state = downloading
    percent = -1
    kit.toast("Downloading Webby " & latest & "…")
  of "permission": discard   # update.permission says what to do; it carries on from onResume
  else: kit.toast("Could not start the update")

proc offer() =
  let size = if apkSize > 0: " (" & $(apkSize div (1024 * 1024)) & " MB)" else: ""
  kit.confirm("Webby " & latest & " is available",
    "This is " & buildInfo().version & ". Download the new version" & size & " and install it?",
    ok = "Update", onResult = proc (ok: bool) =
      if ok: startUpdate()
      else: store(dismissedKey, latest))

proc check(manual = false) =
  if state in {checking, downloading, installing}:
    if manual and state == downloading:
      kit.toast("Downloading Webby " & latest & (if percent >= 0: " (" & $percent & "%)" else: "…"))
    return
  manualCheck = manual
  state = checking
  let current = buildInfo().version
  request("GET", releasesApi, proc (r: Response) =
    state = idle
    if r.status != 200:
      log("webby: update check failed: " & $r.status & " " & r.error)
      if manualCheck: kit.toast("Could not check for updates (" & (if r.error.len > 0: r.error else: $r.status) & ")")
      return
    var version, apk, sha = ""
    var size = 0
    try:
      for rel in parseJson(r.body).getElems:
        let tag = rel{"tag_name"}.getStr
        if rel{"draft"}.getBool or not tag.startsWith(tagPrefix): continue
        for a in rel{"assets"}.getElems:
          if a{"name"}.getStr == apkName:
            apk = a{"browser_download_url"}.getStr
            size = a{"size"}.getInt
          elif a{"name"}.getStr == apkName & ".sha256": sha = a{"browser_download_url"}.getStr
        if apk.len > 0:
          version = tag[tagPrefix.len .. ^1]
          break
        sha = ""
    except CatchableError: discard
    log("webby: update check: latest " & version & ", this is " & current)
    if version.len == 0 or not newer(version, current):
      if manualCheck: kit.toast("Webby is up to date (" & current & ")")
      return
    latest = version
    apkUrl = apk
    shaUrl = sha
    apkSize = size
    state = available
    if manualCheck: offer()
    elif load(dismissedKey) != version: offer(),
    headers = @[("Accept", "application/vnd.github+json")])

proc onHostEvent(name, data: string) =
  case name
  of "update.progress":
    percent = (try: parseInt(data) except ValueError: -1)
  of "update.permission":
    kit.toast("Allow Webby to install apps, then come back to finish the update")
  of "update.installing":
    state = installing
  of "update.failed":
    state = if latest.len > 0: available else: idle
    kit.toast("Could not update Webby: " & data)
  else: discard

proc install*() =
  if incognito: return   # the incognito window's own process; the main one does this
  hostEventHooks.add onHostEvent
  windowHooks.add proc () =
    addMenuHook(mgHelp, proc (items: var seq[kit.MenuItem]) =
      case state
      of available: items.add kit.menuItem("Update to " & latest, startUpdate)
      of downloading:
        items.add kit.menuItem("Downloading update" & (if percent >= 0: " (" & $percent & "%)" else: "…"),
          proc () = check(manual = true))
      of installing: items.add kit.menuItem("Installing update…", proc () = discard)
      else: items.add kit.menuItem("Check for updates", proc () = check(manual = true)))
  startupHooks.add proc () =
    discard after(30_000, proc () = check())
    discard every(checkEveryMs, proc () = check())
