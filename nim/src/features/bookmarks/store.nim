## One profile's bookmarks (app/lib/src/bookmarks/bookmark_store.dart): a "Bookmarks bar" folder shown under the
## toolbar and an "Other bookmarks" folder, kept in `<profile>/bookmarks.json` (or $WEBBY_BOOKMARKS_FILE) in the same
## format as the Flutter app. Every change is written straight away through a temporary file; incognito keeps none.
## Also reads and writes the Netscape bookmarks.html format (bookmark_html.dart).

import std/[algorithm, json, os, sequtils, sets, strutils, tables, times]
from std/unicode import Rune, `$`
import ../../base

type
  Bookmark* = ref object
    ## A bookmarked page, or a folder of them (a folder has no url).
    id*, title*, url*: string
    isFolder*: bool
    children*: seq[Bookmark]   ## a folder's contents in display order
    addedAt*: int64            ## seconds since the epoch
    updatedAt*: int64          ## last added, renamed or moved; the newest edit wins in sync
    pos*: float                ## orders the bookmark among its folder's children (smaller first)

var
  bar*, other*: Bookmark
  showBarSetting = true
  loadError*: string           ## why the file couldn't be read (it was set aside), or ""
  changeHooks*: seq[proc ()]   ## bookmarks or the bar setting changed
  deleted: OrderedTable[string, JsonNode]  ## sync tombstones by id
  idCounter = 0
  loaded = false

proc now(): int64 = getTime().toUnix

proc newLink*(id, title, url: string, addedAt: int64 = -1, updatedAt: int64 = -1, pos = 0.0): Bookmark =
  let added = if addedAt < 0: now() else: addedAt
  Bookmark(id: id, title: title, url: url, addedAt: added, updatedAt: if updatedAt < 0: added else: updatedAt, pos: pos)

proc newFolder*(id, title: string, addedAt: int64 = -1, updatedAt: int64 = -1, pos = 0.0): Bookmark =
  result = newLink(id, title, "", addedAt, updatedAt, pos)
  result.isFolder = true

proc label*(b: Bookmark): string = (if b.title.len > 0: b.title else: b.url)

iterator descendants*(b: Bookmark): Bookmark =
  ## This node and everything under it, depth first.
  var stack = @[b]
  while stack.len > 0:
    let n = stack.pop()
    yield n
    for i in countdown(n.children.high, 0): stack.add n.children[i]

proc fromJson(j: JsonNode): Bookmark =
  if j == nil or j.kind != JObject: return nil
  let id = j{"id"}.getStr
  if id.len == 0: return nil
  let title = j{"title"}.getStr
  let addedAt = j{"addedAt"}.getBiggestInt(0)
  let updatedAt = if j.hasKey("updatedAt"): j["updatedAt"].getBiggestInt(addedAt) else: addedAt
  let pos = j{"pos"}.getFloat(0)
  if j{"url"} != nil and j["url"].kind == JString:
    return newLink(id, title, j["url"].getStr, addedAt, updatedAt, pos)
  result = newFolder(id, title, addedAt, updatedAt, pos)
  var index = 0
  for child in j{"children"}.getElems:
    let node = fromJson(child)
    if node == nil: continue
    # Files from before sync have no positions; number the children in their saved order.
    if child{"pos"} == nil or child["pos"].kind == JNull:
      inc index
      node.pos = index.float
    result.children.add node

proc toJson*(b: Bookmark): JsonNode =
  result = %*{"id": b.id, "title": b.title}
  if not b.isFolder: result["url"] = %b.url
  result["addedAt"] = %b.addedAt
  result["updatedAt"] = %b.updatedAt
  result["pos"] = newJFloat(b.pos)
  if b.isFolder:
    var kids = newJArray()
    for c in b.children: kids.add toJson(c)
    result["children"] = kids

proc file*(): string =
  let override = getEnv("WEBBY_BOOKMARKS_FILE")
  if override.len > 0: override else: profileFile("bookmarks.json")

proc load() =
  loaded = true
  bar = newFolder("bar", "Bookmarks bar", 0)
  other = newFolder("other", "Other bookmarks", 0)
  let path = file()
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    showBarSetting = if j{"showBar"} != nil: j["showBar"].getBool(true) else: true
    for (root, key) in [(bar, "bar"), (other, "other")]:
      let saved = fromJson(j{"roots", key})
      if saved != nil and saved.isFolder: root.children.add saved.children
    if j{"deleted"} != nil and j["deleted"].kind == JObject:
      for k, v in j["deleted"]:
        if v.kind == JObject: deleted[k] = v.copy
  except CatchableError as e:
    # Keep the unreadable file for the user rather than overwriting it on the next save.
    let aside = path & ".corrupt-" & $(epochTime() * 1000).int64
    try: moveFile(path, aside) except CatchableError: discard
    loadError = "Could not read " & path & " (" & e.msg & "); it was moved to " & aside & "."
    bar.children.setLen 0
    other.children.setLen 0

proc ensureLoaded*() =
  if not loaded: load()

proc save() =
  # An incognito window can open bookmarks but changes there aren't kept (the normal window owns the file).
  if incognito: return
  var j = %*{"version": 1, "showBar": showBarSetting, "roots": {"bar": toJson(bar), "other": toJson(other)}}
  if deleted.len > 0:
    var d = newJObject()
    for k, v in deleted: d[k] = v
    j["deleted"] = d
  try: writeFileAtomic(file(), j.pretty)
  except CatchableError as e: stderr.writeLine "webby: could not write ", file(), ": ", e.msg

proc changed() =
  save()
  for h in changeHooks: h()

proc showBar*(): bool = (ensureLoaded(); showBarSetting)
proc setShowBar*(on: bool) =
  ensureLoaded()
  if on == showBarSetting: return
  showBarSetting = on
  changed()

proc roots*(): seq[Bookmark] = (ensureLoaded(); @[bar, other])

proc base36(n: int64): string =
  const digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  var v = n
  if v == 0: return "0"
  while v > 0:
    result.insert($digits[v mod 36], 0)
    v = v div 36

proc newId(): string =
  result = base36((epochTime() * 1_000_000).int64) & base36(idCounter)
  inc idCounter

proc isRoot*(b: Bookmark): bool = b == bar or b == other

iterator all*(): Bookmark =
  ## Every bookmark and folder except the two roots.
  for r in roots():
    for n in r.descendants:
      if not n.isRoot: yield n

proc folders*(): seq[(Bookmark, int)] =
  ## Every folder, the two roots first, each with its depth below its root.
  proc walk(f: Bookmark, depth: int, acc: var seq[(Bookmark, int)]) =
    acc.add((f, depth))
    for c in f.children:
      if c.isFolder: walk(c, depth + 1, acc)
  for r in roots(): walk(r, 0, result)

proc find*(id: string): Bookmark =
  for r in roots():
    for n in r.descendants:
      if n.id == id: return n

proc parentOf*(node: Bookmark): Bookmark =
  for r in roots():
    for f in r.descendants:
      if f.isFolder and node in f.children: return f

proc bookmarkFor*(url: string): Bookmark =
  ## The first bookmark of `url`, or nil when the page isn't bookmarked.
  if url.len == 0: return nil
  for n in all():
    if not n.isFolder and n.url == url: return n

proc path*(folder: Bookmark): string =
  ## "Bookmarks bar / Docs / Dart" for a folder nested that deep.
  var names: seq[string]
  var n = folder
  while n != nil:
    names.insert(n.title, 0)
    n = parentOf(n)
  names.join(" / ")

proc place(folder, node: Bookmark, index = -1) =
  ## Puts `node` into `folder` at `index`, giving it a position between its new neighbours and marking it edited.
  let at = if index < 0: folder.children.len else: clamp(index, 0, folder.children.len)
  let hasBefore = at > 0
  let hasAfter = at < folder.children.len
  let before = if hasBefore: folder.children[at - 1].pos else: 0.0
  let after = if hasAfter: folder.children[at].pos else: 0.0
  var pos =
    if not hasBefore: (if not hasAfter: 1.0 else: after - 1)
    elif not hasAfter: before + 1
    else: (before + after) / 2
  if hasBefore and hasAfter and not (pos > before and pos < after):
    # Out of room between the two (or they were equal): renumber the folder.
    for i, c in folder.children:
      c.pos = float(if i < at: i + 1 else: i + 2)
      c.updatedAt = now()
    pos = at.float + 1
  node.pos = pos
  node.updatedAt = now()
  folder.children.insert(node, at)

proc add*(title, url: string, parent: Bookmark = nil): Bookmark =
  ensureLoaded()
  result = newLink(newId(), title, url)
  place(if parent == nil: bar else: parent, result)
  changed()

proc addFolder*(title: string, parent: Bookmark = nil): Bookmark =
  ensureLoaded()
  result = newFolder(newId(), title)
  place(if parent == nil: other else: parent, result)
  changed()

proc contains(b, node: Bookmark): bool =
  for d in b.descendants:
    if d == node: return true

proc update*(node: Bookmark, title = "", url = "", parent: Bookmark = nil, setTitle = false) =
  ## Renames, re-points or moves `node` (empty strings leave a field as it is unless `setTitle`). A folder can't
  ## move into itself or one of its own folders.
  if title.len > 0 or setTitle: node.title = title
  if url.len > 0 and not node.isFolder: node.url = url
  node.updatedAt = now()
  if parent != nil and parent.isFolder and not node.isRoot:
    let current = parentOf(node)
    let intoItself = node.isFolder and node.contains(parent)
    if current != nil and current != parent and not intoItself:
      current.children.delete(current.children.find(node))
      place(parent, node)
  changed()

proc reorder*(folder: Bookmark, oldIndex: int, newIndex: int) =
  ## Moves the child at `oldIndex` of `folder` to `newIndex` (in the list as it was before the move).
  if oldIndex notin 0 ..< folder.children.len: return
  let node = folder.children[oldIndex]
  folder.children.delete(oldIndex)
  place(folder, node, if newIndex > oldIndex: newIndex - 1 else: newIndex)
  changed()

proc remove*(node: Bookmark) =
  if node.isRoot: return
  let p = parentOf(node)
  if p != nil: p.children.delete(p.children.find(node))
  for gone in node.descendants: deleted[gone.id] = %*{"updatedAt": now(), "deleted": true}
  changed()

proc importBookmarks*(toBar, toOther: seq[Bookmark]): int =
  ## Adds imported bookmarks: `toBar` goes on the bookmarks bar (skipping links already there), `toOther` into a new
  ## "Imported" folder in Other bookmarks. Returns how many links were added.
  ensureLoaded()
  var count = 0
  proc copy(node: Bookmark, count: var int): Bookmark =
    if not node.isFolder:
      inc count
      return newLink(newId(), node.title, node.url, node.addedAt)
    result = newFolder(newId(), node.title, node.addedAt)
    for c in node.children: place(result, copy(c, count))
  var onBar: HashSet[string]
  for n in bar.children:
    if not n.isFolder: onBar.incl n.url
  for node in toBar:
    if not node.isFolder and node.url in onBar: continue
    place(bar, copy(node, count))
  if toOther.len > 0:
    let folder = newFolder(newId(), "Imported")
    for node in toOther: place(folder, copy(node, count))
    place(other, folder)
  changed()
  count

# ---------------------------------------------------------------------------------------------------------------
# Sync (SyncDoc.bookmarks): a record per bookmark and folder by id, plus tombstones.

proc toSyncRecords*(): JsonNode =
  result = newJObject()
  for k, v in deleted: result[k] = v.copy
  proc walk(folder: Bookmark, records: JsonNode) =
    for n in folder.children:
      var r = %*{"parent": folder.id, "pos": newJFloat(n.pos), "title": n.title}
      if n.isFolder: r["folder"] = %true else: r["url"] = %n.url
      r["addedAt"] = %n.addedAt
      r["updatedAt"] = %n.updatedAt
      records[n.id] = r
      if n.isFolder: walk(n, records)
  for r in roots(): walk(r, result)

proc updatedAtOf(r: JsonNode): int64 =
  let v = r{"updatedAt"}
  if v == nil: 0'i64 elif v.kind == JInt: v.getBiggestInt elif v.kind == JFloat: v.getFloat.int64 else: 0'i64

proc applySyncRecords*(records: JsonNode): bool =
  ## Replaces the bookmarks with merged sync records, keeping the Bookmark objects of ones still there. Returns
  ## whether anything changed.
  if toSyncRecords() == records: return false
  var existing: Table[string, Bookmark]
  for n in all(): existing[n.id] = n
  var nodes: OrderedTable[string, Bookmark]
  var parents: Table[string, string]
  deleted.clear()
  for id, r in records:
    if r{"deleted"}.getBool(false):
      deleted[id] = r.copy
      continue
    let title = r{"title"}.getStr
    let hasUrl = r{"url"} != nil and r["url"].kind == JString
    let isFolder = r{"folder"}.getBool(false) or not hasUrl
    let addedAt = r{"addedAt"}.getBiggestInt(0)
    var node = existing.getOrDefault(id)
    if node == nil or node.isFolder != isFolder:
      node = if isFolder: newFolder(id, title, addedAt) else: newLink(id, title, r["url"].getStr, addedAt)
    node.title = title
    node.url = if isFolder: "" else: r["url"].getStr
    node.pos = r{"pos"}.getFloat(0)
    node.updatedAt = updatedAtOf(r)
    node.children.setLen 0
    nodes[id] = node
    parents[id] = if r{"parent"} != nil: r["parent"].getStr("other") else: "other"
  bar.children.setLen 0
  other.children.setLen 0
  for id, node in nodes:
    let p = parents[id]
    let parent =
      if p == "bar": bar
      elif p == "other": other
      elif p in nodes and nodes[p].isFolder: nodes[p]
      else: other
    parent.children.add node
  # Records that loop are hung on Other bookmarks rather than lost.
  var ids = toSeq(nodes.keys)
  ids.sort()
  for id in ids:
    var reachable = false
    for r in roots():
      for n in r.descendants:
        if n.id == id: reachable = true
    if reachable: continue
    let p = nodes.getOrDefault(parents[id])
    if p != nil:
      let i = p.children.find(nodes[id])
      if i >= 0: p.children.delete(i)
    other.children.add nodes[id]
  proc sortFolder(f: Bookmark) =
    f.children.sort(proc (a, b: Bookmark): int =
      if a.pos != b.pos: cmp(a.pos, b.pos) else: cmp(a.id, b.id))
  sortFolder(bar)
  sortFolder(other)
  for n in nodes.values:
    if n.isFolder: sortFolder(n)
  changed()
  true

# ---------------------------------------------------------------------------------------------------------------
# bookmarks.html (the Netscape bookmark file Firefox, Chrome and Safari export)

proc escapeHtml(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc unescapeHtml(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let semi = s.find(';', i + 1)
      if semi > i + 1 and semi - i <= 12:
        let entity = s[i + 1 ..< semi]
        var rep = ""
        var ok = true
        try:
          if entity.len > 1 and entity[0] == '#' and entity[1] in {'x', 'X'}:
            rep = $Rune(parseHexInt(entity[2 .. ^1]))
          elif entity.len > 1 and entity[0] == '#':
            rep = $Rune(parseInt(entity[1 .. ^1]))
          else:
            case entity.toLowerAscii
            of "amp": rep = "&"
            of "lt": rep = "<"
            of "gt": rep = ">"
            of "quot": rep = "\""
            of "apos": rep = "'"
            of "nbsp": rep = " "
            else: ok = false
        except ValueError: rep = "�"
        if ok:
          result.add rep
          i = semi + 1
          continue
    result.add s[i]
    inc i

proc exportHtml*(): string =
  ## The bookmarks bar becomes the toolbar folder; Other bookmarks' contents go at the top level, as Chrome does.
  var o = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n" &
    "<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->\n" &
    "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n" &
    "<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"
  proc write(o: var string, n: Bookmark, depth: int, toolbar = false) =
    let indent = repeat("    ", depth)
    if n.isFolder:
      let flag = if toolbar: " PERSONAL_TOOLBAR_FOLDER=\"true\"" else: ""
      o.add indent & "<DT><H3 ADD_DATE=\"" & $n.addedAt & "\"" & flag & ">" & escapeHtml(n.title) & "</H3>\n"
      o.add indent & "<DL><p>\n"
      for c in n.children: write(o, c, depth + 1)
      o.add indent & "</DL><p>\n"
    else:
      o.add indent & "<DT><A HREF=\"" & escapeHtml(n.url) & "\" ADD_DATE=\"" & $n.addedAt & "\">" &
        escapeHtml(n.title) & "</A>\n"
  ensureLoaded()
  write(o, bar, 1, toolbar = true)
  for c in other.children: write(o, c, 1)
  o.add "</DL><p>\n"
  o

proc attributes(text: string): Table[string, string] =
  var i = 0
  while i < text.len:
    while i < text.len and text[i] notin {'A'..'Z', 'a'..'z', '_', '-'}: inc i
    let start = i
    while i < text.len and text[i] in {'A'..'Z', 'a'..'z', '_', '-'}: inc i
    let name = text[start ..< i].toUpperAscii
    var j = i
    while j < text.len and text[j] in Whitespace: inc j
    if j < text.len and text[j] == '=':
      inc j
      while j < text.len and text[j] in Whitespace: inc j
      if j < text.len and text[j] in {'"', '\''}:
        let q = text[j]
        let stop = text.find(q, j + 1)
        if stop < 0: break
        result[name] = unescapeHtml(text[j + 1 ..< stop])
        i = stop + 1
        continue
    if i == start: inc i

proc stripTags(s: string): string =
  var inTag = false
  for c in s:
    if c == '<': inTag = true
    elif c == '>' and inTag: inTag = false
    elif not inTag: result.add c

proc parseHtml*(html: string): tuple[toolbar, other: seq[Bookmark]] =
  ## Parses a Netscape bookmark file. It is tag soup rather than HTML, so this only looks at <DL>, <H3> and <A>.
  let top = newFolder("", "")
  let toolbar = newFolder("", "")
  let lower = html.toLowerAscii
  proc textUntil(closing: string, start: int): string =
    let stop = lower.find(closing, start)
    unescapeHtml(stripTags(if stop < 0: html[start .. ^1] else: html[start ..< stop])).strip
  var stack = @[top]
  var pending: Bookmark
  var serial = 0
  var i = 0
  while true:
    i = html.find('<', i)
    if i < 0: break
    var j = i + 1
    let closing = j < html.len and html[j] == '/'
    if closing: inc j
    var k = j
    while k < html.len and html[k] in {'a'..'z', 'A'..'Z', '0'..'9'}: inc k
    let tag = lower[j ..< k]
    let stop = html.find('>', k)
    if stop < 0: break
    if tag notin ["dl", "h3", "a"]:
      i = k
      continue
    let attrText = html[k ..< stop]
    let tagEnd = stop + 1
    i = tagEnd
    if tag == "dl":
      if closing:
        if stack.len > 1: discard stack.pop()
      else:
        stack.add(if pending != nil: pending else: stack[^1])
        pending = nil
    elif not closing and tag == "h3":
      let attrs = attributes(attrText)
      let title = textUntil("</h3", tagEnd)
      if attrs.getOrDefault("PERSONAL_TOOLBAR_FOLDER") == "true":
        pending = toolbar
      else:
        let added = try: parseBiggestInt(attrs.getOrDefault("ADD_DATE")) except ValueError: -1'i64
        pending = newFolder($serial, title, added)
        inc serial
        stack[^1].children.add pending
    elif not closing and tag == "a":
      let attrs = attributes(attrText)
      let url = attrs.getOrDefault("HREF")
      # Firefox's "place:" entries are saved searches, not pages.
      if url.len == 0 or url.startsWith("place:"): continue
      let added = try: parseBiggestInt(attrs.getOrDefault("ADD_DATE")) except ValueError: -1'i64
      stack[^1].children.add newLink($serial, textUntil("</a", tagEnd), url, added)
      inc serial
  (toolbar.children, top.children)
