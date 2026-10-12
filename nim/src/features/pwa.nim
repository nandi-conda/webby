## Installable web apps (app/lib/src/pwa): pages with a manifest get an Install app button next to the URL bar;
## an installed app gets a launcher running `webby --app=<url>`, which opens the app in a window without tab strip
## or URL bar. Also the offline switch (pwa/offline.dart): with no network, pages come from the disk cache.

import std/[os, strutils, tables, uri]
import ../browser
import site/[http, images]
import pwa/[manifest, store]

# The Dart app's script, read at compile time so both front ends run the same JS.
const manifestScript = block:
  let dart = staticRead("../../../app/lib/src/pwa/pwa_agent.dart")
  let start = dart.find("String manifestPageScript")
  let first = dart.find("'''", start) + 3
  dart[first ..< dart.find("''';", first)]

type Agent = ref object
  ## One tab's manifest watch.
  manifest: Manifest
  href: string
  generation: int

var
  agents: Table[string, Agent]   ## by the tab's message prefix
  installButton: Widget

proc agent(t: Tab): Agent =
  agents.mgetOrPut(t.messagePrefix, Agent())

proc isWeb(url: string): bool = url.startsWith("http://") or url.startsWith("https://")

# ---------------------------------------------------------------------------------------------------------------
# Install button and dialogs

proc installed(a: Agent): (bool, InstalledApp) =
  if a.manifest == nil: (false, InstalledApp()) else: byId(a.manifest.id)

proc refreshButton() =
  if installButton == nil: return
  let t = currentTab()
  let a = if t == nil: nil else: agent(t)
  if a == nil or a.manifest == nil:
    gtk_widget_hide(installButton)
    return
  let (isInstalled, app) = installed(a)
  gtk_image_set_from_icon_name(gtk_button_get_image(installButton),
    cstring(if isInstalled: "window-new-symbolic" else: "computer-symbolic"), GTK_ICON_SIZE_SMALL_TOOLBAR)
  gtk_widget_set_tooltip_text(installButton,
    cstring(if isInstalled: "Open " & app.name & " app" else: "Install " & a.manifest.title))
  gtk_widget_show(installButton)

proc fetchIcon(t: Tab, m: Manifest, done: proc (bytes, ext: string)) =
  ## The launcher icon: PNG (re-encoded, at most 512 px) or SVG as is; ("", "") when there is none.
  let i = m.bestIcon
  if i < 0:
    done("", "")
    return
  let icon = m.icons[i]
  fetch(t, icon.src, proc (ok: bool, body, kind: string) =
    if not ok: done("", "")
    elif icon.isSvg or "svg" in kind: done(body, "svg")
    else:
      let png = toPng(body)
      if png.len > 0: done(png, "png") else: done("", ""))

proc installApp(t: Tab, m: Manifest) =
  ## Asks for the app's name and installs it.
  let d = gtk_dialog_new_with_buttons("Install app", window, GTK_DIALOG_MODAL, "_Cancel", GTK_RESPONSE_CANCEL,
    "_Install", GTK_RESPONSE_OK, nil)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  let box = gtk_dialog_get_content_area(d)
  gtk_container_set_border_width(box, 12)
  let nameLabel = gtk_label_new("Name")
  gtk_label_set_xalign(nameLabel, 0)
  gtk_box_pack_start(box, nameLabel, 0, 0, 2)
  let e = gtk_entry_new()
  gtk_entry_set_text(e, m.title.cstring)
  gtk_entry_set_activates_default(e, 1)
  gtk_entry_set_width_chars(e, 36)
  gtk_box_pack_start(box, e, 0, 0, 2)
  let start = parseUri(m.startUrl)
  let info = gtk_label_new(cstring(start.hostname & (if start.port.len > 0: ":" & start.port else: "") &
    start.path & "\nOpens in its own window and gets a launcher in your app menu."))
  gtk_label_set_xalign(info, 0)
  addClass(info, "dim-label")
  gtk_box_pack_start(box, info, 0, 0, 8)
  gtk_widget_show_all(d)
  let ok = gtk_dialog_run(d) == GTK_RESPONSE_OK
  let name = $gtk_entry_get_text(e)
  gtk_widget_destroy(d)
  if not ok: return
  fetchIcon(t, m, proc (bytes, ext: string) =
    try:
      let app = store.install(m, name, (bytes, ext))
      refreshButton()
      launch(app)
    except CatchableError as err:
      alert("Could not install", err.msg))

proc manageApp(app: InstalledApp) =
  ## Open or uninstall an installed app.
  let d = gtk_message_dialog_new(window, GTK_DIALOG_MODAL, GTK_MESSAGE_INFO, GTK_BUTTONS_NONE, "%s", app.name.cstring)
  var host = ""
  try: host = parseUri(app.startUrl).hostname except CatchableError: discard
  gtk_message_dialog_format_secondary_text(d, "%s", cstring("Installed from " & host & "."))
  const uninstallResponse = 1.cint
  addClass(gtk_dialog_add_button(d, "_Uninstall", uninstallResponse), "destructive-action")
  discard gtk_dialog_add_button(d, "_Cancel", GTK_RESPONSE_CANCEL)
  discard gtk_dialog_add_button(d, "_Open app", GTK_RESPONSE_OK)
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  let r = gtk_dialog_run(d)
  gtk_widget_destroy(d)
  if r == GTK_RESPONSE_OK: launch(app)
  elif r == uninstallResponse:
    try: uninstall(app) except CatchableError as e: alert("Could not uninstall", e.msg)
    refreshButton()

proc onInstallClicked() =
  let t = currentTab()
  if t == nil: return
  let a = agent(t)
  if a.manifest == nil: return
  let (isInstalled, app) = installed(a)
  if isInstalled: manageApp(app) else: installApp(t, a.manifest)

# ---------------------------------------------------------------------------------------------------------------
# Manifest detection

proc load(t: Tab, href, documentUrl: string) =
  let a = agent(t)
  inc a.generation
  let generation = a.generation
  let finish = proc (found: Manifest) =
    if t.closed or a.generation != generation: return
    a.manifest = found
    if t == currentTab(): refreshButton()
  if href.len == 0 or not isWeb(href):
    finish(nil)
    return
  fetch(t, href, proc (ok: bool, body, kind: string) =
    finish(if ok: parseManifest(body, href, documentUrl) else: nil),
    accept = "application/manifest+json, application/json;q=0.9, */*;q=0.1", maxBytes = 1 shl 20,
    timeoutMs = 15000)

proc onMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"manifest\""): return false
  let href = try: parseJson(text){"href"}.getStr except CatchableError: return true
  let a = agent(t)
  if href == a.href and a.manifest != nil: return true
  a.href = href
  load(t, href, t.url)
  true

proc onTabState(t: Tab) =
  let a = agent(t)
  if a.manifest != nil and not manifest.inScope(a.manifest.scope, t.url):
    a.manifest = nil
    a.href = ""
    inc a.generation
    if t == currentTab(): refreshButton()

# ---------------------------------------------------------------------------------------------------------------
# The app window (--app=<url>)

var
  app: InstalledApp
  hasApp = false
  outsideBar, outsideIcon, outsideHost, backToApp: Widget

proc appInScope(url: string): bool =
  ## Whether `url` belongs to the app: its installed scope, else the start URL's origin.
  if url.len == 0 or not isWeb(url): return true
  if hasApp: return app.inScope(url)
  try: sameOrigin(parseUri(url), parseUri(appUrl)) except CatchableError: true

proc refreshOutside() =
  let t = currentTab()
  if outsideBar == nil or t == nil: return
  if appInScope(t.url):
    gtk_widget_hide(outsideBar)
    return
  var host = t.url
  try: host = parseUri(t.url).hostname except CatchableError: discard
  gtk_label_set_text(outsideHost, host.cstring)
  gtk_image_set_from_icon_name(outsideIcon,
    cstring(if t.url.startsWith("https:"): "channel-secure-symbolic" else: "dialog-information-symbolic"),
    GTK_ICON_SIZE_MENU)
  gtk_widget_set_sensitive(backToApp, t.canBack.gboolean)
  gtk_widget_set_no_show_all(outsideBar, 0)
  gtk_widget_show_all(outsideBar)
  gtk_widget_set_no_show_all(outsideBar, 1)

proc buildAppWindow() =
  let icon = getEnv("WEBBY_APP_ICON")
  if icon.len > 0: discard gtk_window_set_icon_from_file(window, icon.cstring, nil)
  # Pages outside the app's scope get a thin strip with their site and a way out to the browser.
  outsideBar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  gtk_container_set_border_width(outsideBar, 2)
  backToApp = iconButton("go-previous-symbolic", "Back to " & (if hasApp: app.name else: "the app"), goBack)
  outsideIcon = gtk_image_new_from_icon_name("dialog-information-symbolic", GTK_ICON_SIZE_MENU)
  outsideHost = gtk_label_new("")
  gtk_label_set_xalign(outsideHost, 0)
  gtk_label_set_ellipsize(outsideHost, PANGO_ELLIPSIZE_END)
  addClass(outsideHost, "dim-label")
  gtk_box_pack_start(outsideBar, backToApp, 0, 0, 0)
  gtk_box_pack_start(outsideBar, outsideIcon, 0, 0, 0)
  gtk_box_pack_start(outsideBar, outsideHost, 1, 1, 0)
  gtk_box_pack_end(outsideBar, iconButton("web-browser-symbolic", "Open in Webby", proc () =
    let t = currentTab()
    if t != nil: openInBrowser(t.url)), 0, 0, 0)
  gtk_widget_set_no_show_all(outsideBar, 1)
  gtk_box_pack_start(barSlot, outsideBar, 0, 0, 0)

proc closeLater(t: Tab) =
  ## Closes `t` outside the pump (which still uses the tab after the state hooks).
  GC_ref(t)
  discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} =
    let t = cast[Tab](d)
    if not t.closed: closeTab(t)
    GC_unref(t)
    0, cast[pointer](t))

proc onAppTabState(t: Tab) =
  # Links the app opens in a new window go to the browser when they leave the app.
  if tabs.len > 0 and t != tabs[0] and t.props.getOrDefault("pwa.checked") != "1" and isWeb(t.url):
    t.props["pwa.checked"] = "1"
    if not appInScope(t.url):
      openInBrowser(t.url)
      closeLater(t)
      return
  if t == currentTab(): refreshOutside()

# ---------------------------------------------------------------------------------------------------------------
# Offline: Ladybird's network process goes cache-only while the machine has no default route.

var
  offline = false
  offlineIcon, offlineBanner: Widget

proc hasDefaultRoute(): bool =
  ## Whether the kernel has a default route; true when that can't be read, so webby never goes offline by mistake.
  var readable = false
  try:
    let lines = readFile("/proc/net/route").splitLines
    readable = true
    # Iface Destination Gateway Flags ...: destination 00000000 with the RTF_UP flag.
    for line in lines[min(1, lines.len) .. ^1]:
      let f = line.splitWhitespace
      if f.len > 3 and f[1] == "00000000" and (try: (parseHexInt(f[3]) and 1) == 1 except ValueError: false):
        return true
  except CatchableError: discard
  try:
    let lines = readFile("/proc/net/ipv6_route").splitLines
    readable = true
    # dest prefixlen src srclen nexthop metric refcnt use flags iface: ::/0 not on loopback nor a reject route.
    for line in lines:
      let f = line.splitWhitespace
      if f.len < 10 or f[0] != repeat('0', 32) or f[1] != "00": continue
      let flags = try: parseHexInt(f[8]) except ValueError: 0
      if f[9] != "lo" and (flags and 0x0200) == 0: return true
  except CatchableError: discard
  not readable

proc setOffline(value: bool) =
  if value == offline: return
  offline = value
  webby_set_offline(value.cint)
  for w in [offlineIcon, offlineBanner]:
    if w != nil: gtk_widget_set_visible(w, value.gboolean)

proc checkOffline(data: pointer): gboolean {.cdecl.} =
  setOffline(not hasDefaultRoute())
  1

proc startOffline() =
  # Offline mode serves pages from the disk cache, which incognito windows don't have.
  if incognito: return
  if appUrl.len > 0:
    offlineBanner = gtk_label_new("Offline: showing the copy saved when you last opened this.")
    gtk_widget_set_no_show_all(offlineBanner, 1)
    gtk_box_pack_start(barSlot, offlineBanner, 0, 0, 2)
  else:
    offlineIcon = gtk_image_new_from_icon_name("network-offline-symbolic", GTK_ICON_SIZE_SMALL_TOOLBAR)
    gtk_widget_set_tooltip_text(offlineIcon, "Offline: pages come from the copies saved when you last opened them")
    gtk_widget_set_margin_start(offlineIcon, 5)
    gtk_widget_set_margin_end(offlineIcon, 5)
    gtk_widget_set_no_show_all(offlineIcon, 1)
    gtk_box_pack_start(starSlot, offlineIcon, 0, 0, 0)
    gtk_box_reorder_child(starSlot, offlineIcon, 0)
  case getEnv("WEBBY_OFFLINE")
  of "0": discard
  of "1": setOffline(true)
  else:
    setOffline(not hasDefaultRoute())
    discard g_timeout_add(5000, checkOffline, nil)

# ---------------------------------------------------------------------------------------------------------------

proc g_set_prgname(name: cstring) {.importc, cdecl.}
proc gdk_set_program_class(name: cstring) {.importc, cdecl.}

proc install*() =
  startupHooks.add proc () =
    if appUrl.len > 0:
      (hasApp, app) = forUrl(appUrl)
      # The app's own id, so docks show its window apart from webby's, with its launcher's icon.
      let id = getEnv("WEBBY_APP_ID")
      if id.len > 0:
        g_set_prgname(id.cstring)
        gdk_set_program_class(id.cstring)
    elif not incognito:
      try: refreshLaunchers() except CatchableError: discard
  windowHooks.add proc () =
    if appUrl.len > 0: buildAppWindow()
    elif not incognito:
      # Incognito windows don't install apps.
      installButton = iconButton("computer-symbolic", "Install app", onInstallClicked)
      gtk_widget_set_no_show_all(installButton, 1)
      gtk_box_pack_start(starSlot, installButton, 0, 0, 0)
      gtk_box_reorder_child(starSlot, installButton, 0)
    startOffline()
  pageScriptHooks.add proc (t: Tab): string =
    if incognito or appUrl.len > 0 or not isWeb(t.url): ""
    else: manifestScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix))
  pageMessageHooks.add onMessage
  tabStateHooks.add proc (t: Tab) =
    if appUrl.len > 0: onAppTabState(t) else: onTabState(t)
  activeTabHooks.add proc (t: Tab) =
    if appUrl.len > 0: refreshOutside() else: refreshButton()
  tabClosedHooks.add proc (t: Tab) = agents.del t.messagePrefix
