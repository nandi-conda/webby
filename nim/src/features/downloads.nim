## Downloads. Ladybird saves what pages download (Content-Disposition: attachment, <a download>, types it can't
## show, blob: URLs) into the Downloads folder by itself; this shows them: a toolbar button that appears with the
## first download (its icon says whether one is running, its tooltip how far along), a short note when one starts
## and finishes, and the Downloads sidebar (Ctrl+J) with progress, pause/resume/cancel, open and show in folder.
## The list comes from webby_downloads_json (runtimes since 2026.10.15); older runtimes still save the files, and
## Ctrl+J then opens the Downloads folder.

import std/[json, os, strutils, tables, uri]
import ../browser
from nimkit/core as kit import nil
import tabs/common

{.push cdecl, importc.}
proc g_app_info_launch_default_for_uri(uri: cstring, ctx: pointer, err: pointer): gboolean
proc g_bus_get_sync(kind: cint, cancellable: pointer, err: pointer): pointer
proc g_dbus_connection_call_sync(c: pointer, name, path, iface, meth: cstring, params: pointer, replyType: pointer,
  flags: cint, timeoutMs: cint, cancellable: pointer, err: pointer): pointer
proc g_variant_new_parsed(format: cstring): pointer {.varargs.}
proc g_variant_unref(v: pointer)
proc g_error_free(e: pointer)
proc gtk_accel_label_set_accel(l: Widget, key: cuint, mods: cuint)
proc gtk_list_box_get_row_at_y(l: Widget, y: cint): Widget
{.pop.}

type
  Download = object
    id: uint64
    url, path, status, error: string
    received, total, rate, remaining: int64
    canResume, private: bool
  Row = object
    name, detail, bar, pauseButton, actionButton: Widget
    status: string

var
  serial: uint64
  downloads: seq[Download]
  known: Table[uint64, string]   ## id -> status last seen, to notice new and finished downloads
  button: kit.Widget             ## toolbar button; hidden until the first download
  panelOpen = false
  panelList: Widget
  rows: Table[uint64, Row]
  rowIds: seq[uint64]            ## per list row: its download (0 for the empty note)
  refreshQueued = false
  primed = false                 ## the first list was read (downloads Ladybird restored aren't announced)

proc hasApi(): bool = webby_downloads_serial != nil and webby_downloads_json != nil

# ---------------------------------------------------------------------------------------------------------------
# Where downloads go

proc userDirsDownload(): string =
  ## XDG_DOWNLOAD_DIR from ~/.config/user-dirs.dirs (a localized "Téléchargements", a renamed folder), which
  ## Ladybird doesn't read: it only looks at the environment variable.
  try:
    for line in lines(getConfigDir() / "user-dirs.dirs"):
      let l = line.strip
      if not l.startsWith("XDG_DOWNLOAD_DIR="): continue
      let v = l["XDG_DOWNLOAD_DIR=".len .. ^1].strip(chars = {'"'})
      return v.replace("$HOME", getHomeDir().strip(leading = false, chars = {'/'}))
  except CatchableError: discard

proc downloadsDir*(): string =
  result = getEnv("XDG_DOWNLOAD_DIR")
  if result.len == 0: result = userDirsDownload()
  if result.len == 0: result = getHomeDir() / "Downloads"

proc setUpDirectory() =
  ## Before Ladybird starts: point it at the user's Downloads folder and make sure that exists (runtimes before
  ## 2026.10.15 fail a download into a missing folder with only a log line).
  let dir = downloadsDir()
  putEnv("XDG_DOWNLOAD_DIR", dir)
  try: createDir(dir) except CatchableError: discard

# ---------------------------------------------------------------------------------------------------------------
# Opening files

proc fileUri(path: string): string = "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")

proc openPath(path: string) =
  if g_app_info_launch_default_for_uri(fileUri(path).cstring, nil, nil) == 0:
    toast("No app opens " & path.extractFilename)

proc showInFolder(path: string) =
  ## Selects the file in the file manager (org.freedesktop.FileManager1), else opens its folder.
  let bus = g_bus_get_sync(2, nil, nil)   # G_BUS_TYPE_SESSION
  if bus != nil:
    var err: pointer
    let params = g_variant_new_parsed("([%s], '')", fileUri(path).cstring)
    let reply = g_dbus_connection_call_sync(bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1",
      "org.freedesktop.FileManager1", "ShowItems", params, nil, 0, 2000, nil, addr err)
    g_object_unref(bus)
    if reply != nil:
      g_variant_unref(reply)
      return
    if err != nil: g_error_free(err)
  openPath(path.parentDir)

# ---------------------------------------------------------------------------------------------------------------
# The list

proc parse(text: string): seq[Download] =
  try:
    for d in parseJson(text):
      result.add Download(id: uint64(d{"id"}.getBiggestInt), url: d{"url"}.getStr, path: d{"path"}.getStr,
        status: d{"status"}.getStr, error: d{"error"}.getStr, received: d{"received"}.getBiggestInt,
        total: d{"total"}.getBiggestInt(-1), rate: d{"rate"}.getBiggestInt(-1),
        remaining: d{"remaining"}.getBiggestInt(-1), canResume: d{"canResume"}.getBool,
        private: d{"private"}.getBool)
  except CatchableError: discard

proc active(d: Download): bool = d.status in ["in_progress", "paused"]
proc name(d: Download): string = d.path.extractFilename

proc size(n: int64): string =
  if n < 1000: $n & " B"
  elif n < 1000_000: formatFloat(n.float / 1e3, ffDecimal, 0) & " kB"
  elif n < 1000_000_000: formatFloat(n.float / 1e6, ffDecimal, 1) & " MB"
  else: formatFloat(n.float / 1e9, ffDecimal, 2) & " GB"

proc duration(s: int64): string =
  if s < 60: $s & " s left"
  elif s < 3600: $(s div 60) & " min left"
  else: $(s div 3600) & " h " & $(s mod 3600 div 60) & " min left"

proc host(url: string): string =
  try: parseUri(url).hostname except CatchableError: ""

proc detail(d: Download): string =
  case d.status
  of "in_progress", "paused":
    var parts = @[if d.total > 0: size(d.received) & " of " & size(d.total) else: size(d.received)]
    if d.status == "paused": parts.add "Paused"
    else:
      if d.rate > 0: parts.add size(d.rate) & "/s"
      if d.remaining >= 0: parts.add duration(d.remaining)
    parts.join(" · ")
  of "completed":
    (if fileExists(d.path): size(d.received) else: "Deleted") & (let h = host(d.url); if h.len > 0: " · " & h else: "")
  of "canceled": "Canceled"
  else: "Failed" & (if d.error.len > 0: ": " & d.error else: "")

proc fraction(d: Download): float =
  if d.total > 0: min(1.0, d.received.float / d.total.float) else: 0.0

proc find(id: uint64): int =
  for i, d in downloads:
    if d.id == id: return i
  -1

proc runningCount(): int =
  for d in downloads:
    if d.status == "in_progress": inc result

# ---------------------------------------------------------------------------------------------------------------
# The sidebar

proc dim(text: string): Widget =
  result = gtk_label_new(text.cstring)
  addClass(result, "dim-label")
  addClass(result, "webby-small")
  gtk_label_set_xalign(result, 0)
  gtk_label_set_ellipsize(result, PANGO_ELLIPSIZE_END)

proc smallButton(icon, tooltip: string, action: proc ()): Widget =
  result = iconButton(icon, tooltip, action, 16)
  gtk_widget_set_valign(result, GTK_ALIGN_CENTER)

proc updateRow(r: var Row, d: Download) =
  gtk_label_set_text(r.detail, d.detail.cstring)
  gtk_widget_set_visible(r.bar, d.active.gboolean)
  if d.active:
    if d.total > 0: gtk_progress_bar_set_fraction(r.bar, d.fraction)
    else: gtk_progress_bar_pulse(r.bar)
  if r.status != d.status:
    r.status = d.status
    gtk_widget_set_visible(r.pauseButton, d.active.gboolean)
    setButtonIcon(r.pauseButton, if d.status == "paused": "play_arrow" else: "pause")
    gtk_widget_set_tooltip_text(r.pauseButton, if d.status == "paused": "Resume" else: "Pause")
    setButtonIcon(r.actionButton, if d.active: "close" else: "folder_open")
    gtk_widget_set_tooltip_text(r.actionButton, if d.active: "Cancel" else: "Show in folder")
    gtk_widget_set_sensitive(r.actionButton, gboolean(d.active or d.status == "completed" and fileExists(d.path)))

proc pauseOrResume(id: uint64) =
  let i = find(id)
  if i < 0: return
  if downloads[i].status == "paused": webby_downloads_resume(id) else: webby_downloads_pause(id)
  wake()

proc cancelOrShow(id: uint64) =
  let i = find(id)
  if i < 0: return
  if downloads[i].active: webby_downloads_cancel(id); wake()
  else: showInFolder(downloads[i].path)

proc entryRow(d: Download): (Widget, Row) =
  var r: Row
  let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
  for (f, m) in [(gtk_widget_set_margin_start, 10), (gtk_widget_set_margin_end, 4), (gtk_widget_set_margin_top, 6),
                 (gtk_widget_set_margin_bottom, 6)]: f(box, m.cint)
  let fileIcon = icon("insert_drive_file_outlined")
  gtk_widget_set_valign(fileIcon, GTK_ALIGN_CENTER)
  gtk_box_pack_start(box, fileIcon, 0, 0, 0)
  let text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)
  r.name = gtk_label_new(d.name.cstring)
  gtk_label_set_xalign(r.name, 0)
  gtk_label_set_ellipsize(r.name, 2.cint)   # PANGO_ELLIPSIZE_MIDDLE
  gtk_box_pack_start(text, r.name, 0, 0, 0)
  r.bar = gtk_progress_bar_new()
  gtk_widget_set_no_show_all(r.bar, 1)
  gtk_box_pack_start(text, r.bar, 0, 0, 0)
  r.detail = dim("")
  gtk_box_pack_start(text, r.detail, 0, 0, 0)
  gtk_box_pack_start(box, text, 1, 1, 0)
  let id = d.id
  r.pauseButton = smallButton("pause", "Pause", proc () = pauseOrResume(id))
  gtk_widget_set_no_show_all(r.pauseButton, 1)
  gtk_box_pack_start(box, r.pauseButton, 0, 0, 0)
  r.actionButton = smallButton("close", "Cancel", proc () = cancelOrShow(id))
  gtk_box_pack_start(box, r.actionButton, 0, 0, 0)
  gtk_widget_set_tooltip_text(text, d.url.cstring)
  updateRow(r, d)
  (box, r)

proc fillPanel() =
  if panelList == nil: return
  clearChildren(panelList)
  rows.clear
  rowIds.setLen 0
  if downloads.len == 0:
    let l = dim(if hasApi(): "Files you download show up here." else: "This version of the engine doesn't list downloads.")
    gtk_label_set_line_wrap(l, 1)
    gtk_label_set_xalign(l, 0.5)
    gtk_widget_set_margin_top(l, 24)
    gtk_container_add(panelList, l)
    rowIds.add 0
  for i in countdown(downloads.high, 0):   # newest first
    let d = downloads[i]
    let (w, r) = entryRow(d)
    gtk_container_add(panelList, w)
    rows[d.id] = r
    rowIds.add d.id
  gtk_widget_show_all(panelList)

proc refreshPanel() =
  ## Updates rows in place while the same downloads are listed (progress ticks), else rebuilds the list.
  if panelList == nil: return
  var same = rows.len == downloads.len
  if same:
    for d in downloads:
      if d.id notin rows: (same = false; break)
  if not same: fillPanel(); return
  for d in downloads: updateRow(rows[d.id], d)

proc idAt(y: cdouble): uint64 =
  let row = gtk_list_box_get_row_at_y(panelList, y.cint)
  if row == nil: return 0
  let i = gtk_list_box_row_get_index(row)
  if i in 0 ..< rowIds.len: rowIds[i] else: 0

proc onRowActivated(l: Widget, row: Widget, data: pointer) {.cdecl.} =
  let i = gtk_list_box_row_get_index(row)
  if i notin 0 ..< rowIds.len: return
  let at = find(rowIds[i])
  if at >= 0 and downloads[at].status == "completed" and fileExists(downloads[at].path): openPath(downloads[at].path)

proc onPanelButton(l: Widget, ev: GEvent, data: pointer): gboolean {.cdecl.} =
  ## Right-click: open, show in folder, copy the link, download it again.
  var b: cuint
  discard gdk_event_get_button(ev, addr b)
  if b != 3 or gdk_event_get_event_type(ev) != GDK_BUTTON_PRESS: return 0
  var x, y: cdouble
  discard gdk_event_get_coords(ev, addr x, addr y)
  let at = find(idAt(y))
  if at < 0: return 0
  let d = downloads[at]
  var items: seq[kit.MenuItem]
  if d.status == "completed" and fileExists(d.path):
    items.add kit.menuItem("Open", proc () = openPath(d.path))
    items.add kit.menuItem("Show in folder", proc () = showInFolder(d.path))
    items.add kit.menuSeparator()
  items.add kit.menuItem("Copy download link", proc () =
    gtk_clipboard_set_text(systemClipboard(), d.url.cstring, -1))
  if not d.active and webby_downloads_start != nil:
    items.add kit.menuItem("Download again", proc () =
      discard webby_downloads_start(d.url.cstring, d.private.cint)
      wake())
  kit.popupMenu(items)
  1

proc clearList() =
  if webby_downloads_clear != nil: webby_downloads_clear()
  wake()

proc toggleDownloads*() =
  if not hasApi():
    openPath(downloadsDir())
    return
  if panelOpen:
    closeSidePanel()
    return
  let body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
  let top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
  gtk_widget_set_margin_start(top, 8)
  gtk_widget_set_margin_end(top, 4)
  let where = dim(downloadsDir().replace(getHomeDir().strip(leading = false, chars = {'/'}), "~"))
  gtk_box_pack_start(top, where, 1, 1, 0)
  gtk_box_pack_start(top, iconButton("folder_open", "Open the Downloads folder", proc () = openPath(downloadsDir())), 0, 0, 0)
  gtk_box_pack_start(top, iconButton("delete_sweep_outlined", "Clear finished downloads from the list", clearList), 0, 0, 0)
  gtk_box_pack_start(body, top, 0, 0, 0)
  let scroller = gtk_scrolled_window_new(nil, nil)
  gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
  panelList = gtk_list_box_new()
  gtk_list_box_set_selection_mode(panelList, GTK_SELECTION_NONE)
  connect(panelList, "row-activated", onRowActivated)
  connect(panelList, "button-press-event", onPanelButton)
  gtk_container_add(scroller, panelList)
  gtk_box_pack_start(body, scroller, 1, 1, 0)
  panelOpen = true
  showSidePanel("Downloads", body, 360, proc () =
    panelOpen = false
    panelList = nil
    rows.clear)
  fillPanel()

# ---------------------------------------------------------------------------------------------------------------
# Following the engine's list

proc refreshButton() =
  if button == nil: return
  kit.`visible=`(button, downloads.len > 0)
  let running = runningCount()
  if not panelOpen: kit.`iconName=`(button, if running > 0: "downloading" else: "download")
  var tip = "Downloads (Ctrl+J)"
  if running > 0:
    var got, total: int64
    var sized = true
    for d in downloads:
      if d.status != "in_progress": continue
      got += d.received
      if d.total > 0: total += d.total else: sized = false
    tip = (if running == 1: "1 download" else: $running & " downloads") &
      (if sized and total > 0: ", " & $int(got.float * 100 / total.float) & "%" else: ", " & size(got))
  kit.`tooltip=`(button, tip)

proc announce() =
  ## A note when a download starts and when it finishes or fails (the sidebar shows it all when it's open).
  for d in downloads:
    let before = known.getOrDefault(d.id, "")
    if before == d.status: continue
    known[d.id] = d.status
    if panelOpen: continue
    if before.len == 0 and d.active: toast("Downloading " & d.name & " (Ctrl+J shows downloads)")
    elif before.len > 0 and d.status == "completed": toast(d.name & " downloaded")
    elif before.len > 0 and d.status == "failed": toast("Couldn't download " & d.name)

proc poll() =
  let s = webby_downloads_serial()
  if s == serial or refreshQueued: return
  serial = s
  # Progress changes the serial many times a second; read the list at most every 200 ms.
  refreshQueued = true
  discard g_timeout_add(200, proc (d: pointer): gboolean {.cdecl.} =
    refreshQueued = false
    serial = webby_downloads_serial()
    downloads = parse($webby_downloads_json())
    if primed: announce()
    else:
      for d in downloads: known[d.id] = d.status
      primed = true
    refreshButton()
    refreshPanel()
    0, nil)

proc install*() =
  startupHooks.add setUpDirectory
  addShortcut(modCtrl, 0x6a, toggleDownloads)   # Ctrl+J
  windowHooks.add proc () =
    if appUrl.len > 0: return
    addMenuItem("Downloads", toggleDownloads, "Ctrl+J")
    if not hasApi(): return
    button = addToolbarButton("download", "Downloads (Ctrl+J)", toggleDownloads, "download", "Downloads")
    kit.`visible=`(button, false)
    pumpHooks.add poll
