## The remembered per-site permission answers (app/lib/src/site_permissions.dart) in the profile's
## site_permissions.json, and the origin helpers, without UI: used by the desktop (permissions.nim) and Android.

import std/[os, strutils, uri]
import ../../base

type
  Setting* = enum ask = "ask", allow = "allow", blocked = "block"
  Kind* = tuple[name, label, request, icon: string]

const kinds*: array[3, Kind] = [
  ("geolocation", "Location", "Know your location", "location_on_outlined"),
  ("microphone", "Microphone", "Use your microphones", "mic_none"),
  ("notifications", "Notifications", "Show notifications", "notifications_outlined")]

proc kindNamed*(name: string): int =
  for i, k in kinds:
    if k.name == name: return i
  -1

# ---------------------------------------------------------------------------------------------------------------
# Origins

proc originOf*(url: string): string =
  ## "https://example.com[:port]" for http(s) URLs, "" for pages without a site worth keeping settings for.
  try:
    let u = parseUri(url)
    let scheme = u.scheme.toLowerAscii
    if scheme notin ["http", "https"] or u.hostname.len == 0: return ""
    result = scheme & "://" & u.hostname.toLowerAscii
    if u.port.len > 0 and not (scheme == "http" and u.port == "80" or scheme == "https" and u.port == "443"):
      result.add ":" & u.port
  except CatchableError: result = ""

proc siteName*(origin: string): string =
  ## The host without "www.", with the scheme only when it isn't https.
  let i = origin.find("://")
  if i < 0: return origin
  var host = origin[i + 3 .. ^1]
  if host.startsWith("www."): host = host[4 .. ^1]
  if origin.startsWith("https://"): host else: origin[0 ..< i + 3] & host

proc secureOrigin*(url: string): string =
  ## The origin when it may use permission-gated features (https, or http on localhost), else "".
  let o = originOf(url)
  if o.startsWith("https://") or o.startsWith("http://localhost") or o.startsWith("http://127.0.0.1"): o else: ""

# ---------------------------------------------------------------------------------------------------------------
# The remembered answers: {"version": 1, "sites": {origin: {permission: "allow" | "block"}}}

var
  sites: seq[(string, seq[(string, Setting)])]
  loaded = false
  storeListeners*: seq[proc ()]   ## a remembered answer changed

proc isKind(n: JsonNode, kind: JsonNodeKind): bool = n != nil and n.kind == kind

proc storeFile(): string =
  let o = getEnv("WEBBY_SITE_PERMISSIONS_FILE")
  if o.len > 0: o else: profileFile("site_permissions.json")

proc load() =
  if loaded: return
  loaded = true
  let j = readJsonFile(storeFile())
  if j == nil or not isKind(j{"sites"}, JObject): return
  for origin, perms in j["sites"]:
    if perms.kind != JObject: continue
    var list: seq[(string, Setting)]
    for name, v in perms:
      let s = v.getStr
      if s == "allow": list.add (name, allow)
      elif s == "block": list.add (name, blocked)
    if list.len > 0: sites.add (origin, list)

proc save() =
  # An incognito window starts from the profile's answers but keeps its own changes to itself.
  if incognito: return
  var root = newJObject()
  for (origin, list) in sites:
    var o = newJObject()
    for (name, s) in list: o[name] = %($s)
    root[origin] = o
  try: writeJsonFile(storeFile(), %*{"version": 1, "sites": root}, pretty = true)
  except CatchableError as e: stderr.writeLine "webby: could not save ", storeFile(), ": ", e.msg

proc changed() =
  save()
  for h in storeListeners: h()

proc get*(origin, permission: string): Setting =
  load()
  for (o, list) in sites:
    if o == origin:
      for (name, s) in list:
        if name == permission: return s
  ask

proc set*(origin, permission: string, setting: Setting) =
  load()
  if get(origin, permission) == setting: return
  var i = 0
  while i < sites.len and sites[i][0] != origin: inc i
  if i == sites.len: sites.add (origin, newSeq[(string, Setting)]())
  var list = sites[i][1]
  var j = 0
  while j < list.len and list[j][0] != permission: inc j
  if setting == ask:
    if j < list.len: list.delete(j)
  elif j < list.len: list[j][1] = setting
  else: list.add (permission, setting)
  if list.len == 0: sites.delete(i) else: sites[i][1] = list
  changed()

proc reset*(origin: string) =
  ## Forgets every answer `origin` got.
  load()
  for i, (o, _) in sites:
    if o == origin:
      sites.delete(i)
      changed()
      return

proc hasSettings*(origin: string): bool =
  load()
  for (o, list) in sites:
    if o == origin: return list.len > 0
