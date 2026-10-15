## webby on Android (nim/android-kit): the platform services the desktop gets from GTK, D-Bus and libsecret, from
## the app's Java host instead (WebbyHost.onHostCall, Services.java): the password vault's key in the Android
## Keystore, streamed HTTP for summaries, the device's name for sync, and pages following the system's dark theme.

import std/[base64, json, os, strutils, tables]
import ../browser
import passwords/keyring
import site/permstore
import tabs/store as tabStore

proc migrateJavaShellTabs() =
  ## This app replaced the Java-shell Webby Nim under its app id (nim/android-kit/AndroidManifest.xml). Everything
  ## else of that app's profile was already in this one's place (both kept it under XDG_DATA_HOME); only its open
  ## tabs were its own: files/profile/nim-android-tabs.json, {"tabs": [url...], "active": n, "pinned": n}.
  let prefix = getEnv("WEBBY_LADYBIRD_PREFIX")
  if prefix.len == 0 or incognito: return
  let old = prefix.parentDir / "profile" / "nim-android-tabs.json"
  if not fileExists(old): return
  let j = readJsonFile(old)
  if j != nil and j.kind == JObject and not fileExists(openTabsFile()):
    var tabs: seq[DeviceTab]
    for u in j{"tabs"}.getElems:
      if u.kind == JString and u.getStr.len > 0: tabs.add DeviceTab(title: u.getStr, url: u.getStr)
    if tabs.len > 0:
      try: createDir(openTabsFile().parentDir) except OSError: discard
      writeOpenTabs(tabs, clamp(j{"active"}.getInt, 0, tabs.high), clamp(j{"pinned"}.getInt, 0, tabs.len))
  try: moveFile(old, old & ".migrated") except OSError: discard

# Pages follow the system's light or dark theme (as site/colorscheme.nim follows the desktop's).

var scheme = colorSchemeLight

proc applyScheme(t: Tab) =
  if not t.closed and t.view != nil: webby_view_set_color_scheme(t.view, scheme.cint)

proc setScheme(name: string) =
  let s = if name == "dark": colorSchemeDark else: colorSchemeLight
  if s == scheme: return
  scheme = s
  for t in tabs: applyScheme(t)
  wake()

proc onTabState(t: Tab) =
  # A cross-site navigation can swap the page's WebContent process, which starts from Ladybird's default.
  let origin = originOf(t.url)
  if t.props.getOrDefault("android.schemeOrigin") != origin:
    t.props["android.schemeOrigin"] = origin
    applyScheme(t)

type Stream = object
  onStatus: proc (status: int)
  onData: proc (data: string)
  onDone: proc (error: string)

var
  streams: Table[int, Stream]
  nextStream = 1

proc startStream(meth, url: string, headers: seq[(string, string)], body: string, onStatus: proc (status: int),
                 onData: proc (data: string), onDone: proc (error: string)): int =
  let id = nextStream
  inc nextStream
  streams[id] = Stream(onStatus: onStatus, onData: onData, onDone: onDone)
  var hs = newJArray()
  for (k, v) in headers: hs.add %*[k, v]
  if hostCall("httpStream", $(%*{"id": id, "method": meth, "url": url, "headers": hs, "body": encode(body)})) != "ok":
    streams.del id
    discard after(0, proc () = onDone("No network here"))
  id

proc cancelStream(id: int) =
  if id in streams:
    streams.del id
    discard hostCall("httpStreamCancel", $id)

proc onHostEvent(name, data: string) =
  if name == "colorScheme": setScheme(data)
  if not name.startsWith("httpStream."): return
  var j: JsonNode
  try: j = parseJson(data) except CatchableError: return
  let id = j{"id"}.getInt
  if id notin streams: return
  let s = streams[id]
  case name
  of "httpStream.status":
    if s.onStatus != nil: s.onStatus(j{"status"}.getInt)
  of "httpStream.data":
    var piece = ""
    try: piece = decode(j{"data"}.getStr) except CatchableError: discard
    if s.onData != nil: s.onData(piece)
  of "httpStream.done":
    streams.del id
    if s.onDone != nil: s.onDone(j{"error"}.getStr)
  else: discard

proc install*() =
  androidKeyring.lookup = proc (profile: string): (bool, string) =
    let r = hostCall("keystoreGet", profile)
    if not r.startsWith("key:"): raise newException(KeyringError, "the Android keystore failed")
    (r.len > 4, r[4 .. ^1])
  androidKeyring.store = proc (profile, secret: string) =
    if hostCall("keystorePut", $(%*{"profile": profile, "secret": secret})) != "ok":
      raise newException(KeyringError, "the Android keystore failed")
  httpStream = startStream
  httpStreamCancel = cancelStream
  hostEventHooks.add onHostEvent
  startupHooks.add proc () =
    migrateJavaShellTabs()
    deviceDescription = hostCall("device")
    setScheme(hostCall("colorScheme"))
  tabCreatedHooks.add applyScheme
  viewCreatedHooks.add applyScheme
  tabStateHooks.add onTabState
