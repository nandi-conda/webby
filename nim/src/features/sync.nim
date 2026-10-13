## Sync for webby-nim (app/lib/src/passwords/sync and tabs/device_tabs*.dart): passwords, passkeys, never-save sites,
## bookmarks, open tabs, page summaries and saved sessions, end-to-end encrypted with a sync code and stored on the
## webby-sync server or a WebDAV folder, compatible with the Flutter app's devices. Two side panels: "Sync" (turn it
## on, join with a code, show the code) and "Tabs from other devices". Incognito and app windows never sync.
## The parts: sync/doc (merge), sync/keys (code and crypto), sync/http + sync/blobs (transport), sync/engine
## (scheduling), sync/devicetabs (device.json and the tabs blob).

import std/[strutils, times, uri]
import ../browser
import passwords/[manager, ui]
from passwords/panel import panelActionHooks
import sync/[keys, blobs, engine, devicetabs]

{.push cdecl, importc.}
proc gtk_radio_button_new_with_label_from_widget(group: Widget, label: cstring): Widget
proc gtk_window_resize(w: Widget, width, height: cint)
{.pop.}

type PanelKind = enum panelNone, panelSync, panelDevices

var
  shown = panelNone
  panelBody: Widget       ## the box the open panel fills (rebuilt on every change)
  codeShown = false

proc refresh()

# ---------------------------------------------------------------------------------------------------------------
# Small pieces

proc text(markup: string, dim = false, small = false): Widget =
  var m = markup
  if small: m = "<small>" & m & "</small>"
  if dim: m = "<span alpha='65%'>" & m & "</span>"
  result = markupLabel(m, wrap = true)

proc heading(s: string): Widget = text("<b>" & escapeMarkup(s) & "</b>")

proc banner(message: string): Widget =
  let l = text("<span foreground='#c01c28'>" & escapeMarkup(message) & "</span>")
  result = gtk_frame_new(nil)
  for f in [gtk_widget_set_margin_start, gtk_widget_set_margin_end, gtk_widget_set_margin_top,
            gtk_widget_set_margin_bottom]: f(l, 6)
  gtk_container_add(result, l)

proc buttonRow(buttons: varargs[Widget]): Widget =
  result = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  for b in buttons: gtk_box_pack_start(result, b, 0, 0, 0)

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
# Setup dialog (_SetupDialog): where to sync and, when joining, the code. Returns nil when cancelled.

proc setupDialog(join: bool): JsonNode =
  let d = gtk_dialog_new_with_buttons(cstring(if join: "Join sync" else: "Turn on sync"), window, GTK_DIALOG_MODAL,
    "_Cancel", GTK_RESPONSE_CANCEL, cstring(if join: "_Join" else: "_Turn on"), GTK_RESPONSE_OK, nil)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  gtk_window_set_default_size(d, 480, -1)
  let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
  gtk_container_set_border_width(box, 12)
  proc field(label: string, password = false): Widget =
    gtk_box_pack_start(box, text(escapeMarkup(label)), 0, 0, 0)
    result = gtk_entry_new()
    gtk_entry_set_activates_default(result, 1)
    gtk_entry_set_visibility(result, (not password).gboolean)
    gtk_box_pack_start(box, result, 0, 0, 0)
  var codeEntry: Widget
  if join:
    codeEntry = field("Sync code from your other device (or the pairing link)")
    gtk_entry_set_placeholder_text(codeEntry, "webby1-…")
  gtk_box_pack_start(box, text("Store the encrypted copy on"), 0, 0, 4)
  let webby = gtk_radio_button_new_with_label_from_widget(nil, "Webby sync")
  let custom = gtk_radio_button_new_with_label_from_widget(webby, "My sync server")
  let webdav = gtk_radio_button_new_with_label_from_widget(webby, "WebDAV")
  gtk_box_pack_start(box, buttonRow(webby, custom, webdav), 0, 0, 0)
  let serverBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
  let serverLabel = text("")
  let server = gtk_entry_new()
  gtk_entry_set_activates_default(server, 1)
  gtk_box_pack_start(serverBox, serverLabel, 0, 0, 0)
  gtk_box_pack_start(serverBox, server, 0, 0, 0)
  gtk_box_pack_start(box, serverBox, 0, 0, 0)
  let loginBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
  let userLabel = text("Username")
  let user = gtk_entry_new()
  let passLabel = text("Password (an app password is best)")
  let pass = gtk_entry_new()
  gtk_entry_set_visibility(pass, 0)
  gtk_entry_set_activates_default(pass, 1)
  for w in [userLabel, user, passLabel, pass]: gtk_box_pack_start(loginBox, w, 0, 0, 0)
  gtk_box_pack_start(box, loginBox, 0, 0, 0)
  let error = text("")
  gtk_box_pack_start(box, error, 0, 0, 4)
  gtk_box_pack_start(gtk_dialog_get_content_area(d), box, 1, 1, 0)

  let storageChanged = proc () =
    let isCustom = gtk_toggle_button_get_active(custom) != 0
    let isDav = gtk_toggle_button_get_active(webdav) != 0
    gtk_widget_set_visible(serverBox, (isCustom or isDav).gboolean)
    gtk_widget_set_visible(loginBox, isDav.gboolean)
    gtk_label_set_text(serverLabel,
      cstring(if isDav: "Folder address" else: "Server address (runs sync-server from the webby repo)"))
    gtk_entry_set_placeholder_text(server,
      cstring(if isDav: "https://cloud.example.com/remote.php/dav/files/me/webby" else: "https://sync.example.com"))
    gtk_window_resize(d, 480, 1)
  for r in [webby, custom, webdav]: r.on("toggled", storageChanged)
  if join:
    # A pasted pairing link says where to sync; show that.
    codeEntry.on("changed", proc () =
      let t = $gtk_entry_get_text(codeEntry)
      if not t.strip.startsWith("webby-sync:"): return
      try:
        let s = fromPairing(t)
        if s.isWebdav:
          gtk_toggle_button_set_active(webdav, 1)
          gtk_entry_set_text(server, s.server.cstring)
        elif s.server != defaultSyncServer:
          gtk_toggle_button_set_active(custom, 1)
          gtk_entry_set_text(server, s.server.cstring)
      except CatchableError: discard)
  gtk_widget_show_all(d)
  storageChanged()
  let fail = proc (msg: string) =
    gtk_label_set_markup(error, cstring("<span foreground='#c01c28'>" & escapeMarkup(msg) & "</span>"))
  while gtk_dialog_run(d) == GTK_RESPONSE_OK:
    var code = ""
    if join:
      try: code = fromPairing($gtk_entry_get_text(codeEntry)).code.normalizeCode
      except BadSyncCode as e: (fail(e.msg); continue)
      except CatchableError: (fail("That isn't a sync code."); continue)
    else: code = generateCode()
    let isWebby = gtk_toggle_button_get_active(webby) != 0
    let isDav = gtk_toggle_button_get_active(webdav) != 0
    let address = ($gtk_entry_get_text(server)).strip
    if not isWebby and not validServer(address):
      fail("Enter the server's address, like https://cloud.example.com/remote.php/dav/files/me/webby")
      continue
    result = newSettings(code, webdav = isDav, server = if isWebby: defaultSyncServer else: address,
      username = if isDav: $gtk_entry_get_text(user) else: "", password = if isDav: $gtk_entry_get_text(pass) else: "")
    break
  gtk_widget_destroy(d)

proc turnOn(join: bool) =
  let s = setupDialog(join)
  if s == nil: return
  try: enable(s)
  except CatchableError as e: alert("Couldn't turn on sync", e.msg)

# ---------------------------------------------------------------------------------------------------------------
# The Sync panel (sync_page.dart)

proc showDevicesPanel*()

proc fillSyncOff(box: Widget) =
  gtk_box_pack_start(box, heading("Keep your passwords, passkeys, bookmarks and tabs on all your devices"), 0, 0, 0)
  gtk_box_pack_start(box, text("Webby encrypts them on this device with a sync code that only your devices know, " &
    "then stores the encrypted copy on a sync server or in your own WebDAV folder. Nobody without the code, the " &
    "server included, can read them.", dim = true), 0, 0, 0)
  gtk_box_pack_start(box, buttonRow(button("Turn on sync", proc () = turnOn(false), suggested = true),
    button("I have a sync code", proc () = turnOn(true))), 0, 0, 8)

proc fillSyncOn(box: Widget, s: JsonNode) =
  let where = if s.isWebdav: "WebDAV folder " & s.server
              elif s.server == defaultSyncServer: "the webby sync server" else: s.server
  if lastError().len > 0: gtk_box_pack_start(box, banner("Sync isn't working: " & lastError()), 0, 0, 0)
  let last = s{"lastSync"}
  let status = if syncing(): "Syncing with " & where & "…"
               else: "Synced with " & where & " " & (if last == nil or last.kind != JInt: "not yet" else: ago(last.getBiggestInt)) & "."
  let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  gtk_box_pack_start(row, text(escapeMarkup(status)), 1, 1, 0)
  let now = button("Sync now", syncNow)
  gtk_widget_set_sensitive(now, (not syncing()).gboolean)
  gtk_box_pack_end(row, now, 0, 0, 0)
  gtk_box_pack_start(box, row, 0, 0, 0)
  gtk_box_pack_start(box, buttonRow(button("Tabs from other devices", showDevicesPanel)), 0, 0, 4)
  gtk_box_pack_start(box, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 6)
  gtk_box_pack_start(box, heading("Add another device"), 0, 0, 0)
  gtk_box_pack_start(box, text("In webby on the other device, open Sync › I have a sync code, then paste this code " &
    "(or the pairing link). Keep it private: it unlocks your passwords." &
    (if s.isWebdav: " The other device also needs the WebDAV login." else: ""), dim = true), 0, 0, 0)
  if not codeShown:
    gtk_box_pack_start(box, buttonRow(button("Show sync code", proc () = (codeShown = true; refresh()))), 0, 0, 4)
  else:
    let code = text("<tt>" & escapeMarkup(s.code) & "</tt>")
    gtk_label_set_selectable(code, 1)
    gtk_box_pack_start(box, code, 0, 0, 4)
    let link = s.pairingLink
    var buttons = @[button("Copy code", proc () = copyText(s.code))]
    if link != "webby-sync:pair?code=" & s.code:
      let l = text("<small><tt>" & escapeMarkup(link) & "</tt></small>", dim = true)
      gtk_label_set_selectable(l, 1)
      gtk_box_pack_start(box, l, 0, 0, 0)
      buttons.add button("Copy pairing link", proc () = copyText(link))
    buttons.add button("Hide", proc () = (codeShown = false; refresh()), flat = true)
    gtk_box_pack_start(box, buttonRow(buttons), 0, 0, 4)
  gtk_box_pack_start(box, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 6)
  let done = proc (error: string) = (if error.len > 0: alert("Couldn't turn off sync", error))
  let erase = button("Turn off everywhere and erase", proc () =
    if confirm("Erase the synced copy?", "The encrypted copy on the server is deleted and your other devices stop " &
        "syncing. Passwords and bookmarks already on each device stay there."):
      disable(true, done))
  addClass(erase, "destructive-action")
  gtk_box_pack_start(box, buttonRow(button("Turn off sync on this device", proc () = disable(false, done))), 0, 0, 0)
  gtk_box_pack_start(box, buttonRow(erase), 0, 0, 0)

proc fillSync(box: Widget) =
  if theVault == nil:
    gtk_box_pack_start(box, text(escapeMarkup(if vaultError.len > 0: vaultError else: "Opening the vault…"),
      dim = true), 0, 0, 0)
    return
  let s = settings()
  if s == nil: fillSyncOff(box) else: fillSyncOn(box, s)

# ---------------------------------------------------------------------------------------------------------------
# Tabs from other devices (device_tabs_page.dart)

proc openUrls(urls: seq[string]) =
  for i, u in urls: discard openTab(u, focus = i == 0)

proc tabRow(t: DeviceTab): Widget =
  var host = t.url
  try:
    let h = parseUri(t.url).hostname
    if h.len > 0: host = h
  except CatchableError: discard
  let inner = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  let title = markupLabel(escapeMarkup(if t.title.len > 0: t.title else: host))
  let sub = markupLabel("<small><span alpha='65%'>" & escapeMarkup(host) & "</span></small>")
  gtk_box_pack_start(inner, title, 0, 0, 0)
  gtk_box_pack_start(inner, sub, 0, 0, 0)
  result = gtk_button_new()
  gtk_button_set_relief(result, GTK_RELIEF_NONE)
  gtk_container_add(result, inner)
  gtk_widget_set_tooltip_text(result, t.url.cstring)
  gtk_widget_set_margin_start(result, 24)
  let url = t.url
  result.on("clicked", proc () = openUrls(@[url]))

proc deviceHeader(d: RemoteDevice): Widget =
  result = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
  gtk_widget_set_margin_top(result, 8)
  gtk_box_pack_start(result, icon(if d.platform in ["android", "ios"]: "smartphone" else: "computer"), 0, 0, 0)
  gtk_box_pack_start(result, markupLabel("<b>" & escapeMarkup(d.name) & "</b>  <small><span alpha='65%'>" &
    ago(d.seenAt, yesterday = true) & "</span></small>"), 1, 1, 0)
  if d.tabs.len > 1:
    var urls: seq[string]
    for t in d.tabs: urls.add t.url
    gtk_box_pack_end(result, button("Open all", proc () = openUrls(urls), flat = true), 0, 0, 0)

proc fillDevices(box: Widget) =
  if not enabled():
    gtk_box_pack_start(box, heading("See the tabs open on your other devices"), 0, 0, 0)
    gtk_box_pack_start(box, text("Tabs travel with your passwords and bookmarks, encrypted with your sync code. " &
      "Turn on sync here and on your other devices to see their tabs.", dim = true), 0, 0, 0)
    if not incognito and appUrl.len == 0:
      gtk_box_pack_start(box, buttonRow(button("Set up sync", proc () =
        shown = panelSync
        refresh(), suggested = true)), 0, 0, 8)
    return
  let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  let refreshButton = button(if syncing(): "Syncing…" else: "Refresh", syncNow)
  gtk_widget_set_sensitive(refreshButton, (not syncing()).gboolean)
  gtk_box_pack_end(top, refreshButton, 0, 0, 0)
  gtk_box_pack_start(box, top, 0, 0, 0)
  if lastError().len > 0: gtk_box_pack_start(box, banner("Sync isn't working: " & lastError()), 0, 0, 0)
  let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)
  let ds = devices()
  if ds.len == 0:
    gtk_box_pack_start(list, text("No other devices have shared their tabs yet. They show up here once webby on " &
      "another device is syncing with the same sync code.", dim = true), 0, 0, 8)
  for d in ds:
    gtk_box_pack_start(list, deviceHeader(d), 0, 0, 0)
    if d.tabs.len == 0:
      let none = text("No open tabs", dim = true, small = true)
      gtk_widget_set_margin_start(none, 28)
      gtk_box_pack_start(list, none, 0, 0, 0)
    for t in d.tabs: gtk_box_pack_start(list, tabRow(t), 0, 0, 0)
  let scroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  gtk_container_add(scroller, list)
  gtk_box_pack_start(box, scroller, 1, 1, 0)
  gtk_box_pack_start(box, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 4)
  let me = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  let n = sharedTabs().len
  gtk_box_pack_start(me, text("This device: " & escapeMarkup(deviceName()) & "\n<small><span alpha='65%'>" &
    (if sharing(): "Your other devices see the " & $n & " tab" & (if n == 1: "" else: "s") & " open here."
     else: "Your other devices don't see the tabs open here.") & "</span></small>"), 1, 1, 0)
  gtk_box_pack_end(me, button("Rename", proc () =
    let (ok, name) = askText("Name this device", "Other devices list its tabs under this name", deviceName())
    if ok: setDeviceName(name)), 0, 0, 0)
  gtk_box_pack_start(box, me, 0, 0, 0)
  let check = gtk_check_button_new_with_label("Share this device's tabs")
  gtk_toggle_button_set_active(check, sharing().gboolean)
  check.on("toggled", proc () = setSharing(gtk_toggle_button_get_active(check) != 0))
  gtk_box_pack_start(box, check, 0, 0, 0)

# ---------------------------------------------------------------------------------------------------------------
# Panels

proc refresh() =
  if shown == panelNone or panelBody == nil: return
  clearChildren(panelBody)
  if shown == panelSync: fillSync(panelBody) else: fillDevices(panelBody)
  gtk_label_set_text(sidePanelTitle, cstring(if shown == panelSync: "Sync" else: "Tabs from other devices"))
  gtk_widget_show_all(panelBody)

proc openPanel(kind: PanelKind) =
  let body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
  gtk_container_set_border_width(body, 12)
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
    addMenuSeparator()
    addMenuItem("Sync", proc () = toggle(panelSync))
    addMenuItem("Tabs from other devices", proc () = toggle(panelDevices))
    statusListeners.add refresh
    deviceListeners.add proc () = (if shown == panelDevices: refresh())
    engine.start()
  panelActionHooks.add proc (box: Widget) =
    gtk_box_pack_end(box, button(if enabled(): "Synced" else: "Sync", showSyncPanel), 0, 0, 0)
  tabStateHooks.add proc (t: Tab) = publishTabs()
  tabStripHooks.add publishTabs
