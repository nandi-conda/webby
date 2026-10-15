## Bookmarks (app/lib/src/bookmarks): the star in the URL bar and Ctrl+D bookmark the page and open its editor, the
## bookmarks bar under the toolbar (Ctrl+Shift+B) opens them, and the bookmark manager sidebar (Ctrl+Shift+O, the
## toolbar's bookmarks button) browses, searches, edits, reorders, imports and exports them. Items drag to reorder
## on the bar and in the manager. The address bar gets matching bookmarks.

import std/strutils
import ../browser
from nimkit/core as kit import nil
import bookmarks/store
export store

var
  starButton: kit.Widget
  barRow, barRoot: kit.Widget
  managerOpen = false
  managerFolder: Bookmark
  managerSearch, managerTree, managerList: kit.Widget
  refreshQueued = false

proc dragged(data: string): Bookmark =
  ## The bookmark a drag carries (its id), if it still exists.
  if data.len > 0: find(data) else: nil

# ---------------------------------------------------------------------------------------------------------------
# Opening

proc goUrl(url: string) =
  let t = currentTab()
  if t == nil: discard openTab(url)
  else:
    t.loadUrl(url)
    focusPage()

proc openInBackground(url: string) =
  if tabs.len > 0: discard openTab(url, focus = false, index = activeIndex + 1)
  else: discard openTab(url)

proc opener(url: string): proc () =
  ## A closure of its own per URL (closures made in a loop would share the loop's variables).
  result = proc () = goUrl(url)

proc links(node: Bookmark): seq[Bookmark] =
  for n in node.descendants:
    if not n.isFolder: result.add n

# ---------------------------------------------------------------------------------------------------------------
# Dialogs (bookmark_dialog.dart)

proc labeled(box: kit.Widget, label: string, w: kit.Widget) =
  let l = kit.label(label)
  discard kit.sized(l, 60)
  let r = kit.row(l, kit.expand(w))
  r.spacing = 10
  kit.add(box, r)

proc editBookmark*(node: Bookmark, justAdded = false) =
  ## Edits `node`'s name, address and folder, or removes it.
  let heading = if node.isFolder: "Edit folder" elif justAdded: "Bookmark added" else: "Edit bookmark"
  let box = kit.column()
  box.spacing = 8
  discard kit.sized(box, 420)
  let title = kit.entry(text = node.title)
  labeled(box, "Name", title)
  var url: kit.Widget
  if not node.isFolder:
    url = kit.entry(text = node.url)
    labeled(box, "URL", url)
  # A folder can't go inside itself.
  var choices: seq[Bookmark]
  var combo: kit.Widget
  let parent = parentOf(node)
  if not node.isRoot and parent != nil:
    var names: seq[string]
    for (f, _) in folders():
      var inside = false
      if node.isFolder:
        for n in node.descendants:
          if n == f: inside = true
      if inside: continue
      choices.add f
      names.add path(f)
    combo = kit.dropdown(names, choices.find(parent))
    labeled(box, "Folder", combo)
  var buttons: seq[string]
  var removeAt, cancelAt = -1
  if not node.isRoot:
    removeAt = buttons.len
    buttons.add "Remove"
  if not justAdded:
    cancelAt = buttons.len
    buttons.add "Cancel"
  let doneAt = buttons.len
  buttons.add "Done"
  var d: kit.Dialog
  d = kit.dialog(heading, box, buttons, destructive = removeAt, onResult = proc (r: int) =
    if r == removeAt and r >= 0: remove(node)
    elif r == doneAt:
      let i = if combo != nil: kit.selected(combo) else: -1
      update(node, title = kit.text(title).strip, setTitle = true,
        url = if url != nil: kit.text(url).strip else: "",
        parent = if i in 0 ..< choices.len: choices[i] else: nil))
  for e in [title, url]:
    if e != nil: e.onSubmit = proc (t: string) = kit.dialogResult(d, doneAt)
  kit.focus(title)

proc bookmarkPage*() =
  ## Bookmarks the page (or opens its existing bookmark) and shows the editor, as the star and Ctrl+D do.
  let t = currentTab()
  if incognito or t == nil or t.url.len == 0: return
  let existing = bookmarkFor(t.url)
  let node = if existing != nil: existing else: add(if t.title.len > 0: t.title else: t.url, t.url)
  editBookmark(node, justAdded = existing == nil)

proc newFolderIn(parent: Bookmark) =
  kit.prompt("New folder", "Name", "New folder", proc (ok: bool, name: string) =
    if ok and name.strip.len > 0: discard addFolder(name.strip, parent))

proc confirmDelete(node: Bookmark, onYes: proc ()) =
  if not node.isFolder or node.children.len == 0:
    onYes()
    return
  let n = links(node).len
  kit.confirm("Delete \"" & node.label & "\"?",
    "The folder and the " & $n & " bookmark" & (if n == 1: "" else: "s") & " in it will be deleted.", "Delete",
    destructive = true, onResult = proc (ok: bool) = (if ok: onYes()))

const bookmarkFiles = @["*.html", "*.htm"]

proc importFile() =
  kit.chooseFile("Import bookmarks", patterns = bookmarkFiles, filterName = "Bookmark files (bookmarks.html)",
    onDone = proc (path: string) =
      if path.len == 0: return
      try:
        let parsed = parseHtml(readFile(path))
        let n = importBookmarks(parsed.toolbar, parsed.other)
        kit.alert("Imported " & $n & " bookmark" & (if n == 1: "" else: "s") & " from " & path)
      except CatchableError as e:
        kit.alert("Could not import " & path, e.msg))

proc exportFile() =
  kit.chooseFile("Export bookmarks", save = true, name = "bookmarks.html", patterns = bookmarkFiles,
    filterName = "Bookmark files (bookmarks.html)", onDone = proc (path: string) =
      if path.len == 0: return
      try:
        writeFile(path, exportHtml())
        kit.alert("Exported bookmarks to " & path)
      except CatchableError as e:
        kit.alert("Could not export to " & path, e.msg))

# ---------------------------------------------------------------------------------------------------------------
# The bookmarks bar (bookmark_bar.dart)

proc folderMenu(folder: Bookmark): seq[kit.MenuItem] =
  ## Links in `folder` and its subfolders, each subfolder's links labelled with its path.
  var items: seq[kit.MenuItem]
  var any = false
  proc fill(items: var seq[kit.MenuItem], f: Bookmark, prefix: string, any: var bool) =
    for c in f.children:
      if c.isFolder:
        if links(c).len == 0: continue
        if any: items.add kit.menuSeparator()
        fill(items, c, prefix & c.label & " / ", any)
      else:
        items.add kit.menuItem(prefix & c.label, opener(c.url))
        any = true
  fill(items, folder, "", any)
  if not any: items.add kit.menuItem("(empty)", proc () = discard, enabled = false)
  items

proc itemMenu(node: Bookmark): seq[kit.MenuItem] =
  ## Right-click on a bar item.
  if not node.isFolder:
    let url = node.url
    result.add kit.menuItem("Open in new tab", proc () = openInBackground(url))
    result.add kit.menuSeparator()
  else:
    let ls = links(node)
    if ls.len > 0:
      result.add kit.menuItem(if ls.len == 1: "Open in new tab" else: "Open all " & $ls.len & " in new tabs", proc () =
        # Each new tab goes right after the current one, so add them last first to keep the folder order.
        for i in countdown(ls.high, 0): openInBackground(ls[i].url))
      result.add kit.menuSeparator()
  result.add kit.menuItem("Edit…", proc () = editBookmark(node))
  result.add kit.menuItem("Delete", proc () = remove(node))

proc dropOnBar(target: Bookmark, data: string, x: float) =
  ## The left or right half of an item places the dragged one before or after it; the middle half of a folder moves
  ## it into the folder.
  let dragged = dragged(data)
  if dragged == nil or dragged == target: return
  if target.isFolder and x > 0.25 and x < 0.75:
    update(dragged, parent = target)
    return
  let to = bar.children.find(target) + (if x >= 0.5: 1 else: 0)
  let source = bar.children.find(dragged)
  if source < 0:
    update(dragged, parent = bar)
    let moved = bar.children.find(dragged)
    if moved >= 0: reorder(bar, moved, to)
  else:
    reorder(bar, source, to)

proc barItem(node: Bookmark): kit.Widget =
  let l = kit.label(node.label)
  kit.`maxChars=`(l, 24)
  var b: kit.Widget
  b = kit.item(kit.icon(if node.isFolder: "folder_outlined" else: "public", 14), l, onClick = proc () =
    # Folders open their menu under the button.
    if node.isFolder: kit.popupMenu(folderMenu(node), b)
    else: goUrl(node.url))
  b.spacing = 6
  kit.addClass(b, "webby-bookmark")
  if not node.isFolder: kit.`tooltip=`(b, node.label & "\n" & node.url)
  # Middle-click opens a link in a new tab, as in other browsers.
  b.onMiddle = proc () = (if not node.isFolder: openInBackground(node.url))
  b.onContext = proc () = kit.popupMenu(itemMenu(node))
  kit.`dragData=`(b, node.id)
  kit.`onDrop=`(b, proc (data: string, x, y: float) = dropOnBar(node, data, x))
  b

proc fillBar() =
  if barRow == nil: return
  kit.clear(barRow)
  kit.`visible=`(barRoot, showBar())
  if bar.children.len == 0:
    kit.add(barRow, kit.addClass(kit.addClass(kit.label(
      "Bookmark pages with the star in the address bar or Ctrl+D; they show up here."), "dim"), "webby-bar-hint"))
  for node in bar.children: kit.add(barRow, barItem(node))

proc buildBar() =
  barRow = kit.row()
  barRow.spacing = 2
  # The bar's empty end: dropping there moves the item to the end.
  kit.`onDrop=`(barRow, proc (data: string, x, y: float) =
    let d = dragged(data)
    if d == nil: return
    let i = bar.children.find(d)
    if i >= 0: reorder(bar, i, bar.children.len)
    else: update(d, parent = bar))
  barRoot = kit.addClass(kit.scroll(barRow, horizontal = true), "webby-bookmark-bar")
  kit.`visible=`(barRoot, false)
  kit.add(barSlot, barRoot)
  fillBar()

# ---------------------------------------------------------------------------------------------------------------
# The bookmark manager sidebar (bookmarks_page.dart)

proc fillManager()

proc openFolder(f: Bookmark) =
  managerFolder = f
  if managerSearch != nil: kit.setTextSilently(managerSearch, "")
  fillManager()

proc deleteNode(node: Bookmark) =
  confirmDelete(node, proc () =
    var inside = false
    for n in node.descendants:
      if n == managerFolder: inside = true
    if inside:
      managerFolder = parentOf(node)
      if managerFolder == nil: managerFolder = bar
    remove(node))

proc oneLine(text: string): kit.Widget =
  result = kit.label(text)
  kit.`maxChars=`(result, 200)

proc smallButton(icon, tooltip: string, action: proc ()): kit.Widget = kit.iconButton(icon, tooltip, action, 14)

proc activation(node: Bookmark): proc () =
  ## Clicking a row: a folder opens in the manager, a link in the current tab.
  result = proc () = (if node.isFolder: openFolder(node) else: goUrl(node.url))

proc dropInManager(node: Bookmark, data: string, y: float) =
  ## Drag a row onto another: the top or bottom half places it before or after, the middle of a folder moves it in.
  let dragged = dragged(data)
  if dragged == nil or dragged == node: return
  if node.isFolder and y > 0.25 and y < 0.75:
    update(dragged, parent = node)
    return
  let folder = managerFolder
  let to = folder.children.find(node) + (if y >= 0.5: 1 else: 0)
  let source = folder.children.find(dragged)
  if source >= 0: reorder(folder, source, to)
  else:
    update(dragged, parent = folder)
    let moved = folder.children.find(dragged)
    if moved >= 0: reorder(folder, moved, to)

proc managerRow(node: Bookmark, reorderable: bool): kit.Widget =
  let n = node.children.len
  let text = kit.column(oneLine(node.label), kit.addClass(kit.addClass(
    oneLine(if node.isFolder: $n & " item" & (if n == 1: "" else: "s") else: node.url), "dim"), "small"))
  result = kit.item(kit.icon(if node.isFolder: "folder_outlined" else: "public", 18), kit.expand(text),
    smallButton("edit_outlined", "Edit", proc () = editBookmark(node)),
    smallButton("delete_outline", "Delete", proc () = deleteNode(node)), onClick = activation(node))
  result.spacing = 10
  kit.addClass(result, "webby-manager-row")
  result.onMiddle = proc () = (if not node.isFolder: openInBackground(node.url))
  result.onContext = proc () = kit.popupMenu(itemMenu(node))
  kit.`dragData=`(result, node.id)
  if reorderable: kit.`onDrop=`(result, proc (data: string, x, y: float) = dropInManager(node, data, y))

proc emptyLabel(text: string): kit.Widget = kit.addClass(kit.addClass(kit.label(text), "dim"), "webby-manager-empty")

proc folderRow(f: Bookmark, depth: int): kit.Widget =
  ## A folder in the manager's tree; dropping a bookmark on it moves the bookmark in.
  let name = if f == bar: "bookmarks_outlined" elif f == managerFolder: "folder_open" else: "folder_outlined"
  result = kit.item(kit.icon(name), kit.expand(oneLine(f.label)), onClick = activation(f))
  result.spacing = 8
  result.padding = 0
  kit.addClass(result, "webby-folder-row")
  kit.addClass(result, "webby-depth-" & $min(depth, 6))
  kit.setClass(result, "selected", f == managerFolder)
  kit.`onDrop=`(result, proc (data: string, x, y: float) =
    let d = dragged(data)
    if d != nil and d != f: update(d, parent = f))

proc fillManager() =
  if managerList == nil: return
  # The open folder may have been deleted elsewhere.
  if managerFolder == nil or find(managerFolder.id) == nil: managerFolder = bar
  let query = kit.text(managerSearch).strip.toLowerAscii
  kit.clear(managerTree)
  for (f, depth) in folders(): kit.add(managerTree, folderRow(f, depth))
  kit.clear(managerList)
  if query.len > 0:
    var found = 0
    for n in all():
      if query in n.title.toLowerAscii or (not n.isFolder and query in n.url.toLowerAscii):
        kit.add(managerList, managerRow(n, false))
        inc found
    if found == 0: kit.add(managerList, emptyLabel("No bookmarks match."))
  elif managerFolder.children.len == 0:
    kit.add(managerList, emptyLabel(if managerFolder == bar:
      "No bookmarks yet. Bookmark a page with the star in the address bar or Ctrl+D." else: "This folder is empty."))
  else:
    for n in managerFolder.children: kit.add(managerList, managerRow(n, true))

proc showManager*() =
  closeSidePanel()
  ensureLoaded()
  if managerFolder == nil: managerFolder = bar
  let body = kit.column()
  body.spacing = 4
  if loadError.len > 0: kit.add(body, kit.addClass(kit.label(loadError), "error"))
  managerSearch = kit.entry("Search bookmarks", onChange = proc (t: string) = fillManager())
  var more: kit.Widget
  more = kit.iconButton("more_vert", "More", proc () =
    kit.popupMenu(@[kit.menuItem("Import bookmarks.html…", importFile),
                    kit.menuItem("Export bookmarks.html…", exportFile),
                    kit.menuSeparator(),
                    kit.checkItem("Show bookmarks bar", showBar(), proc () = setShowBar(not showBar()))], more))
  let top = kit.addClass(kit.row(kit.expand(managerSearch),
    kit.iconButton("create_new_folder_outlined", "New folder", proc () = newFolderIn(managerFolder)), more),
    "webby-panel-top")
  top.spacing = 2
  kit.add(body, top)
  managerTree = kit.column()
  kit.add(body, kit.sized(kit.scroll(managerTree), 0, 160))
  kit.add(body, kit.separator())
  managerList = kit.column()
  kit.add(body, kit.expand(kit.scroll(managerList)))
  managerOpen = true
  showSidePanel("Bookmarks", body, 400, proc () =
    managerOpen = false
    managerSearch = nil
    managerTree = nil
    managerList = nil)
  fillManager()

proc toggleManager() =
  if managerOpen: closeSidePanel() else: showManager()

# ---------------------------------------------------------------------------------------------------------------

proc updateStar() =
  if starButton == nil: return
  let t = currentTab()
  let marked = t != nil and bookmarkFor(t.url) != nil
  kit.`iconName=`(starButton, if marked: "star" else: "star_border")
  kit.`tooltip=`(starButton, if marked: "Edit bookmark (Ctrl+D)" else: "Bookmark this page (Ctrl+D)")
  kit.setClass(starButton, "webby-starred", marked)
  kit.`enabled=`(starButton, t != nil and t.url.len > 0)

proc refresh() =
  ## Bookmarks changed: redraw what shows them, once per main-loop turn.
  if refreshQueued: return
  refreshQueued = true
  discard after(0, proc () =
    refreshQueued = false
    fillBar()
    updateStar()
    if managerOpen: fillManager())

proc bookmarkSuggestions(text: string): seq[Suggestion] =
  ## Bookmarks whose name or address contain every typed word.
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

proc buildChrome() =
  if appUrl.len > 0: return
  ensureLoaded()
  loadCss(".webby-star { padding: 0 4px; min-height: 0; }\n" &
    ".webby-starred * { color: @theme_selected_bg_color; }\n" &
    "button.webby-bookmark { padding: 2px 6px; min-height: 0; }\n" &
    ".webby-bookmark-bar { border-bottom: 1px solid alpha(currentColor, 0.12); padding-left: 4px; }\n" &
    ".webby-bar-hint { margin: 5px 4px; }\n" &
    "button.webby-manager-row { padding: 4px 4px 4px 10px; }\n" &
    ".webby-manager-row button { padding: 2px; min-height: 0; }\n" &
    ".webby-manager-empty { margin: 24px 12px 0 12px; }\n" &
    "button.webby-folder-row { padding: 3px 4px 3px 12px; min-height: 0; }\n" &
    "button.webby-depth-1 { padding-left: 28px; } button.webby-depth-2 { padding-left: 44px; }\n" &
    "button.webby-depth-3 { padding-left: 60px; } button.webby-depth-4 { padding-left: 76px; }\n" &
    "button.webby-depth-5 { padding-left: 92px; } button.webby-depth-6 { padding-left: 108px; }\n" &
    ".webby-panel-top { margin: 0 4px 0 8px; }")
  # Incognito windows don't bookmark pages.
  if not incognito:
    starButton = kit.iconButton("star_border", "Bookmark this page (Ctrl+D)", bookmarkPage, 16)
    kit.addClass(starButton, "webby-star")
    kit.add(starSlotRow, starButton)
  discard addToolbarButton("bookmarks_outlined", "Bookmarks (Ctrl+Shift+O)", toggleManager, "bookmarks", "Bookmarks")
  buildBar()
  if not incognito: addMenuItem("Bookmark this page", bookmarkPage, "Ctrl+D")
  addMenuCheck("Show bookmarks bar", showBar, proc () = setShowBar(not showBar()), "Ctrl+Shift+B")
  addMenuSeparator()
  addMenuItem("Bookmark manager", showManager, "Ctrl+Shift+O")
  updateStar()

proc install*() =
  changeHooks.add refresh
  activeTabHooks.add proc (t: Tab) = updateStar()
  tabStateHooks.add proc (t: Tab) = (if t == currentTab(): updateStar())
  suggestionProviders.add bookmarkSuggestions
  addShortcut(modCtrl, 0x64, bookmarkPage)                                   # Ctrl+D
  addShortcut(modCtrl or modShift, 0x62, proc () = setShowBar(not showBar()))  # Ctrl+Shift+B
  addShortcut(modCtrl or modShift, 0x6f, showManager)                        # Ctrl+Shift+O
  windowHooks.add buildChrome
