## KRunner (Alt+Space, the launcher's search): open tabs, bookmarks and history matching what's typed; picking a
## tab switches to it, the others open in a new tab. A D-Bus runner (org.kde.krunner1) at dev.webby.krunner
## /krunner, which KRunner finds through the plugin file written to $XDG_DATA_HOME/krunner/dbusplugins. Only the
## normal browser window serves it (not incognito or app windows).

import std/[os, strutils, tables]
import ../../browser
import ../tabs/common
import dbus, common as plasmaCommon

const
  service = "dev.webby.krunner"
  objectPath = "/krunner"
  iface = "org.kde.krunner1"
  maxMatches = 12
  xml = """<node>
  <interface name="org.kde.krunner1">
    <method name="Teardown"/>
    <method name="Config"><arg name="config" type="a{sv}" direction="out"/></method>
    <method name="Actions"><arg name="matches" type="a(sss)" direction="out"/></method>
    <method name="SetActivationToken"><arg name="token" type="s" direction="in"/></method>
    <method name="Run"><arg name="matchId" type="s" direction="in"/><arg name="actionId" type="s" direction="in"/></method>
    <method name="Match"><arg name="query" type="s" direction="in"/><arg name="matches" type="a(sssida{sv})" direction="out"/></method>
  </interface>
</node>"""
  pluginFile = """[Desktop Entry]
Name=Webby
Comment=Switch to Webby's open tabs, open its bookmarks and history
Icon=internet-web-browser
Type=Service
X-KDE-ServiceTypes=Plasma/Runner
X-KDE-PluginInfo-Name=dev.webby.krunner
X-KDE-PluginInfo-EnabledByDefault=true
X-Plasma-API=DBus
X-Plasma-API-Minimum-Version=2.0
X-Plasma-DBusRunner-Service=dev.webby.krunner
X-Plasma-DBusRunner-Path=/krunner
X-Plasma-Request-Actions-Once=true
"""
  # KRunner::QueryMatch::Type
  possibleMatch = 30
  exactMatch = 100

var lastUrls: Table[string, string]   ## match id -> url, from the last Match

proc writePlugin() =
  let dir = getDataDir() / "krunner" / "dbusplugins"   # $XDG_DATA_HOME or ~/.local/share
  let path = dir / "dev.webby.krunner.desktop"
  try:
    if fileExists(path) and readFile(path) == pluginFile: return
    createDir(dir)
    writeFile(path, pluginFile)
  except CatchableError as e: stderr.writeLine "webby: KRunner plugin: ", e.msg

proc score(text, query: string): float =
  ## 0 when `query` isn't in `text`; more when it's a whole match, at the start or at a word's start.
  let at = text.toLowerAscii.find(query)
  if at < 0: return 0
  if text.len == query.len: return 1
  result = 0.6
  if at == 0: result += 0.2
  elif not text[at - 1].isAlphaNumeric: result += 0.1
  result += 0.1 * query.len.float / text.len.float

proc entry(id, text, icon: string, kind: int, relevance: float, subtext, category, url: string): string =
  "(" & q(id) & ", " & q(text) & ", " & q(icon) & ", " & $kind & ", " & formatFloat(relevance, ffDecimal, 3) &
    ", {'subtext': <" & q(subtext) & ">, 'category': <" & q(category) & ">, 'urls': <[" & q(url) &
    "]>, 'actions': <@as []>})"

proc match(query: string): string =
  let qq = query.strip.toLowerAscii
  var items: seq[string]
  lastUrls.clear()
  if qq.len >= 2:
    var seen: seq[string]
    for t in tabs:
      if t.closed or isBlank(t): continue
      let title = tabLabel(t)
      let s = max(score(title, qq), score(t.url, qq) * 0.9)
      if s <= 0: continue
      seen.add t.url
      items.add entry("tab:" & t.messagePrefix, title, "internet-web-browser",
        (if title.toLowerAscii == qq: exactMatch else: possibleMatch), 0.5 + s / 2, t.url, "Webby tabs", t.url)
      if items.len >= maxMatches: break
    for provider in suggestionProviders:
      for sg in provider(qq):
        if items.len >= maxMatches: break
        if sg.url.len == 0 or sg.url in seen: continue
        seen.add sg.url
        let title = if sg.title.len > 0: sg.title else: sg.url
        let s = max(score(title, qq), score(sg.url, qq) * 0.9)
        let id = "url:" & $lastUrls.len
        lastUrls[id] = sg.url
        let (icon, category) = if sg.kind == "bookmark": ("bookmarks", "Webby bookmarks")
                               else: ("view-history", "Webby history")
        items.add entry(id, title, icon, possibleMatch, 0.2 + max(s, 0.3) / 3, sg.url, category, sg.url)
  "([" & items.join(", ") & "],)"

proc run(id: string) =
  if id.startsWith("tab:"):
    let prefix = id[4 .. ^1]
    for t in tabs:
      if t.messagePrefix == prefix and not t.closed:
        showTab(t)
        return
  elif id in lastUrls:
    discard openTab(lastUrls[id])
    raiseWindow()

proc onCall(meth: string, params: GVariant, inv: pointer) =
  case meth
  of "Match":
    let text = match(params.stringAt(0))
    reply(inv, gv("(a(sssida{sv}))", (if text == "([],)": "(@a(sssida{sv}) [],)" else: text)))
  of "Run":
    let id = params.stringAt(0)
    reply(inv)
    run(id)
    wake()
  of "SetActivationToken":
    activationToken = params.stringAt(0)
    reply(inv)
  of "Actions": reply(inv, gv("(a(sss))", "(@a(sss) [],)"))
  of "Config": reply(inv, gv("(a{sv})", "(@a{sv} {},)"))
  of "Teardown": reply(inv)
  else: replyError(inv, "no method " & meth)

var nameId: cuint

proc install*() =
  windowHooks.add proc () =
    if incognito or appUrl.len > 0: return
    if not exportObject(objectPath, xml, [iface], onCall): return
    writePlugin()
    nameId = own(service)
  shutdownHooks.add proc () = unown(nameId)
