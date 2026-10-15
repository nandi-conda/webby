## The synced form of everything and how two copies merge (app/lib/src/passwords/sync/sync_doc.dart). Pure Nim, no
## GTK, so tests can run it beside the Dart code.
##
## A doc is a JsonNode object of sections (passwords, passkeys, neverSave, bookmarks, devices, summaries, sessions,
## secrets),
## each {key: record}. Records carry "updatedAt" (seconds); a deletion is a tombstone {updatedAt, deleted: true}.
## `canonical` is byte for byte Dart's `SyncDoc.canonical()` (jsonEncode with sorted keys, Dart's number and string
## forms, keys ordered by UTF-16 code units), since merge ties are broken by comparing those encodings.

import std/[algorithm, json, math, strutils, tables, unicode]

const
  tombstoneLifetime* = 180 * 24 * 3600   ## seconds a deletion is remembered
  deviceLifetime* = 30 * 24 * 3600       ## seconds a silent device stays under "Tabs from other devices"
  summaryLimit* = 300
  sectionNames* = ["passwords", "passkeys", "neverSave", "bookmarks", "devices", "summaries", "sessions", "secrets"]
  bookmarkRoots* = ["bar", "other"]

# ---------------------------------------------------------------------------------------------------------------
# Dart's jsonEncode

proc cmpUtf16*(a, b: string): int =
  ## Dart's String.compareTo: by UTF-16 code units (differs from byte order only past U+FFFF vs U+E000..U+FFFF).
  var i, j = 0
  var pendA, pendB = -1   # the low surrogate still to compare after a high one
  while true:
    var ua, ub: int
    if pendA >= 0: (ua = pendA; pendA = -1)
    elif i < a.len:
      var r: Rune
      fastRuneAt(a, i, r, true)
      let c = r.int
      if c >= 0x10000:
        ua = 0xD800 + ((c - 0x10000) shr 10)
        pendA = 0xDC00 + ((c - 0x10000) and 0x3FF)
      else: ua = c
    else: ua = -1
    if pendB >= 0: (ub = pendB; pendB = -1)
    elif j < b.len:
      var r: Rune
      fastRuneAt(b, j, r, true)
      let c = r.int
      if c >= 0x10000:
        ub = 0xD800 + ((c - 0x10000) shr 10)
        pendB = 0xDC00 + ((c - 0x10000) and 0x3FF)
      else: ub = c
    else: ub = -1
    if ua != ub: return (if ua < ub: -1 else: 1)
    if ua < 0: return 0

proc utf16Len*(s: string): int =
  for r in s.runes: result += (if r.int >= 0x10000: 2 else: 1)

proc dartDouble*(x: float): string =
  ## Dart's double.toString(): JavaScript's shortest form, with ".0" on whole numbers.
  if x.classify in {fcNan}: return "NaN"
  if x.classify == fcInf: return "Infinity"
  if x.classify == fcNegInf: return "-Infinity"
  if x == 0: return (if x.classify == fcNegZero: "-0.0" else: "0.0")
  let neg = x < 0
  let a = abs(x)
  var sci = ""
  for p in 1 .. 17:
    sci = formatFloat(a, ffScientific, p - 1)
    if parseFloat(sci) == a: break
  let e = sci.find('e')
  var digits = sci[0 ..< e].replace(".", "")
  let exp10 = parseInt(sci[e + 1 .. ^1])
  digits = digits.strip(leading = false, chars = {'0'})
  if digits.len == 0: digits = "0"
  let k = digits.len
  let n = exp10 + 1
  if k <= n and n <= 21: result = digits & repeat('0', n - k) & ".0"
  elif 0 < n and n <= 21: result = digits[0 ..< n] & "." & digits[n .. ^1]
  elif -6 < n and n <= 0: result = "0." & repeat('0', -n) & digits
  else:
    let ex = n - 1
    result = digits[0 .. 0] & (if k > 1: "." & digits[1 .. ^1] else: "") & "e" & (if ex >= 0: "+" else: "-") & $abs(ex)
  if neg: result = "-" & result

proc dartString(s: string, o: var string) =
  o.add '"'
  for c in s:
    case c
    of '"': o.add "\\\""
    of '\\': o.add "\\\\"
    of '\b': o.add "\\b"
    of '\t': o.add "\\t"
    of '\n': o.add "\\n"
    of '\f': o.add "\\f"
    of '\r': o.add "\\r"
    elif c < ' ': o.add "\\u00" & toHex(ord(c), 2).toLowerAscii
    else: o.add c
  o.add '"'

proc sortedKeys*(n: JsonNode): seq[string] =
  for k in n.keys: result.add k
  result.sort(cmpUtf16)

proc encode(n: JsonNode, o: var string, sortKeys: bool) =
  if n == nil:
    o.add "null"
    return
  case n.kind
  of JNull: o.add "null"
  of JBool: o.add (if n.getBool: "true" else: "false")
  of JInt: o.add $n.getBiggestInt
  of JFloat: o.add dartDouble(n.getFloat)
  of JString: dartString(n.getStr, o)
  of JArray:
    o.add '['
    for i, e in n.getElems:
      if i > 0: o.add ','
      encode(e, o, sortKeys)
    o.add ']'
  of JObject:
    o.add '{'
    var first = true
    let keys = if sortKeys: sortedKeys(n) else: (var s: seq[string]; (for k in n.keys: s.add k); s)
    for k in keys:
      if not first: o.add ','
      first = false
      dartString(k, o)
      o.add ':'
      encode(n[k], o, sortKeys)
    o.add '}'

proc dartJson*(n: JsonNode): string =
  ## jsonEncode(n) in Dart, keeping key order.
  encode(n, result, false)

proc canonicalValue*(n: JsonNode): string =
  ## jsonEncode(_canonicalValue(n)): keys sorted at every level.
  encode(n, result, true)

# ---------------------------------------------------------------------------------------------------------------
# Docs

proc newDoc*(): JsonNode =
  result = newJObject()
  for s in sectionNames: result[s] = newJObject()

proc section*(doc: JsonNode, name: string): JsonNode =
  ## The doc's section (never nil; an empty object when missing).
  let s = if doc == nil: nil else: doc{name}
  if s != nil and s.kind == JObject: s else: newJObject()

proc docFromJson*(j: JsonNode): JsonNode =
  ## SyncDoc.fromJson: sections that are objects, records that are objects, copied.
  result = newDoc()
  if j == nil or j.kind != JObject: return
  for s in sectionNames:
    let v = j{s}
    if v == nil or v.kind != JObject: continue
    for k, r in v:
      if r.kind == JObject: result[s][k] = r.copy

proc docWith*(name: string, records: JsonNode): JsonNode =
  ## A doc holding only one section.
  result = newDoc()
  if records != nil and records.kind == JObject:
    for k, r in records:
      if r.kind == JObject: result[name][k] = r.copy

proc toJson*(doc: JsonNode): JsonNode =
  ## SyncDoc.toJson: version, the three vault sections always, the others when not empty.
  result = %*{"version": 1}
  for s in sectionNames:
    let sec = doc.section(s)
    if s in ["passwords", "passkeys", "neverSave"] or sec.len > 0: result[s] = sec

proc canonical*(doc: JsonNode): string = canonicalValue(doc.toJson)

proc sameDoc*(a, b: JsonNode): bool = canonical(a) == canonical(b)

proc updatedAtOf*(r: JsonNode): int64 =
  let v = r{"updatedAt"}
  if v == nil: 0'i64 elif v.kind == JInt: v.getBiggestInt elif v.kind == JFloat: v.getFloat.int64 else: 0'i64

proc isDeleted*(r: JsonNode): bool =
  let v = r{"deleted"}
  v != nil and v.kind == JBool and v.getBool

proc newer*(a, b: JsonNode): JsonNode =
  ## The winner of two versions of one item: the newer; at the same time a deletion; then the larger encoding.
  let ta = updatedAtOf(a)
  let tb = updatedAtOf(b)
  if ta != tb: return (if ta > tb: a else: b)
  if isDeleted(a) != isDeleted(b): return (if isDeleted(a): a else: b)
  if cmpUtf16(canonicalValue(a), canonicalValue(b)) >= 0: a else: b

proc same(a, b: JsonNode): bool = cast[pointer](a) == cast[pointer](b)

proc mergeSection(a, b: JsonNode, expireBefore: int64): OrderedTable[string, JsonNode] =
  var keys: seq[string]
  for k in a.keys: keys.add k
  for k in b.keys:
    if not a.hasKey(k): keys.add k
  for k in keys:
    let x = a{k}
    let y = b{k}
    let winner = if x == nil: y elif y == nil: x else: newer(x, y)
    if isDeleted(winner) and updatedAtOf(winner) < expireBefore: continue
    result[k] = winner.copy

proc toNode(t: OrderedTable[string, JsonNode]): JsonNode =
  result = newJObject()
  for k, v in t: result[k] = v

proc trimSummaries(records: var OrderedTable[string, JsonNode]) =
  var live: seq[string]
  for k, r in records:
    if not isDeleted(r): live.add k
  let snapshot = records
  live.sort(proc (a, b: string): int =
    let ta = updatedAtOf(snapshot[a])
    let tb = updatedAtOf(snapshot[b])
    if ta != tb: (if tb < ta: -1 else: 1) else: cmpUtf16(a, b))
  for i in summaryLimit ..< live.len: records.del live[i]

proc isFolder(r: JsonNode): bool =
  let v = r{"folder"}
  v != nil and v.kind == JBool and v.getBool

proc repairBookmarks(records: var OrderedTable[string, JsonNode]) =
  ## _repairBookmarks: re-homes orphans in Other bookmarks, cuts folder loops and collapses duplicates.
  var ids: seq[string]
  for k in records.keys: ids.add k
  ids.sort(cmpUtf16)

  proc resolve(records: OrderedTable[string, JsonNode], start: JsonNode): string =
    var parent = start
    var seen: seq[string]
    while parent != nil and parent.kind == JString and parent.getStr notin bookmarkRoots and parent.getStr notin seen:
      let p = parent.getStr
      seen.add p
      if p notin records: return "other"
      let r = records[p]
      if not isDeleted(r): return (if isFolder(r): p else: "other")
      parent = r{"mergedInto"}
    if parent != nil and parent.kind == JString and parent.getStr in bookmarkRoots: parent.getStr else: "other"

  proc setParent(records: var OrderedTable[string, JsonNode], id, parent: string) =
    let r = records[id].copy
    r["parent"] = %parent
    records[id] = r

  var changed = true
  while changed:
    changed = false
    for id in ids:
      let r = records[id]
      if isDeleted(r): continue
      let parent = resolve(records, r{"parent"})
      let cur = r{"parent"}
      if cur == nil or cur.kind != JString or cur.getStr != parent: setParent(records, id, parent)
    for id in ids:
      if isDeleted(records[id]): continue
      var seen: seq[string]
      var at = id
      while at notin bookmarkRoots:
        if at in seen:
          setParent(records, at, "other")
          break
        seen.add at
        at = records[at]["parent"].getStr
    for (folders, key) in [(true, "title"), (false, "url")]:
      var groups: OrderedTable[string, seq[string]]
      for id in ids:
        let r = records[id]
        if isDeleted(r) or isFolder(r) != folders: continue
        let g = dartJson(%[r{"parent"}, (if r{key} == nil: newJNull() else: r{key})])
        groups.mgetOrPut(g, @[]).add id
      for group in groups.values:
        if group.len < 2: continue
        var keepId = group[0]
        for id in group[1 .. ^1]:
          if not same(newer(records[keepId], records[id]), records[keepId]): keepId = id
        for id in group:
          if id == keepId: continue
          var tomb = %*{"updatedAt": updatedAtOf(records[id]), "deleted": true}
          if folders: tomb["mergedInto"] = %keepId
          records[id] = tomb
        if folders: changed = true
      if changed: break

proc mergeDocs*(a, b: JsonNode, now: int64): JsonNode =
  ## Merges two copies; the result is the same in either order. `now` in seconds.
  let expireBefore = now - tombstoneLifetime
  result = newDoc()
  var passwords = mergeSection(a.section("passwords"), b.section("passwords"), expireBefore)
  # The same site and username saved on two devices: keep the newest, delete the rest.
  var byAccount: OrderedTable[string, seq[string]]
  for id, r in passwords:
    if isDeleted(r): continue
    let account = dartJson(%[(if r{"origin"} == nil: newJNull() else: r["origin"]),
                             (if r{"username"} == nil: newJNull() else: r["username"])])
    byAccount.mgetOrPut(account, @[]).add id
  for ids in byAccount.values:
    if ids.len < 2: continue
    var keep = ids[0]
    for id in ids[1 .. ^1]:
      if not same(newer(passwords[keep], passwords[id]), passwords[keep]): keep = id
    for id in ids:
      if id != keep: passwords[id] = %*{"id": id, "updatedAt": updatedAtOf(passwords[id]), "deleted": true}
  result["passwords"] = passwords.toNode
  result["passkeys"] = mergeSection(a.section("passkeys"), b.section("passkeys"), expireBefore).toNode
  result["neverSave"] = mergeSection(a.section("neverSave"), b.section("neverSave"), expireBefore).toNode
  var bookmarks = mergeSection(a.section("bookmarks"), b.section("bookmarks"), expireBefore)
  repairBookmarks(bookmarks)
  result["bookmarks"] = bookmarks.toNode
  var devices = mergeSection(a.section("devices"), b.section("devices"), expireBefore)
  var stale: seq[string]
  for k, r in devices:
    if not isDeleted(r) and updatedAtOf(r) < now - deviceLifetime: stale.add k
  for k in stale: devices.del k
  result["devices"] = devices.toNode
  var summaries = mergeSection(a.section("summaries"), b.section("summaries"), expireBefore)
  trimSummaries(summaries)
  result["summaries"] = summaries.toNode
  result["sessions"] = mergeSection(a.section("sessions"), b.section("sessions"), expireBefore).toNode
  result["secrets"] = mergeSection(a.section("secrets"), b.section("secrets"), expireBefore).toNode
