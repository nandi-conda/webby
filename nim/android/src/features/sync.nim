## Sync and tabs from other devices on Android (src/features/sync.nim on the desktop): the same engine
## (features/sync/engine.nim) keeps the vault, bookmarks, open tabs, summaries and sessions in sync, over HTTP done by
## Java (features/net.nim). Java's Sync and "Tabs from other devices" screens read "sync.state" / "devices.list" and
## refresh on "syncStatus" events.

import std/[strutils, times, uri]
import ../core
import ../../../src/features/passwords/manager
import ../../../src/features/sync/[keys, blobs, engine, devicetabs]

proc ago(seconds: int64): string =
  let d = getTime().toUnix - seconds
  if d < 60: "just now"
  elif d < 3600: $(d div 60) & " min ago"
  elif d < 86400: $(d div 3600) & " h ago"
  else: $(d div 86400) & " days ago"

proc validServer(text: string): bool =
  try:
    let u = parseUri(text)
    u.scheme in ["http", "https"] and u.hostname.len > 0
  except CatchableError: false

proc state(args: JsonNode): JsonNode =
  if theVault == nil:
    return %*{"vaultError": (if vaultError.len > 0: vaultError else: "Opening the vault…"), "on": false}
  let s = settings()
  if s == nil: return %*{"on": false}
  let where = if s.isWebdav: "WebDAV folder " & s.server
              elif s.server == defaultSyncServer: "the webby sync server" else: s.server
  let last = s{"lastSync"}
  let status = if syncing(): "Syncing with " & where & "…"
               else: "Synced with " & where & " " &
                 (if last == nil or last.kind != JInt: "not yet" else: ago(last.getBiggestInt)) & "."
  let link = s.pairingLink
  %*{"on": true, "syncing": syncing(), "status": status, "lastError": lastError(), "code": s.code,
    "pairingLink": (if link != "webby-sync:pair?code=" & s.code: link else: ""), "webdav": s.isWebdav}

proc turnOn(args: JsonNode): JsonNode =
  ## {join, code, storage: "webby" | "custom" | "webdav", server, username, password} -> {error}
  var code = ""
  if args{"join"}.getBool:
    try: code = fromPairing(args{"code"}.getStr).code.normalizeCode
    except BadSyncCode as e: return %*{"error": e.msg}
    except CatchableError: return %*{"error": "That isn't a sync code."}
  else: code = generateCode()
  let storage = args{"storage"}.getStr
  let isDav = storage == "webdav"
  let address = args{"server"}.getStr.strip
  if storage != "webby" and not validServer(address):
    return %*{"error": "Enter the server's address, like https://cloud.example.com/remote.php/dav/files/me/webby"}
  let s = newSettings(code, webdav = isDav, server = if storage == "webby": defaultSyncServer else: address,
    username = if isDav: args{"username"}.getStr else: "", password = if isDav: args{"password"}.getStr else: "")
  try: enable(s)
  except CatchableError as e: return %*{"error": e.msg}
  %*{"error": ""}

proc parsePairing(args: JsonNode): JsonNode =
  ## Where a pasted pairing link says to sync: {storage, server}, or null.
  let t = args{"text"}.getStr.strip
  if not t.startsWith("webby-sync:"): return newJNull()
  try:
    let s = fromPairing(t)
    if s.isWebdav: %*{"storage": "webdav", "server": s.server}
    elif s.server != defaultSyncServer: %*{"storage": "custom", "server": s.server}
    else: %*{"storage": "webby", "server": ""}
  except CatchableError: newJNull()

proc turnOff(args: JsonNode): JsonNode =
  disable(args{"erase"}.getBool, proc (error: string) =
    event("syncStatus", %*{"error": error}))
  nil

proc devicesList(args: JsonNode): JsonNode =
  var list = newJArray()
  for d in devices():
    var ts = newJArray()
    for t in d.tabs: ts.add %*{"title": t.title, "url": t.url}
    list.add %*{"name": d.name, "platform": d.platform, "seen": ago(d.seenAt), "tabs": ts}
  %*{"on": enabled(), "syncing": syncing(), "lastError": lastError(), "devices": list, "name": deviceName(),
    "sharing": sharing(), "shared": sharedTabs().len}

proc publishTabs() =
  var list: seq[DeviceTab]
  for t in tabs:
    if not t.closed and t.url != homePage: list.add (t.title, t.url)
  setTabs(list)

proc install*() =
  if incognito: return
  startupHooks.add proc () =
    deviceDescription = callJava("deviceModel", "")[1]
    statusListeners.add proc () = event("syncStatus")
    deviceListeners.add proc () = event("syncStatus")
    engine.start()
  tabStateHooks.add proc (t: Tab) = publishTabs()
  tabClosedHooks.add proc (t: Tab) = discard startTimer(0, publishTabs)
  commands["sync.state"] = state
  commands["sync.turnOn"] = turnOn
  commands["sync.parsePairing"] = parsePairing
  commands["sync.off"] = turnOff
  commands["sync.now"] = proc (args: JsonNode): JsonNode = (syncNow(); nil)
  commands["devices.list"] = devicesList
  commands["devices.rename"] = proc (args: JsonNode): JsonNode = (setDeviceName(args{"name"}.getStr); nil)
  commands["devices.share"] = proc (args: JsonNode): JsonNode = (setSharing(args{"on"}.getBool); nil)
