## Downloads. Ladybird saves what pages download (Content-Disposition: attachment, <a download>, types it can't
## show, blob: URLs) into the Downloads folder by itself; this shows them: a toolbar button that appears with the
## first download (its icon says whether one is running, its tooltip how far along), a short note when one starts
## and finishes, and the Downloads sidebar (Ctrl+J) with progress, pause/resume/cancel, open and show in folder.
## The list comes from webby_downloads_json (runtimes since 2026.10.15); on Android, whose engine build doesn't have
## it, from "download" host events of the app's folder watcher (android-kit Downloads.java: bytes so far, no total,
## no cancel). Older desktop runtimes still save the files, and Ctrl+J then opens the Downloads folder.
## On the desktop the sidebar's top row also picks the folder downloads go to and whether to ask where to save each
## file: <profile>/downloads.json ({"folder": path or "", "ask": bool}). Ladybird reads $XDG_DOWNLOAD_DIR for every
## download, so changing it applies at once; bug reports and Save image follow it too. Asking can't hold the engine
## back (it picks the path itself), so the file chooser opens as the download starts and the file is moved there
## once it's done; cancelling the chooser cancels the download.

import std/[json, os, sequtils, strutils, tables, times, uri]
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
    fileName: string               ## the name to show when `path` doesn't end in it (an Android content:// URI)
    received, total, rate, remaining: int64
    created: int64                 ## unix ms; 0 when unknown (Android)
    canResume, private: bool
  Row = object
    name, detail, bar, pauseButton, actionButton: kit.Widget
    status: string

var
  serial: uint64
  downloads: seq[Download]
  known: Table[uint64, string]   ## id -> status last seen, to notice new and finished downloads
  button: kit.Widget             ## toolbar button; hidden until the first download
  percent: kit.Widget            ## next to it while something downloads: "45%" (or the bytes so far)
  hostIds: Table[string, uint64] ## Android: file name -> its list entry's id
  hostSerial: uint64             ## Android: the last id given out
  panelOpen = false
  panelList, panelTop: kit.Widget
  rows: Table[uint64, Row]
  refreshQueued = false
  startedMs = int64(epochTime() * 1000)   ## downloads from before this (Ladybird restored them) aren't announced
  systemDir: string              ## the Downloads folder webby uses when none is chosen
  prefs: JsonNode                ## downloads.json, read once
  destinations: Table[uint64, string]  ## asked downloads: id -> where the user wants it ("" while still asking)
  moved: Table[uint64, string]         ## id -> where an asked download's file was moved

type DownloadInfo* = object
  ## A download as other features see it (features/plasma/jobs.nim shows them in the desktop's job tracker).
  id*: uint64
  url*, path*, name*, status*, error*: string   ## status: in_progress, paused, completed, canceled, failed
  received*, total*, rate*: int64               ## total and rate -1 when unknown
  canResume*, fresh*: bool                      ## fresh: started in this session (not one Ladybird restored)

var downloadsChangedHooks*: seq[proc (list: seq[DownloadInfo])]   ## the list changed (at most every 200 ms)

proc hasApi(): bool = webby_downloads_serial != nil and webby_downloads_json != nil
proc listed(): bool = hasApi() or defined(android)   ## whether there is a list to show

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

proc defaultDownloadsDir(): string =
  result = getEnv("XDG_DOWNLOAD_DIR")
  if result.len == 0: result = userDirsDownload()
  if result.len == 0: result = getHomeDir() / "Downloads"

proc pref(): JsonNode =
  if prefs == nil:
    prefs = readJsonFile(profileFile("downloads.json"))
    if prefs == nil or prefs.kind != JObject: prefs = newJObject()
  prefs

proc savePrefs() =
  # Incognito windows follow the normal profile's choices but don't change them.
  if not incognito:
    try: writeJsonFile(profileFile("downloads.json"), pref()) except CatchableError: discard

proc chosenDir(): string =
  when defined(android): "" else: pref(){"folder"}.getStr

proc askEachTime(): bool =
  when defined(android): false else: pref(){"ask"}.getBool

proc downloadsDir*(): string =
  ## Where downloads (and bug reports, saved images) go: the folder picked in the Downloads sidebar, else the
  ## user's Downloads folder.
  result = chosenDir()
  if result.len == 0: result = (if systemDir.len > 0: systemDir else: defaultDownloadsDir())

proc applyDirectory() =
  ## Points Ladybird at downloadsDir() and makes sure that exists (runtimes before 2026.10.15 fail a download into
  ## a missing folder with only a log line). A chosen folder that can't be made (a drive that isn't mounted) falls
  ## back to the Downloads folder until it can.
  var dir = downloadsDir()
  try: createDir(dir)
  except CatchableError:
    dir = systemDir
    try: createDir(dir) except CatchableError: discard
  putEnv("XDG_DOWNLOAD_DIR", dir)

proc setUpDirectory() =
  systemDir = defaultDownloadsDir()
  applyDirectory()

# ---------------------------------------------------------------------------------------------------------------
# Opening files

proc fileUri(path: string): string = "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")

when defined(android):
  # The Android host opens files with an app that takes them (through its FileProvider); there is no file manager
  # to select one in, so "Show in folder" opens the file too.
  proc openPath(path: string) =
    if hostCall("openFile", path) != "ok": toast("No app opens " & path.extractFilename)

  proc showInFolder*(path: string) = openPath(path)

else:
  proc openPath(path: string) =
    if g_app_info_launch_default_for_uri(fileUri(path).cstring, nil, nil) == 0:
      toast("No app opens " & path.extractFilename)

  proc showInFolder*(path: string) =
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

proc openDownloadsFolder() =
  when defined(android):
    if hostCall("showDownloads", "") != "ok": toast("No app shows downloads")
  else: openPath(downloadsDir())

# ---------------------------------------------------------------------------------------------------------------
# The list

proc parse(text: string): seq[Download] =
  try:
    for d in parseJson(text):
      result.add Download(id: uint64(d{"id"}.getBiggestInt), url: d{"url"}.getStr, path: d{"path"}.getStr,
        status: d{"status"}.getStr, error: d{"error"}.getStr, received: d{"received"}.getBiggestInt,
        total: d{"total"}.getBiggestInt(-1), rate: d{"rate"}.getBiggestInt(-1),
        remaining: d{"remaining"}.getBiggestInt(-1), created: d{"created"}.getBiggestInt, canResume: d{"canResume"}.getBool,
        private: d{"private"}.getBool)
  except CatchableError: discard

proc active(d: Download): bool = d.status in ["in_progress", "paused"]
proc name(d: Download): string = (if d.fileName.len > 0: d.fileName else: d.path.extractFilename)
proc available(d: Download): bool = d.path.startsWith("content://") or fileExists(d.path)

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
    (if d.available: size(d.received) else: "Deleted") & (let h = host(d.url); if h.len > 0: " · " & h else: "")
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
  kit.`visible=`(r.bar, d.active and d.total > 0)   # without a size, the bytes so far say it
  if d.active: kit.`value=`(r.bar, d.fraction)
  # Ladybird pauses only downloads it can resume (the server takes Range requests).
  kit.`visible=`(r.pauseButton, d.status == "paused" or d.status == "in_progress" and d.canResume)
  if r.status != d.status:
    r.status = d.status
    kit.`iconName=`(r.pauseButton, if d.status == "paused": "play_arrow" else: "pause")
    kit.`tooltip=`(r.pauseButton, if d.status == "paused": "Resume" else: "Pause")
    kit.`iconName=`(r.actionButton, if d.active: "close" else: "folder_open")
    kit.`tooltip=`(r.actionButton, if d.active: "Cancel" else: "Show in folder")
  kit.`enabled=`(r.actionButton, d.active and webby_downloads_cancel != nil or d.status == "completed" and d.available)

proc pauseOrResume(id: uint64) =
  let i = find(id)
  if i < 0: return
  if downloads[i].status == "paused": webby_downloads_resume(id) else: webby_downloads_pause(id)
  wake()

proc cancelOrShow(id: uint64) =
  let i = find(id)
  if i < 0: return
  if downloads[i].active:
    if webby_downloads_cancel != nil: webby_downloads_cancel(id); wake()
  else: showInFolder(downloads[i].path)

proc rowMenu(id: uint64) =
  ## Right-click: open, show in folder, copy the link, download it again.
  let at = find(id)
  if at < 0: return
  let d = downloads[at]
  var items: seq[kit.MenuItem]
  if d.status == "completed" and d.available:
    items.add kit.menuItem("Open", proc () = openPath(d.path))
    items.add kit.menuItem("Show in folder", proc () = showInFolder(d.path))
    items.add kit.menuSeparator()
  items.add kit.menuItem("Copy download link", proc () =
    copyUrl(d.url))
  if not d.active and webby_downloads_start != nil:
    items.add kit.menuItem("Download again", proc () =
      discard webby_downloads_start(d.url.cstring, d.private.cint)
      wake())
  kit.popupMenu(items)

proc openIfDone(id: uint64) =
  let at = find(id)
  if at >= 0 and downloads[at].status == "completed" and downloads[at].available: openPath(downloads[at].path)

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
    let l = kit.addClass(dim(if listed(): "Files you download show up here."
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

proc refreshAll()

proc clearList() =
  if webby_downloads_clear != nil: webby_downloads_clear()
  else:
    downloads.keepItIf(it.active)
    refreshAll()
  wake()

# ---------------------------------------------------------------------------------------------------------------
# Choosing where downloads go

proc tilde(path: string): string = path.replace(getHomeDir().strip(leading = false, chars = {'/'}), "~")

proc fillPanelTop()

proc setFolder(dir: string) =
  ## Downloads go to `dir` from now on ("" for the Downloads folder).
  pref()["folder"] = %(if dir == systemDir: "" else: dir)
  savePrefs()
  applyDirectory()
  fillPanelTop()
  toast("Downloads go to " & tilde(downloadsDir()))

proc changeFolder() =
  kit.chooseFolder("Download to", proc (dir: string) =
    if dir.len > 0: setFolder(dir), downloadsDir())

proc setAsk(on: bool) =
  pref()["ask"] = %on
  savePrefs()

proc settle(id: uint64) =
  ## Moves an asked download's finished file to where the user said, once both are known.
  let dest = destinations.getOrDefault(id, "")
  let i = find(id)
  if dest.len == 0 or i < 0 or downloads[i].status != "completed": return
  destinations.del id
  let src = downloads[i].path
  if src != dest:
    try: moveFile(src, dest)
    except CatchableError as e:
      toast("Couldn't move " & src.extractFilename & " to " & tilde(dest) & ": " & e.msg)
      return
  moved[id] = dest
  downloads[i].path = dest

proc askWhere(id: uint64, name: string) =
  ## The save chooser for a download that has just started (it keeps going meanwhile).
  kit.chooseFile("Save " & name, proc (path: string) =
    let i = find(id)
    if i < 0 or downloads[i].status in ["canceled", "failed"]:
      destinations.del id
    elif path.len == 0:
      destinations.del id
      if downloads[i].active:
        if webby_downloads_cancel != nil: webby_downloads_cancel(id)
      else:
        try: removeFile(downloads[i].path) except CatchableError: discard
      toast("Canceled " & name)
      refreshAll()
      wake()
    else:
      destinations[id] = path
      settle(id)
      if id in moved: toast(path.extractFilename & " saved")
      refreshAll(), save = true, name = name, folder = downloadsDir())

proc toggleDownloads*() =
  if not listed():
    openPath(downloadsDir())
    return
  if panelOpen:
    closeSidePanel()
    return
  panelTop = kit.column()
  panelList = kit.column()
  panelList.spacing = 0
  let body = kit.column(panelTop, kit.expand(kit.scroll(panelList)))
  body.spacing = 4
  panelOpen = true
  showSidePanel("Downloads", body, 360, proc () =
    panelOpen = false
    panelTop = nil
    panelList = nil
    rows.clear)
  fillPanelTop()
  fillPanel()

proc fillPanelTop() =
  ## The folder downloads go to, with buttons to open it, pick another and clear the list; on the desktop also
  ## whether to ask where to save each file.
  if panelTop == nil: return
  kit.clear(panelTop)
  let where = dim(tilde(downloadsDir()))
  kit.`tooltip=`(where, downloadsDir())
  var buttons = @[kit.expand(where),
    kit.iconButton("folder_open", "Open the download folder", openDownloadsFolder)]
  when not defined(android):
    buttons.add kit.iconButton("edit_outlined", "Change the download folder", changeFolder)
  buttons.add kit.iconButton("delete_sweep_outlined", "Clear finished downloads from the list", clearList)
  let top = kit.addClass(kit.row(buttons), "webby-panel-top")
  top.spacing = 4
  kit.add(panelTop, top)
  when not defined(android):
    let ask = kit.addClass(kit.check("Ask where to save each file", askEachTime(), setAsk), "webby-panel-top")
    kit.add(panelTop, ask)
    if chosenDir().len > 0:
      let reset = kit.addClass(kit.button("Use " & tilde(systemDir), proc () = setFolder("")), "webby-panel-top")
      kit.add(panelTop, kit.row(reset))

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
    if percent != nil:
      kit.`text=`(percent, if sized and total > 0: $int(got.float * 100 / total.float) & "%" else: size(got))
  if percent != nil: kit.`visible=`(percent, running > 0)
  kit.`tooltip=`(button, tip)

proc announce() =
  ## A note when a download starts and when it finishes or fails (the sidebar shows it all when it's open).
  for d in downloads:
    let before = known.getOrDefault(d.id, "")
    if before == d.status: continue
    known[d.id] = d.status
    if d.created > 0 and d.created < startedMs: continue
    if before.len == 0 and (d.active or d.status == "completed") and askEachTime() and hasApi():
      destinations[d.id] = ""
      let (id, name) = (d.id, d.name)
      discard after(0, proc () = askWhere(id, name))   # not from inside the list's refresh
      continue
    if panelOpen: continue
    if before.len == 0 and d.active: toast("Downloading " & d.name & " (Ctrl+J shows downloads)")
    elif d.status == "completed":
      if d.id notin destinations: toast(d.name & " downloaded")   # else when the chooser closes
    elif d.status == "failed": toast("Couldn't download " & d.name)

proc pauseDownload*(id: uint64) =
  if webby_downloads_pause != nil:
    webby_downloads_pause(id)
    wake()
proc resumeDownload*(id: uint64) =
  if webby_downloads_resume != nil:
    webby_downloads_resume(id)
    wake()
proc cancelDownload*(id: uint64) =
  if webby_downloads_cancel != nil:
    webby_downloads_cancel(id)
    wake()

proc refreshAll() =
  if downloadsChangedHooks.len > 0:
    var list: seq[DownloadInfo]
    for d in downloads:
      list.add DownloadInfo(id: d.id, url: d.url, path: d.path, name: d.name, status: d.status, error: d.error,
        received: d.received, total: d.total, rate: d.rate, canResume: d.canResume,
        fresh: d.created == 0 or d.created >= startedMs)
    for h in downloadsChangedHooks: h(list)
  announce()
  refreshButton()
  refreshPanel()

proc onHostEvent(name, data: string) =
  ## Android: the folder watcher's {name, status, received, path} for one file.
  if name != "download": return
  try:
    let e = parseJson(data)
    let file = e{"name"}.getStr
    var id = hostIds.getOrDefault(file, 0)
    var at = find(id)
    if at < 0 or not downloads[at].active and e{"status"}.getStr == "in_progress":
      inc hostSerial
      id = hostSerial
      hostIds[file] = id
      downloads.add Download(id: id, fileName: file, path: downloadsDir() / file, total: -1, rate: -1, remaining: -1)
      at = downloads.high
    downloads[at].status = e{"status"}.getStr
    let received = e{"received"}.getBiggestInt
    if received > 0 or downloads[at].status != "in_progress": downloads[at].received = received
    if e{"path"}.getStr.len > 0: downloads[at].path = e{"path"}.getStr
    refreshAll()
  except CatchableError: discard

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
    for d in downloads.mitems:
      if d.id in moved: d.path = moved[d.id]
    for id in toSeq(destinations.keys): settle(id)
    refreshAll())

proc install*() =
  startupHooks.add setUpDirectory
  addShortcut(modCtrl, 0x6a, toggleDownloads)   # Ctrl+J
  windowHooks.add proc () =
    if appUrl.len > 0: return
    addMenuItem("Downloads", toggleDownloads, "Ctrl+J")
    loadCss("button.webby-download-row { padding: 6px 4px 6px 10px; }\n" &
      ".webby-download-row button { padding: 2px; min-height: 0; }\n" &
      ".webby-download-percent { margin: 0 6px 0 -2px; }\n" &
      ".webby-downloads-empty { margin-top: 24px; }\n.webby-panel-top { margin: 0 4px 0 8px; }")
    if not listed(): return
    button = addToolbarButton("download", "Downloads (Ctrl+J)", toggleDownloads, "download", "Downloads")
    kit.`visible=`(button, false)
    when not defined(android):
      percent = kit.addClass(kit.addClass(kit.label(""), "small"), "webby-download-percent")
      kit.add(toolbarEndRow, percent)
      kit.`visible=`(percent, false)
    if hasApi(): pumpHooks.add poll
    else:
      when defined(android): hostEventHooks.add onHostEvent
