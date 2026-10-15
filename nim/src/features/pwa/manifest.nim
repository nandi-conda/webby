## The parts of a web app manifest (https://www.w3.org/TR/appmanifest/) webby uses, with URLs resolved, as
## app/lib/src/pwa/manifest.dart parses them.

import std/[json, strutils, uri]

type
  ManifestIcon* = object
    src*: string
    sizes*: seq[int]     ## edge lengths from `sizes`; 0 stands for `any` (a scalable icon)
    kind*, purpose*: string

  Manifest* = ref object
    manifestUrl*, id*, name*, shortName*, description*, startUrl*, scope*, display*: string
    themeColor*, backgroundColor*: string
    icons*: seq[ManifestIcon]

proc isKind*(n: JsonNode, kind: JsonNodeKind): bool = n != nil and n.kind == kind

proc defaultPort(scheme: string): string =
  case scheme
  of "http": "80"
  of "https": "443"
  else: ""

proc canon*(u: Uri): Uri =
  ## Lower-case scheme and host, no default port, like Dart's Uri.
  result = u
  result.scheme = u.scheme.toLowerAscii
  result.hostname = u.hostname.toLowerAscii
  if result.port == defaultPort(result.scheme): result.port = ""

proc sameOrigin*(a, b: Uri): bool =
  let a = canon(a)
  let b = canon(b)
  a.scheme == b.scheme and a.hostname == b.hostname and a.port == b.port

proc inScope*(scope, url: string): bool =
  ## Whether `url` is the same origin as `scope` and under its path.
  try:
    let s = parseUri(scope)
    let u = parseUri(url)
    sameOrigin(u, s) and u.path.startsWith(s.path)
  except CatchableError: false

proc isSvg*(i: ManifestIcon): bool = "svg" in i.kind or i.src.toLowerAscii.split('?')[0].endsWith(".svg")
proc isPng*(i: ManifestIcon): bool = "png" in i.kind or i.src.toLowerAscii.split('?')[0].endsWith(".png")
proc largest(i: ManifestIcon): int = (if i.sizes.len == 0: 0 else: max(i.sizes))

proc title*(m: Manifest): string = (if m.name.len > 0: m.name else: m.shortName)

proc bestIcon*(m: Manifest): int =
  ## The icon for a desktop launcher (an index into icons, -1 if none): PNG over SVG over anything else, `any`
  ## purpose over `maskable`, then the one closest to 256 px (bigger beats smaller).
  result = -1
  var best = low(int)
  for i, icon in m.icons:
    var s = 0
    if icon.isPng: s += 4000
    elif icon.isSvg: s += 3000
    if "any" in icon.purpose.splitWhitespace: s += 2000
    let size = if icon.isSvg: 256 else: icon.largest
    s += (if size >= 256: 1000 - clamp(size - 256, 0, 999) div 4 else: size * 2)
    if s > best:
      best = s
      result = i

proc parseManifest*(text, manifestUrl, documentUrl: string): Manifest =
  ## The manifest fetched from `manifestUrl` for the page at `documentUrl`; nil when it isn't a JSON object or
  ## names no app.
  let json = try: parseJson(text) except CatchableError: return nil
  if json.kind != JObject: return nil
  proc str(key: string): string =
    if isKind(json{key}, JString): json[key].getStr.strip else: ""
  let base = parseUri(manifestUrl)
  let document = parseUri(documentUrl)
  proc resolve(value: string): (bool, Uri) =
    if value.len == 0: return (false, Uri())
    try: (true, canon(combine(base, parseUri(value)))) except CatchableError: (false, Uri())

  let name = str("name")
  let shortName = str("short_name")
  if name.len == 0 and shortName.len == 0: return nil

  # start_url must be same-origin with the document, else the document's URL is used.
  var (ok, start) = resolve(str("start_url"))
  if not ok or not sameOrigin(start, document): start = canon(document)
  start.anchor = ""

  # scope must contain start_url, else it's start_url's directory.
  # (std/uri's combine(start, ".") leaves "/." on the path, which then matches no page.)
  let dir = start.path[0 .. max(start.path.rfind('/'), 0)]
  let defaultScope = Uri(scheme: start.scheme, hostname: start.hostname, port: start.port,
    path: if dir.startsWith("/"): dir else: "/")
  var (hasScope, scope) = resolve(str("scope"))
  if not hasScope or not sameOrigin(scope, start) or not start.path.startsWith(scope.path): scope = defaultScope
  scope = Uri(scheme: scope.scheme, hostname: scope.hostname, port: scope.port, path: scope.path)

  var id = start
  let idValue = str("id")
  if idValue.len > 0:
    try:
      var resolved = canon(combine(start, parseUri(idValue)))
      resolved.anchor = ""
      if sameOrigin(resolved, start): id = resolved
    except CatchableError: discard

  var icons: seq[ManifestIcon]
  for entry in json{"icons"}.getElems:
    if entry.kind != JObject or not isKind(entry{"src"}, JString): continue
    let raw = entry["src"].getStr
    var src: string
    if raw.startsWith("data:"): src = raw
    else:
      let (ok, u) = resolve(raw)
      if not ok or u.scheme notin ["http", "https"]: continue
      src = $u
    var sizes: seq[int]
    for size in entry{"sizes"}.getStr.splitWhitespace:
      if size.toLowerAscii == "any": sizes.add 0
      else:
        let parts = size.toLowerAscii.split('x')
        if parts.len == 2 and parts[0].len > 0 and parts[1].len > 0 and parts[0].allCharsInSet(Digits) and
            parts[1].allCharsInSet(Digits):
          try: sizes.add parseInt(parts[0]) except ValueError: discard
    icons.add ManifestIcon(src: src, sizes: sizes, kind: entry{"type"}.getStr.toLowerAscii,
      purpose: if isKind(entry{"purpose"}, JString): entry["purpose"].getStr.toLowerAscii else: "any")

  Manifest(manifestUrl: manifestUrl, id: $id, name: name, shortName: shortName, description: str("description"),
    startUrl: $start, scope: $scope, display: (if str("display").len == 0: "browser" else: str("display")),
    themeColor: str("theme_color"), backgroundColor: str("background_color"), icons: icons)
