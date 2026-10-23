## Sync for webby-nim (app/lib/src/passwords/sync and tabs/device_tabs*.dart): passwords, passkeys, never-save sites,
## bookmarks, open tabs, page summaries and saved sessions, end-to-end encrypted with a sync code and stored on the
## webby-sync server or a WebDAV folder, compatible with the Flutter app's devices. Two side panels: "Sync" (turn it
## on, join with a code, show the code) and "Tabs from other devices". Incognito and app windows never sync.
## The parts: sync/doc (merge), sync/keys (code and crypto), sync/http + sync/blobs (transport), sync/engine
## (scheduling), sync/devicetabs (device.json and the tabs blob).

import std/[strutils, times, uri]
import ../browser
import passwords/manager
from passwords/panel import panelActionHooks
from nimkit/core as kit import nil
import sync/[keys, blobs, engine, devicetabs]

type PanelKind = enum panelNone, panelSync, panelDevices

var
  shown = panelNone
  panelBody: kit.Widget   ## the box the open panel fills (rebuilt on every change)
  codeShown = false

proc refresh()

# ---------------------------------------------------------------------------------------------------------------
# Small pieces

proc text(s: string, dim = false, small = false): kit.Widget =
  result = kit.label(s)
  if dim: kit.addClass(result, "dim")
  if small: kit.addClass(result, "small")

proc heading(s: string): kit.Widget = kit.addClass(kit.label(s), "bold")

proc banner(message: string): kit.Widget = kit.addClass(kit.addClass(kit.label(message), "error"), "card")

proc buttonRow(buttons: varargs[kit.Widget]): kit.Widget =
  result = kit.row(buttons)
  result.spacing = 6

proc btn(label: string, action: proc (), suggested = false, flat = false): kit.Widget =
  result = kit.button(label, action)
  if suggested: kit.addClass(result, "suggested")
  if flat: kit.addClass(result, "flat")

proc gap(px: int): kit.Widget = kit.sized(kit.column(), 0, px)

proc ago(seconds: int64, yesterday = false): string =
  let d = getTime().toUnix - seconds
  if d < 60: "just now"
  elif d < 3600: $(d div 60) & " min ago"
  elif d < 86400: $(d div 3600) & " h ago"
  elif yesterday and d div 86400 == 1: "yesterday"
  else: $(d div 86400) & " days ago"

proc validServer(text: string): bool =
  try:
    let u = parseUri(text)
    u.scheme in ["http", "https"] and u.hostname.len > 0
  except CatchableError: false

# ---------------------------------------------------------------------------------------------------------------
# Setup dialog (_SetupDialog): where to sync and, when joining, the code. `onDone` gets the new settings.

proc setupDialog(join: bool, onDone: proc (s: JsonNode)) =
  let box = kit.column()
  box.spacing = 6
  discard kit.sized(box, 460)
  proc field(label: string): kit.Widget =
    kit.add(box, text(label))
    result = kit.entry()
    kit.add(box, result)
  var codeEntry: kit.Widget
  if join:
    codeEntry = field("Sync code from your other device (or the pairing link)")
    kit.`placeholder=`(codeEntry, "webby1-…")
  kit.add(box, text("Store the encrypted copy on"))
  let storage = kit.dropdown(@["Webby sync", "My sync server", "WebDAV"], 0)
  kit.add(box, buttonRow(storage))
  let serverLabel = text("")
  let server = kit.entry()
  let serverBox = kit.column(serverLabel, server)
  serverBox.spacing = 6
  kit.add(box, serverBox)
  let user = kit.entry()
  let pass = kit.entry()
  kit.`password=`(pass, true)
  let loginBox = kit.column(text("Username"), user, text("Password (an app password is best)"), pass)
  loginBox.spacing = 6
  kit.add(box, loginBox)
  let error = kit.addClass(text(""), "error")
  kit.add(box, error)

  let storageChanged = proc () =
    let isCustom = kit.selected(storage) == 1
    let isDav = kit.selected(storage) == 2
    kit.`visible=`(serverBox, isCustom or isDav)
    kit.`visible=`(loginBox, isDav)
    kit.`text=`(serverLabel, if isDav: "Folder address" else: "Server address (runs sync-server from the webby repo)")
    kit.`placeholder=`(server,
      if isDav: "https://cloud.example.com/remote.php/dav/files/me/webby" else: "https://sync.example.com")
  storage.onSelect = proc (i: int) = storageChanged()
  storageChanged()
  if join:
    # A pasted pairing link says where to sync; show that.
    codeEntry.onChange = proc (t: string) =
      if not t.strip.startsWith("webby-sync:"): return
      try:
        let s = fromPairing(t)
        if s.isWebdav:
          kit.`selected=`(storage, 2)
          kit.`text=`(server, s.server)
        elif s.server != defaultSyncServer:
          kit.`selected=`(storage, 1)
          kit.`text=`(server, s.server)
        storageChanged()
      except CatchableError: discard
  var d: kit.Dialog
  let fail = proc (msg: string) =
    kit.`text=`(error, msg)
    kit.showDialog(d)
  d = kit.dialog(if join: "Join sync" else: "Turn on sync", box, @["Cancel", if join: "Join" else: "Turn on"],
    proc (i: int) =
      if i != 1: return
      var code = ""
      if join:
        try: code = fromPairing(kit.text(codeEntry)).code.normalizeCode
        except BadSyncCode as e: (fail(e.msg); return)
        except CatchableError: (fail("That isn't a sync code."); return)
      else: code = generateCode()
      let isWebby = kit.selected(storage) == 0
      let isDav = kit.selected(storage) == 2
      let address = kit.text(server).strip
      if not isWebby and not validServer(address):
        fail("Enter the server's address, like https://cloud.example.com/remote.php/dav/files/me/webby")
        return
      onDone(newSettings(code, webdav = isDav, server = if isWebby: defaultSyncServer else: address,
        username = if isDav: kit.text(user) else: "", password = if isDav: kit.text(pass) else: "")))
  for e in [codeEntry, server, user, pass]:
    if e != nil: e.onSubmit = proc (t: string) = kit.dialogResult(d, 1)
  if join: kit.focus(codeEntry)

proc turnOn(join: bool) =
  setupDialog(join, proc (s: JsonNode) =
    try: enable(s)
    except CatchableError as e: kit.alert("Couldn't turn on sync", e.msg))

# ---------------------------------------------------------------------------------------------------------------
# The Sync panel (sync_page.dart)

proc showDevicesPanel*()

proc fillSyncOff(box: kit.Widget) =
  kit.add(box, heading("Keep your passwords, passkeys, bookmarks and tabs on all your devices"))
  kit.add(box, text("Webby encrypts them on this device with a sync code that only your devices know, " &
    "then stores the encrypted copy on a sync server or in your own WebDAV folder. Nobody without the code, the " &
    "server included, can read them.", dim = true))
  kit.add(box, gap(4))
  kit.add(box, buttonRow(btn("Turn on sync", proc () = turnOn(false), suggested = true),
    btn("I have a sync code", proc () = turnOn(true))))

proc fillSyncOn(box: kit.Widget, s: JsonNode) =
  let where = if s.isWebdav: "WebDAV folder " & s.server
              elif s.server == defaultSyncServer: "the webby sync server" else: s.server
  if lastError().len > 0: kit.add(box, banner("Sync isn't working: " & lastError()))
  let last = s{"lastSync"}
  let status = if syncing(): "Syncing with " & where & "…"
               else: "Synced with " & where & " " & (if last == nil or last.kind != JInt: "not yet" else: ago(last.getBiggestInt)) & "."
  let now = btn("Sync now", syncNow)
  kit.`enabled=`(now, not syncing())
  let row = buttonRow(kit.expand(text(status)), now)
  kit.add(box, row)
  kit.add(box, buttonRow(btn("Tabs from other devices", showDevicesPanel)))
  kit.add(box, kit.separator())
  kit.add(box, heading("Add another device"))
  kit.add(box, text("In webby on the other device, open Sync › I have a sync code, then paste this code " &
    "(or the pairing link). Keep it private: it unlocks your passwords." &
    (if s.isWebdav: " The other device also needs the WebDAV login." else: ""), dim = true))
  if not codeShown:
    kit.add(box, buttonRow(btn("Show sync code", proc () = (codeShown = true; refresh()))))
  else:
    kit.add(box, kit.addClass(text(s.code), "mono"))
    let link = s.pairingLink
    var buttons = @[btn("Copy code", proc () = copyText(s.code))]
    if link != "webby-sync:pair?code=" & s.code:
      kit.add(box, kit.addClass(text(link, dim = true, small = true), "mono"))
      buttons.add btn("Copy pairing link", proc () = copyText(link))
    buttons.add btn("Hide", proc () = (codeShown = false; refresh()), flat = true)
    kit.add(box, buttonRow(buttons))
  kit.add(box, kit.separator())
  let done = proc (error: string) = (if error.len > 0: kit.alert("Couldn't turn off sync", error))
  let erase = btn("Turn off everywhere and erase", proc () =
    kit.confirm("Erase the synced copy?", "The encrypted copy on the server is deleted and your other devices stop " &
        "syncing. Passwords and bookmarks already on each device stay there.", "Erase", destructive = true,
      onResult = proc (ok: bool) = (if ok: disable(true, done))))
  kit.addClass(erase, "destructive")
  kit.add(box, buttonRow(btn("Turn off sync on this device", proc () = disable(false, done))))
  kit.add(box, buttonRow(erase))

proc fillSync(box: kit.Widget) =
  if theVault == nil:
    kit.add(box, text(if vaultError.len > 0: vaultError else: "Opening the vault…", dim = true))
    if vaultError.len > 0:
      kit.add(box, buttonRow(btn("Try again", proc () = (retryVault(); refresh())), btn("Start a new vault",
        proc () = kit.confirm("Start a new password vault?", "The vault that can't be opened is kept beside it " &
            "(vault.json.unreadable-…), in case its key turns up. Join sync with the code from another device to " &
            "get your passwords back.", "Start new vault",
          onResult = proc (ok: bool) = (if ok: (startNewVault(); refresh()))), flat = true)))
    return
  let s = settings()
  if s == nil: fillSyncOff(box) else: fillSyncOn(box, s)

# ---------------------------------------------------------------------------------------------------------------
# Tabs from other devices (device_tabs_page.dart)

proc openUrls(urls: seq[string]) =
  for i, u in urls: discard openTab(u, focus = i == 0)

proc oneLine(s: string): kit.Widget =
  result = kit.label(s)
  kit.`maxChars=`(result, 200)

proc tabRow(t: DeviceTab): kit.Widget =
  var host = t.url
  try:
    let h = parseUri(t.url).hostname
    if h.len > 0: host = h
  except CatchableError: discard
  let url = t.url
  result = kit.item(kit.expand(kit.column(oneLine(if t.title.len > 0: t.title else: host),
    kit.addClass(kit.addClass(oneLine(host), "dim"), "small"))), onClick = proc () = openUrls(@[url]))
  kit.`tooltip=`(result, t.url)
  kit.addClass(result, "webby-device-tab")

proc deviceHeader(d: RemoteDevice): kit.Widget =
  let name = kit.row(kit.addClass(oneLine(d.name), "bold"),
    kit.addClass(kit.addClass(kit.label(ago(d.seenAt, yesterday = true)), "dim"), "small"))
  name.spacing = 8
  result = kit.addClass(kit.row(kit.icon(if d.platform in ["android", "ios"]: "smartphone" else: "computer"),
    kit.expand(name)), "webby-device")
  result.spacing = 8
  if d.tabs.len > 1:
    var urls: seq[string]
    for t in d.tabs: urls.add t.url
    kit.add(result, btn("Open all", proc () = openUrls(urls), flat = true))

proc fillDevices(box: kit.Widget) =
  if not enabled():
    kit.add(box, heading("See the tabs open on your other devices"))
    kit.add(box, text("Tabs travel with your passwords and bookmarks, encrypted with your sync code. " &
      "Turn on sync here and on your other devices to see their tabs.", dim = true))
    if not incognito and appUrl.len == 0:
      kit.add(box, gap(4))
      kit.add(box, buttonRow(btn("Set up sync", proc () =
        shown = panelSync
        refresh(), suggested = true)))
    return
  let refreshButton = btn(if syncing(): "Syncing…" else: "Refresh", syncNow)
  kit.`enabled=`(refreshButton, not syncing())
  kit.add(box, buttonRow(kit.spacer(), refreshButton))
  if lastError().len > 0: kit.add(box, banner("Sync isn't working: " & lastError()))
  let list = kit.column()
  list.spacing = 2
  let ds = devices()
  if ds.len == 0:
    kit.add(list, text("No other devices have shared their tabs yet. They show up here once webby on " &
      "another device is syncing with the same sync code.", dim = true))
  for d in ds:
    kit.add(list, deviceHeader(d))
    if d.tabs.len == 0:
      kit.add(list, kit.addClass(text("No open tabs", dim = true, small = true), "webby-device-tab"))
    for t in d.tabs: kit.add(list, tabRow(t))
  kit.add(box, kit.expand(kit.scroll(list)))
  kit.add(box, kit.separator())
  let n = sharedTabs().len
  let me = kit.column(text("This device: " & deviceName()), text(
    if sharing(): "Your other devices see the " & $n & " tab" & (if n == 1: "" else: "s") & " open here."
    else: "Your other devices don't see the tabs open here.", dim = true, small = true))
  kit.add(box, buttonRow(kit.expand(me), btn("Rename", proc () =
    kit.prompt("Name this device", "Other devices list its tabs under this name", deviceName(),
      proc (ok: bool, name: string) = (if ok: setDeviceName(name))))))
  kit.add(box, kit.check("Share this device's tabs", sharing(), proc (on: bool) = setSharing(on)))

# ---------------------------------------------------------------------------------------------------------------
# Panels

proc refresh() =
  if shown == panelNone or panelBody == nil: return
  kit.clear(panelBody)
  if shown == panelSync: fillSync(panelBody) else: fillDevices(panelBody)
  setSidePanelTitle(if shown == panelSync: "Sync" else: "Tabs from other devices")

proc openPanel(kind: PanelKind) =
  let body = kit.addClass(kit.column(), "webby-sync-panel")
  body.spacing = 6
  # (showing it closes the previous panel first, which may be one of these and clear panelBody)
  showSidePanel("", body, 420, proc () = (shown = panelNone; panelBody = nil))
  panelBody = body
  shown = kind
  refresh()

proc showSyncPanel*() =
  codeShown = false
  openPanel(panelSync)

proc showDevicesPanel*() =
  openPanel(panelDevices)
  # Fetch the latest from the other devices.
  if enabled() and not syncing(): syncNow()

proc toggle(kind: PanelKind) =
  if shown == kind: closeSidePanel()
  elif kind == panelSync: showSyncPanel()
  else: showDevicesPanel()

# ---------------------------------------------------------------------------------------------------------------

proc publishTabs() =
  var list: seq[DeviceTab]
  for t in tabs:
    if not t.closed: list.add (t.title, t.url)
  setTabs(list)

proc install*() =
  if incognito or appUrl.len > 0: return
  windowHooks.add proc () =
    loadCss(""".webby-sync-panel { padding: 12px; }
.webby-device { margin-top: 8px; }
.webby-device-tab { margin-left: 24px; }""")
    addMenuSeparator()
    addMenuItem("Sync", proc () = toggle(panelSync))
    addMenuItem("Tabs from other devices", proc () = toggle(panelDevices))
    statusListeners.add refresh
    deviceListeners.add proc () = (if shown == panelDevices: refresh())
    if theVault != nil: engine.start()
    else: vaultOpenHooks.add proc () = (engine.start(); refresh())
  panelActionHooks.add proc (box: kit.Widget) =
    kit.add(box, kit.button(if enabled(): "Synced" else: "Sync", showSyncPanel))
  tabStateHooks.add proc (t: Tab) = publishTabs()
  tabStripHooks.add publishTabs
