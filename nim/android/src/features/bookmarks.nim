## Bookmarks on Android (src/features/bookmarks.nim on the desktop): the profile's bookmarks.json
## (features/bookmarks/store.nim, the Flutter app's format). The star in the menu bookmarks the page; the Bookmarks
## screen browses folders, edits, moves and deletes; bookmarks.html imports and exports.

import std/strutils
import ../core
import ../../../src/features/bookmarks/store
import omnibox

proc nodeJson(n: Bookmark): JsonNode =
  result = %*{"id": n.id, "title": n.label, "isFolder": n.isFolder}
  if not n.isFolder:
    result["url"] = %n.url
    result["name"] = %n.title
  else:
    result["count"] = %n.children.len

proc folderArg(args: JsonNode, key = "folder"): Bookmark =
  let id = args{key}.getStr
  if id.len > 0: find(id) else: nil

proc list(args: JsonNode): JsonNode =
  ## {folder: id or ""} -> {folder: {id, title, path}, parent, items}; "" lists the two roots.
  ensureLoaded()
  let f = folderArg(args)
  var items = newJArray()
  if f == nil:
    for r in roots(): items.add nodeJson(r)
    return %*{"folder": nil, "parent": "", "items": items}
  for c in f.children: items.add nodeJson(c)
  let p = parentOf(f)
  %*{"folder": {"id": f.id, "title": f.label, "path": path(f)}, "parent": (if p == nil: "" else: p.id), "items": items}

proc current(args: JsonNode): JsonNode =
  ## The bookmark of the page shown, or null.
  let t = core.current()
  if t == nil: return newJNull()
  let b = bookmarkFor(t.url)
  if b == nil: return newJNull()
  let p = parentOf(b)
  result = nodeJson(b)
  result["parent"] = %(if p == nil: "" else: p.id)
  result["parentPath"] = %(if p == nil: "" else: path(p))

proc bookmarkPage(args: JsonNode): JsonNode =
  ## Bookmarks the page shown (on the bar, as the desktop star does) or returns its bookmark.
  let t = core.current()
  if t == nil or t.url.len == 0 or t.url == homePage: return newJNull()
  if bookmarkFor(t.url) == nil: discard store.add(t.title, t.url)
  current(args)

proc folders(args: JsonNode): JsonNode =
  result = newJArray()
  for (f, depth) in store.folders():
    result.add %*{"id": f.id, "title": f.label, "depth": depth}

proc update(args: JsonNode): JsonNode =
  ## {id, title?, url?, parent?}
  let n = find(args{"id"}.getStr)
  if n == nil: return %false
  store.update(n, title = args{"title"}.getStr, url = args{"url"}.getStr, parent = folderArg(args, "parent"),
    setTitle = args.hasKey("title"))
  sendState()
  %true

proc addOne(args: JsonNode): JsonNode =
  ## {title, url, parent?} or {title, folder: true, parent?}
  let parent = folderArg(args, "parent")
  let n = if args{"folder"}.getBool: store.addFolder(args{"title"}.getStr, parent)
          else: store.add(args{"title"}.getStr, args{"url"}.getStr, parent)
  sendState()
  nodeJson(n)

proc removeOne(args: JsonNode): JsonNode =
  let n = find(args{"id"}.getStr)
  if n != nil and not n.isRoot: store.remove(n)
  sendState()
  nil

proc reorderOne(args: JsonNode): JsonNode =
  let f = folderArg(args)
  if f != nil: store.reorder(f, args{"from"}.getInt, args{"to"}.getInt)
  nil

proc exportHtml(args: JsonNode): JsonNode = %*{"html": store.exportHtml()}

proc importHtml(args: JsonNode): JsonNode =
  let (toolbar, others) = store.parseHtml(args{"html"}.getStr)
  let n = store.importBookmarks(toolbar, others)
  sendState()
  %*{"count": n}

proc links(args: JsonNode): JsonNode =
  ## Every link in a folder and its subfolders, for "Open all".
  result = newJArray()
  let f = folderArg(args)
  if f == nil: return
  for n in f.descendants:
    if not n.isFolder: result.add %n.url

proc bookmarkSuggestions(text: string): seq[Suggestion] =
  let words = text.toLowerAscii.splitWhitespace
  if words.len == 0: return
  for n in all():
    if n.isFolder: continue
    let hay = n.url.toLowerAscii & " " & n.title.toLowerAscii
    var ok = true
    for w in words:
      if w notin hay: ok = false
    if ok:
      result.add Suggestion(title: n.title, url: n.url, kind: "bookmark")
      if result.len >= 3: return

proc install*() =
  stateHooks.add proc (t: Tab, state: JsonNode) =
    state["bookmarked"] = %(t != nil and bookmarkFor(t.url) != nil)
  suggestionProviders.add bookmarkSuggestions
  commands["bookmarks.list"] = list
  commands["bookmarks.current"] = current
  commands["bookmarks.bookmarkPage"] = bookmarkPage
  commands["bookmarks.folders"] = folders
  commands["bookmarks.update"] = update
  commands["bookmarks.add"] = addOne
  commands["bookmarks.remove"] = removeOne
  commands["bookmarks.reorder"] = reorderOne
  commands["bookmarks.exportHtml"] = exportHtml
  commands["bookmarks.importHtml"] = importHtml
  commands["bookmarks.links"] = links
  changeHooks.add proc () = sendState()
