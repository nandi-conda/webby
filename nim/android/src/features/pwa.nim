## Installable web apps on Android (src/features/pwa.nim on the desktop): the Dart app's page script reports a
## page's <link rel=manifest>; the manifest (pwa/manifest.nim) is fetched with base.httpRequest, and while the
## current page has one, the state Java gets carries "app" and the menu offers Install app. Installing pins a home
## screen shortcut (Java's ShortcutManager) that opens the app's start URL in Webby.

import std/[base64, strutils, uri]
import ../core
import ../../../src/features/pwa/manifest

const manifestScript = block:
  let dart = staticRead("../../../../app/lib/src/pwa/pwa_agent.dart")
  let start = dart.find("String manifestPageScript")
  let first = dart.find("'''", start) + 3
  dart[first ..< dart.find("''';", first)]

type Agent = ref object
  manifest: Manifest
  href: string
  generation: int

var agents: Table[int, Agent]   ## by tab id

proc agent(t: Tab): Agent = agents.mgetOrPut(t.id, Agent())

proc isWeb(url: string): bool = url.startsWith("http://") or url.startsWith("https://")

proc get(url, accept: string, done: proc (ok: bool, body, kind: string), redirects = 3) =
  ## GETs `url` (following a few redirects); data: URLs are decoded here.
  if url.startsWith("data:"):
    let comma = url.find(',')
    if comma < 0: (done(false, "", ""); return)
    let meta = url[5 ..< comma]
    var body = url[comma + 1 .. ^1]
    if meta.endsWith(";base64"):
      try: body = decode(body) except CatchableError: (done(false, "", ""); return)
    else: body = decodeUrl(body, decodePlus = false)
    done(true, body, meta.split(';')[0])
    return
  if base.httpRequest == nil or not isWeb(url): (done(false, "", ""); return)
  base.httpRequest("GET", url, @[("Accept", accept), ("User-Agent", "webby")], "",
    proc (status: int, reason: string, headers: seq[(string, string)], body, error: string) =
      var location, kind = ""
      for (k, v) in headers:
        if k == "location": location = v
        elif k == "content-type": kind = v.toLowerAscii
      if status in 300 .. 399 and location.len > 0 and redirects > 0:
        let next = try: $combine(parseUri(url), parseUri(location)) except CatchableError: ""
        get(next, accept, done, redirects - 1)
      else: done(status == 200 and body.len <= 4 shl 20, body, kind))

proc load(t: Tab, href: string) =
  let a = agent(t)
  inc a.generation
  let generation = a.generation
  let documentUrl = t.url
  let finish = proc (found: Manifest) =
    if t.closed or a.generation != generation: return
    a.manifest = found
    if t == current(): sendState()
  if href.len == 0 or not isWeb(href):
    finish(nil)
    return
  get(href, "application/manifest+json, application/json;q=0.9, */*;q=0.1", proc (ok: bool, body, kind: string) =
    finish(if ok: parseManifest(body, href, documentUrl) else: nil))

proc onMessage(t: Tab, j: JsonNode): bool =
  if j{"type"}.getStr != "manifest": return false
  let href = j{"href"}.getStr
  let a = agent(t)
  if href == a.href and a.manifest != nil: return true
  a.href = href
  load(t, href)
  true

proc iconFor(m: Manifest): int =
  ## A bitmap icon for the launcher (Android can't draw SVG ones): `any` purpose over `maskable`, closest to 192 px.
  result = -1
  var best = low(int)
  for i, icon in m.icons:
    if icon.isSvg: continue
    var s = if "any" in icon.purpose.splitWhitespace: 2000 else: 0
    let size = if icon.sizes.len == 0: 0 else: max(icon.sizes)
    s += (if size >= 192: 1000 - clamp(size - 192, 0, 999) div 4 else: size * 2)
    if s > best:
      best = s
      result = i

proc installCmd(args: JsonNode): JsonNode =
  ## {name}: fetches the icon and asks Java to pin the shortcut ("pinShortcut" {name, url, id, icon (base64)}).
  let t = current()
  if t == nil: return nil
  let m = agent(t).manifest
  if m == nil: return nil
  var name = args{"name"}.getStr.strip
  if name.len == 0: name = m.title
  proc pin(icon: string) =
    event("pinShortcut", %*{"name": name, "url": m.startUrl, "id": m.id, "icon": encode(icon),
      "color": m.backgroundColor})
  let i = iconFor(m)
  if i < 0: pin("")
  else: get(m.icons[i].src, "image/png, image/webp, image/*;q=0.8", proc (ok: bool, body, kind: string) =
    pin(if ok: body else: ""))
  nil

proc install*() =
  pageScriptHooks.add proc (t: Tab): string =
    # Not while the document is parsing: the script reports with prompt() at once, which can wedge the load, and
    # its observer needs <head>.
    if not isWeb(t.url): ""
    else: "(() => { const run = () => {\n" & manifestScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix)) &
      "\n}; if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true });" &
      " else run(); })();"
  pageMessageHooks.add onMessage
  tabStateHooks.add proc (t: Tab) =
    let a = agent(t)
    if a.manifest != nil and not inScope(a.manifest.scope, t.url):
      a.manifest = nil
      a.href = ""
      inc a.generation
  tabClosedHooks.add proc (t: Tab) = agents.del t.id
  stateHooks.add proc (t: Tab, state: JsonNode) =
    let m = if t == nil: nil else: agents.getOrDefault(t.id, Agent()).manifest
    state["app"] = if m == nil: %"" else: %m.title
  commands["pwa.install"] = installCmd
