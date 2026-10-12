## Bookmarks (app/lib/src/bookmarks): the star in the URL bar and Ctrl+D bookmark the page and open its editor, the
## bookmarks bar under the toolbar (Ctrl+Shift+B) opens them, and the bookmark manager sidebar (Ctrl+Shift+O, the
## toolbar's bookmarks button) browses, searches, edits, reorders, imports and exports them. Items drag to reorder
## on the bar and in the manager. The address bar gets matching bookmarks.

import std/strutils
import ../browser
import bookmarks/store
export store

type
  GtkTargetEntry = object
    target: cstring
    flags, info: cuint

  Cb = ref object
    ## A Nim closure behind a GTK signal; freed with the handler.
    action: proc ()
    press: proc (ev: GEvent): bool
    drop: proc (x, y, width, height: int)
    node: Bookmark

{.push cdecl, importc.}
proc gtk_combo_box_text_new(): Widget
proc gtk_combo_box_text_append_text(c: Widget, text: cstring)
proc gtk_combo_box_set_active(c: Widget, i: cint)
proc gtk_combo_box_get_active(c: Widget): cint
proc gtk_accel_label_set_accel(l: Widget, key: cuint, mods: cuint)
proc gtk_scrolled_window_set_propagate_natural_height(s: Widget, on: gboolean)
proc gtk_scrolled_window_set_max_content_height(s: Widget, h: cint)
proc gtk_drag_source_set(w: Widget, mask: cuint, targets: ptr GtkTargetEntry, n: cint, actions: cint)
proc gtk_drag_dest_set(w: Widget, flags: cint, targets: ptr GtkTargetEntry, n: cint, actions: cint)
proc gtk_selection_data_set(sel: pointer, kind: pointer, format: cint, data: cstring, len: cint)
proc gtk_selection_data_get_target(sel: pointer): pointer
proc gtk_dialog_get_widget_for_response(d: Widget, r: cint): Widget
proc gtk_list_box_row_set_activatable(r: Widget, on: gboolean)
proc g_object_set_data_full(o: pointer, key: cstring, data: pointer, destroy: pointer)
{.pop.}

const
  GTK_POLICY_EXTERNAL = 3.cint
  GDK_ACTION_MOVE = 4.cint
  GTK_DEST_DEFAULT_ALL = 7.cint
  responseRemove = 1.cint

var
  dragTarget = GtkTargetEntry(target: "webby/bookmark", flags: 1, info: 0)  # GTK_TARGET_SAME_APP
  dragging: Bookmark              ## the bookmark being dragged, if any
  starButton, barBox, barScroller, barCheck: Widget
  barCheckHandler: culong
  managerOpen = false
  managerFolder: Bookmark
  managerSearch, managerTree, managerList: Widget
  refreshQueued = false

# ---------------------------------------------------------------------------------------------------------------
# Signals with Nim closures

proc freeCb(data: pointer, closure: pointer) {.cdecl.} = GC_unref(cast[Cb](data))

proc hold(cb: Cb): pointer =
  GC_ref(cb)
  cast[pointer](cb)

proc onAction(w: Widget, action: proc (), signal = "clicked") =
  discard g_signal_connect_data(w, signal.cstring,
    proc (w: Widget, d: pointer) {.cdecl.} = cast[Cb](d).action(), hold(Cb(action: action)), freeCb, 0)

proc onPress(w: Widget, press: proc (ev: GEvent): bool) =
  ## button-press-event; `press` returns whether it handled the click.
  discard g_signal_connect_data(w, "button-press-event",
    proc (w: Widget, ev: GEvent, d: pointer): gboolean {.cdecl.} =
      (if gdk_event_get_event_type(ev) == GDK_BUTTON_PRESS: cast[Cb](d).press(ev).gboolean else: 0),
    hold(Cb(press: press)), freeCb, 0)

proc button(ev: GEvent): cuint = discard gdk_event_get_button(ev, addr result)

proc dragSource(w: Widget, node: Bookmark) =
  ## Lets `w` be dragged as `node`.
  gtk_drag_source_set(w, GDK_BUTTON1_MASK.cuint, addr dragTarget, 1, GDK_ACTION_MOVE)
  discard g_signal_connect_data(w, "drag-begin",
    proc (w: Widget, ctx: pointer, d: pointer) {.cdecl.} = dragging = cast[Cb](d).node, hold(Cb(node: node)), freeCb, 0)
  discard g_signal_connect_data(w, "drag-data-get",
    proc (w: Widget, ctx, sel: pointer, info, time: cuint, d: pointer) {.cdecl.} =
      let id = cast[Cb](d).node.id
      gtk_selection_data_set(sel, gtk_selection_data_get_target(sel), 8, id.cstring, id.len.cint),
    hold(Cb(node: node)), freeCb, 0)
  discard g_signal_connect_data(w, "drag-end",
    proc (w: Widget, ctx: pointer, d: pointer) {.cdecl.} = dragging = nil, nil, nil, 0)

proc dropTarget(w: Widget, drop: proc (x, y, width, height: int)) =
  ## Calls `drop` with the drop point when a bookmark is dropped on `w` (the bookmark is in `dragging`).
  gtk_drag_dest_set(w, GTK_DEST_DEFAULT_ALL, addr dragTarget, 1, GDK_ACTION_MOVE)
  discard g_signal_connect_data(w, "drag-data-received",
    proc (w: Widget, ctx: pointer, x, y: cint, sel: pointer, info, time: cuint, d: pointer) {.cdecl.} =
      if dragging != nil:
        cast[Cb](d).drop(x, y, gtk_widget_get_allocated_width(w), gtk_widget_get_allocated_height(w)),
    hold(Cb(drop: drop)), freeCb, 0)

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

proc labeled(grid: Widget, row: int, label: string, w: Widget) =
  let l = gtk_label_new(label.cstring)
  gtk_label_set_xalign(l, 1)
  gtk_grid_attach(grid, l, 0, row.cint, 1, 1)
  gtk_widget_set_hexpand(w, 1)
  gtk_grid_attach(grid, w, 1, row.cint, 1, 1)

proc editBookmark*(node: Bookmark, justAdded = false) =
  ## Edits `node`'s name, address and folder, or removes it.
  let heading = if node.isFolder: "Edit folder" elif justAdded: "Bookmark added" else: "Edit bookmark"
  let d = gtk_dialog_new_with_buttons(heading.cstring, window, GTK_DIALOG_MODAL, nil)
  if not node.isRoot:
    addClass(gtk_dialog_add_button(d, "_Remove", responseRemove), "destructive-action")
  if not justAdded: discard gtk_dialog_add_button(d, "_Cancel", GTK_RESPONSE_CANCEL)
  addClass(gtk_dialog_add_button(d, "_Done", GTK_RESPONSE_OK), "suggested-action")
  gtk_dialog_set_default_response(d, GTK_RESPONSE_OK)
  gtk_window_set_default_size(d, 440, -1)
  let grid = gtk_grid_new()
  gtk_grid_set_row_spacing(grid, 8)
  gtk_grid_set_column_spacing(grid, 10)
  gtk_container_set_border_width(grid, 12)
  gtk_box_pack_start(gtk_dialog_get_content_area(d), grid, 1, 1, 0)
  let title = gtk_entry_new()
  gtk_entry_set_text(title, node.title.cstring)
  gtk_entry_set_activates_default(title, 1)
  labeled(grid, 0, "Name", title)
  var url: Widget
  if not node.isFolder:
    url = gtk_entry_new()
    gtk_entry_set_text(url, node.url.cstring)
    gtk_entry_set_activates_default(url, 1)
    labeled(grid, 1, "URL", url)
  # A folder can't go inside itself.
  var choices: seq[Bookmark]
  var combo: Widget
  let parent = parentOf(node)
  if not node.isRoot and parent != nil:
    combo = gtk_combo_box_text_new()
    for (f, _) in folders():
      var inside = false
      if node.isFolder:
        for n in node.descendants:
          if n == f: inside = true
      if inside: continue
      choices.add f
      gtk_combo_box_text_append_text(combo, path(f).cstring)
    gtk_combo_box_set_active(combo, choices.find(parent).cint)
    labeled(grid, 2, "Folder", combo)
  gtk_widget_show_all(d)
  gtk_widget_grab_focus(title)
  let r = gtk_dialog_run(d)
  if r == responseRemove:
    remove(node)
  elif r == GTK_RESPONSE_OK:
    let i = if combo != nil: gtk_combo_box_get_active(combo).int else: -1
    update(node, title = ($gtk_entry_get_text(title)).strip, setTitle = true,
      url = if url != nil: ($gtk_entry_get_text(url)).strip else: "",
      parent = if i in 0 ..< choices.len: choices[i] else: nil)
  gtk_widget_destroy(d)

proc bookmarkPage*() =
  ## Bookmarks the page (or opens its existing bookmark) and shows the editor, as the star and Ctrl+D do.
  let t = currentTab()
  if incognito or t == nil or t.url.len == 0: return
  let existing = bookmarkFor(t.url)
  let node = if existing != nil: existing else: add(if t.title.len > 0: t.title else: t.url, t.url)
  editBookmark(node, justAdded = existing == nil)

proc newFolderIn(parent: Bookmark) =
  let (ok, name) = askText("New folder", "Name", "New folder")
  if ok and name.strip.len > 0: discard addFolder(name.strip, parent)

proc confirmDelete(node: Bookmark): bool =
  if not node.isFolder or node.children.len == 0: return true
  let n = links(node).len
  confirm("Delete \"" & node.label & "\"?",
    "The folder and the " & $n & " bookmark" & (if n == 1: "" else: "s") & " in it will be deleted.")

proc chooseFile(title: string, save: bool): string =
  let d = gtk_file_chooser_dialog_new(title.cstring, window,
    if save: GTK_FILE_CHOOSER_ACTION_SAVE else: GTK_FILE_CHOOSER_ACTION_OPEN,
    "_Cancel", GTK_RESPONSE_CANCEL, (if save: "_Export" else: "_Import").cstring, GTK_RESPONSE_ACCEPT, nil)
  let filter = gtk_file_filter_new()
  gtk_file_filter_set_name(filter, "Bookmark files (bookmarks.html)")
  gtk_file_filter_add_pattern(filter, "*.html")
  gtk_file_filter_add_pattern(filter, "*.htm")
  gtk_file_chooser_add_filter(d, filter)
  if save:
    gtk_file_chooser_set_current_name(d, "bookmarks.html")
    gtk_file_chooser_set_do_overwrite_confirmation(d, 1)
  if gtk_dialog_run(d) == GTK_RESPONSE_ACCEPT:
    let p = gtk_file_chooser_get_filename(d)
    result = $p
    g_free(p)
  gtk_widget_destroy(d)

proc importFile() =
  let path = chooseFile("Import bookmarks", save = false)
  if path.len == 0: return
  try:
    let parsed = parseHtml(readFile(path))
    let n = importBookmarks(parsed.toolbar, parsed.other)
    alert("Imported " & $n & " bookmark" & (if n == 1: "" else: "s") & " from " & path)
  except CatchableError as e:
    alert("Could not import " & path, e.msg)

proc exportFile() =
  let path = chooseFile("Export bookmarks", save = true)
  if path.len == 0: return
  try:
    writeFile(path, exportHtml())
    alert("Exported bookmarks to " & path)
  except CatchableError as e:
    alert("Could not export to " & path, e.msg)

# ---------------------------------------------------------------------------------------------------------------
# The bookmarks bar (bookmark_bar.dart)

proc folderMenu(folder: Bookmark): Widget =
  ## Links in `folder` and its subfolders, each subfolder's links labelled with its path.
  result = gtk_menu_new()
  var any = false
  proc fill(menu: Widget, f: Bookmark, prefix: string, any: var bool) =
    for c in f.children:
      if c.isFolder:
        if links(c).len == 0: continue
        if any: menuSeparator(menu)
        fill(menu, c, prefix & c.label & " / ", any)
      else:
        menuItem(menu, prefix & c.label, opener(c.url))
        any = true
  fill(result, folder, "", any)
  if not any: gtk_widget_set_sensitive(menuItem(result, "(empty)", proc () = discard), 0)

proc itemMenu(node: Bookmark): Widget =
  ## Right-click on a bar item.
  result = gtk_menu_new()
  if not node.isFolder:
    let url = node.url
    menuItem(result, "Open in new tab", proc () = openInBackground(url))
    menuSeparator(result)
  else:
    let ls = links(node)
    if ls.len > 0:
      menuItem(result, if ls.len == 1: "Open in new tab" else: "Open all " & $ls.len & " in new tabs", proc () =
        # Each new tab goes right after the current one, so add them last first to keep the folder order.
        for i in countdown(ls.high, 0): openInBackground(ls[i].url))
      menuSeparator(result)
  menuItem(result, "Edit…", proc () = editBookmark(node))
  menuItem(result, "Delete", proc () = remove(node))

proc popup(menu, anchor: Widget, ev: GEvent) =
  gtk_menu_attach_to_widget(menu, anchor, nil)
  gtk_widget_show_all(menu)
  gtk_menu_popup_at_pointer(menu, ev)

proc dropOnBar(target: Bookmark, x, width: int) =
  ## The left or right half of an item places the dragged one before or after it; the middle half of a folder moves
  ## it into the folder.
  let dragged = dragging
  if dragged == nil or dragged == target: return
  let f = x / max(width, 1)
  if target.isFolder and f > 0.25 and f < 0.75:
    update(dragged, parent = target)
    return
  let to = bar.children.find(target) + (if f >= 0.5: 1 else: 0)
  let source = bar.children.find(dragged)
  if source < 0:
    update(dragged, parent = bar)
    let moved = bar.children.find(dragged)
    if moved >= 0: reorder(bar, moved, to)
  else:
    reorder(bar, source, to)

proc barItem(node: Bookmark): Widget =
  let b = gtk_button_new()
  gtk_button_set_relief(b, GTK_RELIEF_NONE)
  addClass(b, "webby-bookmark")
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
  gtk_box_pack_start(box, gtk_image_new_from_icon_name(
    cstring(if node.isFolder: "folder-symbolic" else: "web-browser-symbolic"), GTK_ICON_SIZE_MENU), 0, 0, 0)
  let l = gtk_label_new(node.label.cstring)
  gtk_label_set_ellipsize(l, PANGO_ELLIPSIZE_END)
  gtk_label_set_max_width_chars(l, 24)
  gtk_box_pack_start(box, l, 0, 0, 0)
  gtk_container_add(b, box)
  if not node.isFolder: gtk_widget_set_tooltip_text(b, cstring(node.label & "\n" & node.url))
  onPress(b, proc (ev: GEvent): bool =
    case button(ev)
    of 1:
      if node.isFolder:
        # Folders open their menu under the button on a left click.
        let menu = folderMenu(node)
        gtk_menu_attach_to_widget(menu, b, nil)
        gtk_widget_show_all(menu)
        gtk_menu_popup_at_widget(menu, b, 7, 1, ev)    # GDK_GRAVITY_SOUTH_WEST / NORTH_WEST
        return true
      false
    of 2:
      # Middle-click opens a link in a new tab, as in other browsers.
      if not node.isFolder: openInBackground(node.url)
      true
    of 3:
      popup(itemMenu(node), b, ev)
      true
    else: false)
  if not node.isFolder: onAction(b, proc () = goUrl(node.url))
  dragSource(b, node)
  dropTarget(b, proc (x, y, w, h: int) = dropOnBar(node, x, w))
  b

proc fillBar() =
  if barBox == nil: return
  clearChildren(barBox)
  gtk_widget_set_visible(barScroller, showBar().gboolean)
  if bar.children.len == 0:
    let hint = gtk_label_new("Bookmark pages with the star in the address bar or Ctrl+D; they show up here.")
    addClass(hint, "dim-label")
    gtk_widget_set_margin_start(hint, 8)
    gtk_widget_set_margin_top(hint, 5)
    gtk_widget_set_margin_bottom(hint, 5)
    gtk_box_pack_start(barBox, hint, 0, 0, 0)
  for node in bar.children: gtk_box_pack_start(barBox, barItem(node), 0, 0, 0)
  gtk_widget_show_all(barBox)

proc buildBar() =
  let events = gtk_event_box_new()   # the bar's empty end: dropping there moves the item to the end
  barBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  gtk_widget_set_margin_start(barBox, 4)
  gtk_container_add(events, barBox)
  dropTarget(events, proc (x, y, w, h: int) =
    let i = bar.children.find(dragging)
    if i >= 0: reorder(bar, i, bar.children.len)
    else: update(dragging, parent = bar))
  barScroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(barScroller, GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
  gtk_scrolled_window_set_propagate_natural_height(barScroller, 1)
  gtk_container_add(barScroller, events)
  gtk_widget_show(events)
  addClass(barScroller, "webby-bookmark-bar")
  gtk_widget_set_no_show_all(barScroller, 1)
  gtk_box_pack_start(barSlot, barScroller, 0, 0, 0)
  fillBar()

# ---------------------------------------------------------------------------------------------------------------
# The bookmark manager sidebar (bookmarks_page.dart)

proc fillManager()

proc openFolder(f: Bookmark) =
  managerFolder = f
  if managerSearch != nil: gtk_entry_set_text(managerSearch, "")
  # After the click that asked for it: the rows are rebuilt.
  discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} = (fillManager(); 0), nil)

proc deleteNode(node: Bookmark) =
  if not confirmDelete(node): return
  var inside = false
  for n in node.descendants:
    if n == managerFolder: inside = true
  if inside:
    managerFolder = parentOf(node)
    if managerFolder == nil: managerFolder = bar
  remove(node)

proc smallButton(icon, tooltip: string, action: proc ()): Widget =
  result = gtk_button_new_from_icon_name(icon.cstring, GTK_ICON_SIZE_MENU)
  gtk_button_set_relief(result, GTK_RELIEF_NONE)
  gtk_widget_set_tooltip_text(result, tooltip.cstring)
  gtk_widget_set_valign(result, GTK_ALIGN_CENTER)
  onAction(result, action)

proc managerRow(node: Bookmark, reorderable: bool): Widget =
  let events = gtk_event_box_new()
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)
  gtk_widget_set_margin_start(box, 10)
  gtk_widget_set_margin_end(box, 4)
  gtk_widget_set_margin_top(box, 4)
  gtk_widget_set_margin_bottom(box, 4)
  gtk_box_pack_start(box, gtk_image_new_from_icon_name(
    cstring(if node.isFolder: "folder-symbolic" else: "web-browser-symbolic"), GTK_ICON_SIZE_BUTTON), 0, 0, 0)
  let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
  let title = gtk_label_new(node.label.cstring)
  gtk_label_set_xalign(title, 0)
  gtk_label_set_ellipsize(title, PANGO_ELLIPSIZE_END)
  gtk_box_pack_start(text, title, 0, 0, 0)
  let n = node.children.len
  let sub = gtk_label_new(cstring(if node.isFolder: $n & " item" & (if n == 1: "" else: "s") else: node.url))
  gtk_label_set_xalign(sub, 0)
  gtk_label_set_ellipsize(sub, PANGO_ELLIPSIZE_END)
  addClass(sub, "dim-label")
  gtk_box_pack_start(text, sub, 0, 0, 0)
  gtk_box_pack_start(box, text, 1, 1, 0)
  gtk_box_pack_start(box, smallButton("document-edit-symbolic", "Edit", proc () = editBookmark(node)), 0, 0, 0)
  gtk_box_pack_start(box, smallButton("user-trash-symbolic", "Delete", proc () = deleteNode(node)), 0, 0, 0)
  gtk_container_add(events, box)
  onPress(events, proc (ev: GEvent): bool =
    if button(ev) == 2 and not node.isFolder:
      openInBackground(node.url)
      return true
    if button(ev) == 3:
      popup(itemMenu(node), events, ev)
      return true
    false)
  if reorderable:
    # Drag a row onto another: the top or bottom half places it before or after, the middle of a folder moves it in.
    dragSource(events, node)
    dropTarget(events, proc (x, y, w, h: int) =
      let dragged = dragging
      if dragged == nil or dragged == node: return
      let f = y / max(h, 1)
      if node.isFolder and f > 0.25 and f < 0.75:
        update(dragged, parent = node)
        return
      let folder = managerFolder
      let to = folder.children.find(node) + (if f >= 0.5: 1 else: 0)
      let source = folder.children.find(dragged)
      if source >= 0: reorder(folder, source, to)
      else:
        update(dragged, parent = folder)
        let moved = folder.children.find(dragged)
        if moved >= 0: reorder(folder, moved, to))
  events

proc unrefCb(data: pointer) {.cdecl.} = GC_unref(cast[Cb](data))

proc listRow(list, child: Widget, onActivate: proc ()) =
  ## A row of `list` (see `newList`) that runs `onActivate` when clicked or activated with the keyboard.
  let row = gtk_list_box_row_new()
  gtk_container_add(row, child)
  if onActivate == nil: gtk_list_box_row_set_activatable(row, 0)
  else: g_object_set_data_full(row, "webby-action", hold(Cb(action: onActivate)), unrefCb)
  gtk_container_add(list, row)

proc onListRow(l: Widget, row: Widget, data: pointer) {.cdecl.} =
  let cb = g_object_get_data(row, "webby-action")
  if cb != nil: cast[Cb](cb).action()

proc newList(mode: cint): Widget =
  result = gtk_list_box_new()
  gtk_list_box_set_selection_mode(result, mode)
  connect(result, "row-activated", onListRow)

proc emptyLabel(text: string): Widget =
  result = gtk_label_new(text.cstring)
  addClass(result, "dim-label")
  gtk_label_set_line_wrap(result, 1)
  gtk_widget_set_margin_top(result, 24)
  gtk_widget_set_margin_start(result, 12)
  gtk_widget_set_margin_end(result, 12)

proc activation(node: Bookmark): proc () =
  ## Clicking a row: a folder opens in the manager, a link in the current tab.
  result = proc () = (if node.isFolder: openFolder(node) else: goUrl(node.url))

proc folderRow(f: Bookmark, depth: int): Widget =
  ## A folder in the manager's tree; dropping a bookmark on it moves the bookmark in.
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
  gtk_widget_set_margin_start(box, cint(12 + 16 * depth))
  gtk_widget_set_margin_top(box, 3)
  gtk_widget_set_margin_bottom(box, 3)
  let icon = if f == bar: "user-bookmarks-symbolic" elif f == managerFolder: "folder-open-symbolic"
             else: "folder-symbolic"
  gtk_box_pack_start(box, gtk_image_new_from_icon_name(icon.cstring, GTK_ICON_SIZE_MENU), 0, 0, 0)
  let l = gtk_label_new(f.label.cstring)
  gtk_label_set_xalign(l, 0)
  gtk_label_set_ellipsize(l, PANGO_ELLIPSIZE_END)
  gtk_box_pack_start(box, l, 1, 1, 0)
  result = gtk_event_box_new()
  gtk_container_add(result, box)
  dropTarget(result, proc (x, y, w, h: int) = update(dragging, parent = f))

proc fillManager() =
  if managerList == nil: return
  # The open folder may have been deleted elsewhere.
  if managerFolder == nil or find(managerFolder.id) == nil: managerFolder = bar
  let query = ($gtk_entry_get_text(managerSearch)).strip.toLowerAscii
  clearChildren(managerTree)
  for (f, depth) in folders():
    listRow(managerTree, folderRow(f, depth), activation(f))
    if f == managerFolder and query.len == 0:
      gtk_list_box_select_row(managerTree, gtk_list_box_get_row_at_index(managerTree, cint(children(managerTree).high)))
  gtk_widget_show_all(managerTree)

  clearChildren(managerList)
  if query.len > 0:
    var found = 0
    for n in all():
      if query in n.title.toLowerAscii or (not n.isFolder and query in n.url.toLowerAscii):
        listRow(managerList, managerRow(n, false), activation(n))
        inc found
    if found == 0: listRow(managerList, emptyLabel("No bookmarks match."), nil)
  elif managerFolder.children.len == 0:
    listRow(managerList, emptyLabel(if managerFolder == bar:
      "No bookmarks yet. Bookmark a page with the star in the address bar or Ctrl+D." else: "This folder is empty."),
      nil)
  else:
    for n in managerFolder.children: listRow(managerList, managerRow(n, true), activation(n))
  gtk_widget_show_all(managerList)

proc showManager*() =
  closeSidePanel()
  ensureLoaded()
  if managerFolder == nil: managerFolder = bar
  let body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
  if loadError.len > 0:
    let e = gtk_label_new(loadError.cstring)
    gtk_label_set_line_wrap(e, 1)
    addClass(e, "error")
    gtk_box_pack_start(body, e, 0, 0, 4)
  let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  gtk_widget_set_margin_start(top, 8)
  gtk_widget_set_margin_end(top, 4)
  managerSearch = gtk_search_entry_new()
  gtk_entry_set_placeholder_text(managerSearch, "Search bookmarks")
  onAction(managerSearch, fillManager, "search-changed")
  gtk_box_pack_start(top, managerSearch, 1, 1, 0)
  gtk_box_pack_start(top, iconButton("folder-new-symbolic", "New folder", proc () = newFolderIn(managerFolder)),
    0, 0, 0)
  let more = gtk_menu_button_new()
  gtk_button_set_relief(more, GTK_RELIEF_NONE)
  gtk_button_set_image(more, gtk_image_new_from_icon_name("view-more-symbolic", GTK_ICON_SIZE_SMALL_TOOLBAR))
  gtk_widget_set_tooltip_text(more, "More")
  let menu = gtk_menu_new()
  gtk_widget_set_halign(menu, GTK_ALIGN_END)
  menuItem(menu, "Import bookmarks.html…", importFile)
  menuItem(menu, "Export bookmarks.html…", exportFile)
  menuSeparator(menu)
  let check = gtk_check_menu_item_new_with_label("Show bookmarks bar")
  gtk_check_menu_item_set_active(check, showBar().gboolean)
  onAction(check, proc () = setShowBar(gtk_check_menu_item_get_active(check) != 0), "toggled")
  gtk_menu_shell_append(menu, check)
  gtk_widget_show_all(menu)
  gtk_menu_button_set_popup(more, menu)
  gtk_box_pack_start(top, more, 0, 0, 0)
  gtk_box_pack_start(body, top, 0, 0, 0)

  let treeScroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(treeScroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  gtk_scrolled_window_set_propagate_natural_height(treeScroller, 1)
  gtk_scrolled_window_set_max_content_height(treeScroller, 200)
  managerTree = newList(GTK_SELECTION_SINGLE)
  gtk_container_add(treeScroller, managerTree)
  gtk_box_pack_start(body, treeScroller, 0, 0, 0)
  gtk_box_pack_start(body, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 0)
  let listScroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(listScroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  managerList = newList(GTK_SELECTION_NONE)
  gtk_container_add(listScroller, managerList)
  gtk_box_pack_start(body, listScroller, 1, 1, 0)
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
  # A text star rather than an icon: it shows in every icon theme and takes the accent colour.
  gtk_label_set_text(gtk_bin_get_child(starButton), cstring(if marked: "★" else: "☆"))
  gtk_widget_set_tooltip_text(starButton,
    cstring(if marked: "Edit bookmark (Ctrl+D)" else: "Bookmark this page (Ctrl+D)"))
  if marked: addClass(starButton, "webby-starred") else: removeClass(starButton, "webby-starred")
  gtk_widget_set_sensitive(starButton, (t != nil and t.url.len > 0).gboolean)

proc refresh() =
  ## Bookmarks changed: redraw what shows them, once per main-loop turn.
  if refreshQueued: return
  refreshQueued = true
  discard g_idle_add(proc (d: pointer): gboolean {.cdecl.} =
    refreshQueued = false
    fillBar()
    updateStar()
    if managerOpen: fillManager()
    if barCheck != nil:
      g_signal_handler_block(barCheck, barCheckHandler)
      gtk_check_menu_item_set_active(barCheck, showBar().gboolean)
      g_signal_handler_unblock(barCheck, barCheckHandler)
    0, nil)

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

proc accel(item: Widget, key: uint32, mods: uint32) =
  gtk_accel_label_set_accel(gtk_bin_get_child(item), key.cuint, mods.cuint)

proc buildChrome() =
  if appUrl.len > 0: return
  ensureLoaded()
  loadCss(".webby-star { font-size: 18px; padding: 0 6px; min-height: 0; }\n" &
    ".webby-starred label { color: @theme_selected_bg_color; }\n" &
    ".webby-bookmark { padding: 2px 6px; min-height: 0; }\n" &
    ".webby-bookmark-bar { border-bottom: 1px solid alpha(currentColor, 0.12); }")
  # Incognito windows don't bookmark pages.
  if not incognito:
    starButton = iconButton("", "Bookmark this page (Ctrl+D)", bookmarkPage)
    gtk_button_set_image(starButton, nil)
    gtk_button_set_label(starButton, "☆")
    addClass(starButton, "webby-star")
    gtk_box_pack_start(starSlot, starButton, 0, 0, 0)
  discard addToolbarButton("user-bookmarks-symbolic", "Bookmarks (Ctrl+Shift+O)", toggleManager)
  buildBar()
  if not incognito: addMenuItem("Bookmark this page", bookmarkPage).accel(0x64, GDK_CONTROL_MASK)
  barCheck = gtk_check_menu_item_new_with_label("Show bookmarks bar")
  gtk_check_menu_item_set_active(barCheck, showBar().gboolean)
  barCheckHandler = g_signal_connect_data(barCheck, "toggled", proc (w: Widget, d: pointer) {.cdecl.} =
    setShowBar(gtk_check_menu_item_get_active(w) != 0), nil, nil, 0)
  barCheck.accel(0x62, GDK_CONTROL_MASK or GDK_SHIFT_MASK)
  gtk_menu_shell_append(moreMenu, barCheck)
  gtk_widget_show(barCheck)
  addMenuSeparator()
  addMenuItem("Bookmark manager", showManager).accel(0x6f, GDK_CONTROL_MASK or GDK_SHIFT_MASK)
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
