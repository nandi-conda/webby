## Installable web apps (app/lib/src/pwa): pages with a manifest get an Install app button next to the URL bar;
## an installed app gets a launcher running `webby --app=<url>`, which opens the app in a window without tab strip
## or URL bar. Also the offline switch (pwa/offline.dart): with no network, pages come from the disk cache.

import std/[os, strutils, tables, uri]
import ../browser
from nimkit/core as kit import nil
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
  installButton: kit.Widget

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
    kit.`visible=`(installButton, false)
    return
  let (isInstalled, app) = installed(a)
  kit.`iconName=`(installButton, if isInstalled: "open_in_new" else: "install_desktop")
  kit.`tooltip=`(installButton, if isInstalled: "Open " & app.name & " app" else: "Install " & a.manifest.title)
  kit.`visible=`(installButton, true)

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
  let e = kit.entry(text = m.title)
  discard kit.sized(e, 300)
  let start = parseUri(m.startUrl)
  let info = kit.addClass(kit.label(start.hostname & (if start.port.len > 0: ":" & start.port else: "") &
    start.path & "\nOpens in its own window and gets a launcher in your app menu."), "dim")
  var d: kit.Dialog
  d = kit.dialog("Install app", kit.column(kit.label("Name"), e, info), @["Cancel", "Install"], proc (r: int) =
    if r != 1: return
    let name = kit.text(e)
    fetchIcon(t, m, proc (bytes, ext: string) =
      try:
        let app = store.install(m, name, (bytes, ext))
        refreshButton()
        launch(app)
      except CatchableError as err:
        alert("Could not install", err.msg)))
  e.onSubmit = proc (s: string) = kit.dialogResult(d, 1)
  kit.focus(e)
  kit.selectAll(e)

proc manageApp(app: InstalledApp) =
  ## Open or uninstall an installed app.
  var host = ""
  try: host = parseUri(app.startUrl).hostname except CatchableError: discard
  discard kit.dialog(app.name, kit.column(kit.label("Installed from " & host & ".")),
    @["Uninstall", "Cancel", "Open app"], destructive = 0, onResult = proc (r: int) =
      if r == 2: launch(app)
      elif r == 0:
        try: uninstall(app) except CatchableError as e: alert("Could not uninstall", e.msg)
        refreshButton())

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
  outsideBar, outsideIcon, outsideHost, backToApp: kit.Widget

proc appInScope(url: string): bool =
  ## Whether `url` belongs to the app: its installed scope, else the start URL's origin.
  if url.len == 0 or not isWeb(url): return true
  if hasApp: return app.inScope(url)
  try: sameOrigin(parseUri(url), parseUri(appUrl)) except CatchableError: true

proc refreshOutside() =
  let t = currentTab()
  if outsideBar == nil or t == nil: return
  if appInScope(t.url):
    kit.`visible=`(outsideBar, false)
    return
  var host = t.url
  try: host = parseUri(t.url).hostname except CatchableError: discard
  kit.`text=`(outsideHost, host)
  kit.`iconName=`(outsideIcon, if t.url.startsWith("https:"): "lock_outline" else: "info_outline")
  kit.`enabled=`(backToApp, t.canBack)
  kit.`visible=`(outsideBar, true)

proc buildAppWindow() =
  let icon = getEnv("WEBBY_APP_ICON")
  if icon.len > 0: discard gtk_window_set_icon_from_file(window, icon.cstring, nil)
  # Pages outside the app's scope get a thin strip with their site and a way out to the browser.
  backToApp = kit.iconButton("arrow_back", "Back to " & (if hasApp: app.name else: "the app"), goBack)
  outsideIcon = kit.icon("info_outline", 14)
  outsideHost = kit.addClass(kit.label(""), "dim")
  kit.`maxChars=`(outsideHost, 200)
  outsideBar = kit.row(backToApp, outsideIcon, kit.expand(outsideHost),
    kit.iconButton("open_in_browser", "Open in Webby", proc () =
      let t = currentTab()
      if t != nil: openInBrowser(t.url)))
  outsideBar.spacing = 6
  kit.addClass(outsideBar, "webby-app-outside-bar")
  kit.`visible=`(outsideBar, false)
  kit.add(barSlot, outsideBar)

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
  offlineIcon: kit.Widget
  offlineBanner: kit.Widget

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
  if offlineIcon != nil: kit.`visible=`(offlineIcon, value)
  if offlineBanner != nil: kit.`visible=`(offlineBanner, value)

proc checkOffline(data: pointer): gboolean {.cdecl.} =
  setOffline(not hasDefaultRoute())
  1

proc startOffline() =
  # Offline mode serves pages from the disk cache, which incognito windows don't have.
  if incognito: return
  if appUrl.len > 0:
    offlineBanner = kit.addClass(kit.label("Offline: showing the copy saved when you last opened this."),
      "webby-info-bar")
    kit.`visible=`(offlineBanner, offline)
    kit.add(barSlot, offlineBanner)
  else:
    offlineIcon = kit.icon("cloud_off")
    kit.`tooltip=`(offlineIcon, "Offline: pages come from the copies saved when you last opened them")
    kit.`visible=`(offlineIcon, offline)
    kit.insert(starSlotRow, kit.sized(offlineIcon, 26), 0)
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
      installButton = kit.iconButton("install_desktop", "Install app", onInstallClicked)
      kit.`visible=`(installButton, false)
      kit.insert(starSlotRow, installButton, 0)
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
