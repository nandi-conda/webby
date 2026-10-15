## Installed web apps (app/lib/src/pwa/app_store.dart): one folder per app under ${XDG_DATA_HOME}/webby/apps/
## (app.json and the icon) and a dev.webby.WebApp-<slug>.desktop launcher in ${XDG_DATA_HOME}/applications/ that
## runs `webby --app=<url>`.

import std/[algorithm, base64, json, os, strutils, uri]
import ../../browser
import manifest

type InstalledApp* = object
  slug*, id*, name*, startUrl*, scope*, manifestUrl*, iconPath*, themeColor*, description*: string

proc inScope*(app: InstalledApp, url: string): bool = manifest.inScope(app.scope, url)

proc toJson(app: InstalledApp): JsonNode =
  result = %*{"id": app.id, "name": app.name, "startUrl": app.startUrl, "scope": app.scope,
    "manifestUrl": app.manifestUrl}
  if app.iconPath.len > 0: result["icon"] = %app.iconPath
  if app.themeColor.len > 0: result["themeColor"] = %app.themeColor
  if app.description.len > 0: result["description"] = %app.description

proc fromJson(slug: string, j: JsonNode): (bool, InstalledApp) =
  if j == nil or j.kind != JObject or not isKind(j{"id"}, JString) or not isKind(j{"startUrl"}, JString): return
  let start = j["startUrl"].getStr
  (true, InstalledApp(slug: slug, id: j["id"].getStr, name: j{"name"}.getStr, startUrl: start,
    scope: j{"scope"}.getStr(start), manifestUrl: j{"manifestUrl"}.getStr, iconPath: j{"icon"}.getStr,
    themeColor: j{"themeColor"}.getStr, description: j{"description"}.getStr))

proc appsDir*(): string = dataHome() / "webby" / "apps"
proc applicationsDir*(): string = dataHome() / "applications"

proc appIdFor*(slug: string): string =
  ## The app's own application id: its window's Wayland app id and X11 WM_CLASS, so docks show it apart from webby.
  "dev.webby.WebApp-" & slug

proc desktopFile*(slug: string): string = applicationsDir() / appIdFor(slug) & ".desktop"

proc slugFor*(id: string): string =
  ## A file-name-safe key for an app id: its host plus a 32-bit FNV-1a hash of the whole id.
  var host = ""
  try:
    for c in parseUri(id).hostname.toLowerAscii:
      if c in {'a'..'z', '0'..'9'}: host.add c
      elif not host.endsWith('-'): host.add '-'
  except CatchableError: discard
  var hash = 0x811c9dc5'u32
  for c in id:
    hash = (hash xor uint32(ord(c))) * 0x01000193'u32
  (if host.len == 0: "app" else: host) & "-" & toHex(BiggestInt(hash), 8).toLowerAscii

proc apps*(): seq[InstalledApp] =
  if not dirExists(appsDir()): return
  for kind, dir in walkDir(appsDir()):
    if kind notin {pcDir, pcLinkToDir}: continue
    let (ok, app) = fromJson(dir.lastPathPart, readJsonFile(dir / "app.json"))
    if ok: result.add app
  result.sort(proc (a, b: InstalledApp): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))

proc byId*(id: string): (bool, InstalledApp) =
  let slug = slugFor(id)
  for app in apps():
    if app.slug == slug: return (true, app)

proc forUrl*(url: string): (bool, InstalledApp) =
  ## The installed app whose start URL is `url` (how --app=<url> finds its scope), else one whose scope has it.
  let all = apps()
  for app in all:
    if app.startUrl == url: return (true, app)
  for app in all:
    if app.inScope(url) and (not result[0] or app.scope.len > result[1].scope.len): result = (true, app)

# ---------------------------------------------------------------------------------------------------------------
# Starting webby

proc launchCommand*(): seq[string] =
  ## The conda bin/webby wrapper when there is one, else this executable with the Ladybird prefix it runs with.
  let exe = getAppFilename()
  let wrapper = exe.parentDir.parentDir.parentDir / "bin" / "webby"
  if exe.parentDir.endsWith("/lib/webby") and fileExists(wrapper): return @[wrapper]
  let prefix = getEnv("WEBBY_LADYBIRD_PREFIX")
  if prefix.len > 0: result = @["env", "WEBBY_LADYBIRD_PREFIX=" & prefix]
  result.add exe

proc windowEnvironment*(app: InstalledApp): seq[(string, string)] =
  ## What the app's window needs to look like the app: its id, name and icon.
  result = @[("WEBBY_APP_ID", appIdFor(app.slug)), ("WEBBY_APP_NAME", app.name)]
  if app.iconPath.len > 0: result.add ("WEBBY_APP_ICON", app.iconPath)

when defined(android):
  proc spawn(args: seq[string], extra: seq[(string, string)] = @[]) = discard   # no other processes to start

else:
  proc g_spawn_async(dir: cstring, argv, envp: cstringArray, flags: cint, setup, data: pointer, pid: pointer,
    err: ptr pointer): cint {.importc, cdecl.}
  proc g_error_free(e: pointer) {.importc, cdecl.}

  proc spawn(args: seq[string], extra: seq[(string, string)] = @[]) =
    ## Starts webby detached, with this environment minus the app-window variables plus `extra`.
    var env: seq[string]
    for k, v in envPairs():
      if not k.startsWith("WEBBY_APP_"): env.add k & "=" & v
    for (k, v) in extra: env.add k & "=" & v
    let argv = allocCStringArray(args)
    let envp = allocCStringArray(env)
    var err: pointer
    if g_spawn_async(nil, argv, envp, 4.cint, nil, nil, nil, addr err) == 0 and err != nil:   # G_SPAWN_SEARCH_PATH
      stderr.writeLine "webby: could not start ", args.join(" ")
      g_error_free(err)
    deallocCStringArray(argv)
    deallocCStringArray(envp)

proc launch*(app: InstalledApp) =
  ## Starts `app` in its own window. On Android: asks the home screen to pin a shortcut that opens it in webby.
  when defined(android):
    var icon = ""
    if app.iconPath.endsWith(".png"):
      try: icon = encode(readFile(app.iconPath)) except CatchableError: discard
    discard hostCall("pinApp", $(%*{"name": app.name, "url": app.startUrl, "id": app.slug, "icon": icon,
      "color": app.themeColor}))
  else:
    spawn(launchCommand() & @["--app=" & app.startUrl], windowEnvironment(app))

proc openInBrowser*(url: string) =
  ## Opens `url` in a normal browser window.
  spawn(launchCommand() & @[url])

# ---------------------------------------------------------------------------------------------------------------
# Launchers

proc escape(value: string): string =
  value.multiReplace(("\\", "\\\\"), ("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t"))

proc quoteExecArg(arg: string): string =
  ## Reserved characters need double quotes, and `%` is doubled since it starts field codes.
  var a = arg.replace("%", "%%")
  if a.find(Whitespace + {'"', '\'', '\\', '>', '<', '~', '|', '&', ';', '$', '*', '?', '#', '(', ')', '`'}) >= 0:
    var q = "\""
    for c in a:
      if c in {'\\', '"', '`', '$'}: q.add '\\'
      q.add c
    a = q & "\""
  # The spec's string escaping turns each backslash into two once more.
  a.replace("\\", "\\\\")

proc desktopEntry*(app: InstalledApp, description = ""): string =
  ## The launcher for `app` (Desktop Entry spec 1.5).
  let command = launchCommand()
  var exec = @["env"]
  for (k, v) in windowEnvironment(app): exec.add k & "=" & v
  exec.add(if command[0] == "env": command[1 .. ^1] else: command)
  exec.add "--app=" & app.startUrl
  var lines = @["[Desktop Entry]", "Type=Application", "Version=1.5", "Name=" & escape(app.name)]
  if description.len > 0: lines.add "Comment=" & escape(description)
  var quoted: seq[string]
  for a in exec: quoted.add quoteExecArg(a)
  lines.add "Exec=" & quoted.join(" ")
  lines.add "Icon=" & (if app.iconPath.len > 0: app.iconPath else: "dev.webby.webby")
  lines.add ["Terminal=false", "Categories=Network;WebApps;", "StartupNotify=true",
    "StartupWMClass=" & appIdFor(app.slug), "X-Webby-App-Id=" & escape(app.id), ""]
  lines.join("\n")

proc refreshDesktopDatabase() =
  # Most desktops watch the folder anyway; this just makes it quicker where the tool exists.
  if findExe("update-desktop-database").len > 0: spawn(@["update-desktop-database", applicationsDir()])

proc writeDesktopFile(app: InstalledApp, description: string) =
  when defined(android): return   # launchers are home screen shortcuts there (launch)
  createDir(applicationsDir())
  let file = desktopFile(app.slug)
  let tmp = file & ".tmp"
  writeFile(tmp, desktopEntry(app, description))
  try: setFilePermissions(tmp, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
    fpOthersExec})
  except CatchableError: discard
  moveFile(tmp, file)
  let old = applicationsDir() / "webby-app-" & app.slug & ".desktop"
  if fileExists(old): removeFile(old)
  refreshDesktopDatabase()

proc refreshLaunchers*() =
  ## Rewrites every installed app's launcher, so launchers follow webby's install path and launcher format.
  for app in apps():
    try: writeDesktopFile(app, app.description)
    except CatchableError: discard

proc install*(m: Manifest, name: string, icon: tuple[bytes, ext: string]): InstalledApp =
  ## Installs `m` as `name` with its icon (PNG or SVG bytes; none when empty) and writes the launcher.
  let slug = slugFor(m.id)
  let dir = appsDir() / slug
  createDir(dir)
  var iconPath = ""
  if icon.bytes.len > 0:
    iconPath = dir / "icon." & icon.ext
    writeFile(iconPath, icon.bytes)
  result = InstalledApp(slug: slug, id: m.id, name: (if name.strip.len > 0: name.strip else: m.title),
    startUrl: m.startUrl, scope: m.scope, manifestUrl: m.manifestUrl, iconPath: iconPath, themeColor: m.themeColor,
    description: m.description)
  writeFile(dir / "app.json", result.toJson.pretty)
  writeDesktopFile(result, m.description)

proc uninstall*(app: InstalledApp) =
  # Launchers from before app ids were webby-app-<slug>.desktop.
  for launcher in [desktopFile(app.slug), applicationsDir() / "webby-app-" & app.slug & ".desktop"]:
    if fileExists(launcher): removeFile(launcher)
  removeDir(appsDir() / app.slug)
  refreshDesktopDatabase()
