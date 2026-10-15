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

when not defined(android):
  {.push cdecl, importc.}
  proc g_app_info_launch_default_for_uri(uri: cstring, ctx: pointer, err: pointer): gboolean
  proc g_bus_get_sync(kind: cint, cancellable: pointer, err: pointer): pointer
  proc g_dbus_connection_call_sync(c: pointer, name, path, iface, meth: cstring, params: pointer, replyType: pointer,
    flags: cint, timeoutMs: cint, cancellable: pointer, err: pointer): pointer
  proc g_variant_new_parsed(format: cstring): pointer {.varargs.}
  proc g_variant_unref(v: pointer)
  proc g_error_free(e: pointer)
  {.pop.}

type
  Download = object
    id: uint64
    url, path, status, error: string
    received, total, rate, remaining: int64
    canResume, private: bool
  Row = object
    name, detail, bar, pauseButton, actionButton: kit.Widget
    status: string

var
  serial: uint64
  downloads: seq[Download]
  known: Table[uint64, string]   ## id -> status last seen, to notice new and finished downloads
  button: kit.Widget             ## toolbar button; hidden until the first download
  panelOpen = false
  panelList: kit.Widget
  rows: Table[uint64, Row]
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

when defined(android):
  # The Android host opens files with an app that takes them (through its FileProvider); there is no file manager
  # to select one in, so "Show in folder" opens the file too.
  proc openPath(path: string) =
    if hostCall("openFile", path) != "ok": toast("No app opens " & path.extractFilename)

  proc showInFolder(path: string) = openPath(path)

else:
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

proc dim(text: string): kit.Widget =
  result = kit.addClass(kit.addClass(kit.label(text), "dim"), "small")
  kit.`maxChars=`(result, 200)

proc smallButton(icon, tooltip: string, action: proc ()): kit.Widget = kit.iconButton(icon, tooltip, action, 16)

proc updateRow(r: var Row, d: Download) =
  kit.`text=`(r.detail, d.detail)
  kit.`visible=`(r.bar, d.active)
  if d.active: kit.`value=`(r.bar, d.fraction)
  # Ladybird pauses only downloads it can resume (the server takes Range requests).
  kit.`visible=`(r.pauseButton, d.status == "paused" or d.status == "in_progress" and d.canResume)
  if r.status != d.status:
    r.status = d.status
    kit.`iconName=`(r.pauseButton, if d.status == "paused": "play_arrow" else: "pause")
    kit.`tooltip=`(r.pauseButton, if d.status == "paused": "Resume" else: "Pause")
    kit.`iconName=`(r.actionButton, if d.active: "close" else: "folder_open")
    kit.`tooltip=`(r.actionButton, if d.active: "Cancel" else: "Show in folder")
    kit.`enabled=`(r.actionButton, d.active or d.status == "completed" and fileExists(d.path))

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

proc rowMenu(id: uint64) =
  ## Right-click: open, show in folder, copy the link, download it again.
  let at = find(id)
  if at < 0: return
  let d = downloads[at]
  var items: seq[kit.MenuItem]
  if d.status == "completed" and fileExists(d.path):
    items.add kit.menuItem("Open", proc () = openPath(d.path))
    items.add kit.menuItem("Show in folder", proc () = showInFolder(d.path))
    items.add kit.menuSeparator()
  items.add kit.menuItem("Copy download link", proc () =
    copyText(d.url))
  if not d.active and webby_downloads_start != nil:
    items.add kit.menuItem("Download again", proc () =
      discard webby_downloads_start(d.url.cstring, d.private.cint)
      wake())
  kit.popupMenu(items)

proc openIfDone(id: uint64) =
  let at = find(id)
  if at >= 0 and downloads[at].status == "completed" and fileExists(downloads[at].path): openPath(downloads[at].path)

proc entryRow(d: Download): (kit.Widget, Row) =
  var r: Row
  r.name = kit.label(d.name)
  kit.`maxChars=`(r.name, 200)
  r.bar = kit.progress()
  r.detail = dim("")
  let text = kit.column(r.name, r.bar, r.detail)
  text.spacing = 2
  let id = d.id
  r.pauseButton = smallButton("pause", "Pause", proc () = pauseOrResume(id))
  r.actionButton = smallButton("close", "Cancel", proc () = cancelOrShow(id))
  let row = kit.item(kit.icon("insert_drive_file_outlined"), kit.expand(text), r.pauseButton, r.actionButton,
    onClick = proc () = openIfDone(id))
  row.spacing = 8
  kit.addClass(row, "webby-download-row")
  kit.`tooltip=`(row, d.url)
  row.onContext = proc () = rowMenu(id)
  updateRow(r, d)
  (row, r)

proc fillPanel() =
  if panelList == nil: return
  kit.clear(panelList)
  rows.clear
  if downloads.len == 0:
    let l = kit.addClass(dim(if hasApi(): "Files you download show up here."
                             else: "This version of the engine doesn't list downloads."), "webby-downloads-empty")
    kit.`maxChars=`(l, 0)
    kit.add(panelList, l)
  for i in countdown(downloads.high, 0):   # newest first
    let d = downloads[i]
    let (w, r) = entryRow(d)
    kit.add(panelList, w)
    rows[d.id] = r

proc refreshPanel() =
  ## Updates rows in place while the same downloads are listed (progress ticks), else rebuilds the list.
  if panelList == nil: return
  var same = rows.len == downloads.len
  if same:
    for d in downloads:
      if d.id notin rows: (same = false; break)
  if not same: fillPanel(); return
  for d in downloads: updateRow(rows[d.id], d)

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
  let where = dim(downloadsDir().replace(getHomeDir().strip(leading = false, chars = {'/'}), "~"))
  let top = kit.addClass(kit.row(kit.expand(where),
    kit.iconButton("folder_open", "Open the Downloads folder", proc () = openPath(downloadsDir())),
    kit.iconButton("delete_sweep_outlined", "Clear finished downloads from the list", clearList)), "webby-panel-top")
  top.spacing = 4
  panelList = kit.column()
  panelList.spacing = 0
  let body = kit.column(top, kit.expand(kit.scroll(panelList)))
  body.spacing = 4
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
    elif d.status == "completed": toast(d.name & " downloaded")
    elif d.status == "failed": toast("Couldn't download " & d.name)

proc poll() =
  let s = webby_downloads_serial()
  if s == serial or refreshQueued: return
  serial = s
  # Progress changes the serial many times a second; read the list at most every 200 ms.
  refreshQueued = true
  discard after(200, proc () =
    refreshQueued = false
    serial = webby_downloads_serial()
    downloads = parse($webby_downloads_json())
    if primed: announce()
    else:
      for d in downloads: known[d.id] = d.status
      primed = true
    refreshButton()
    refreshPanel())

proc install*() =
  startupHooks.add setUpDirectory
  addShortcut(modCtrl, 0x6a, toggleDownloads)   # Ctrl+J
  windowHooks.add proc () =
    if appUrl.len > 0: return
    addMenuItem("Downloads", toggleDownloads, "Ctrl+J")
    loadCss("button.webby-download-row { padding: 6px 4px 6px 10px; }\n" &
      ".webby-download-row button { padding: 2px; min-height: 0; }\n" &
      ".webby-downloads-empty { margin-top: 24px; }\n.webby-panel-top { margin: 0 4px 0 8px; }")
    if not hasApi(): return
    button = addToolbarButton("download", "Downloads (Ctrl+J)", toggleDownloads, "download", "Downloads")
    kit.`visible=`(button, false)
    pumpHooks.add poll
