## Downloads in Plasma's job tracker (the notifications applet's progress, like Dolphin's copies): each download
## started in this session gets a job view from org.kde.JobViewServer (JobViewServerV2.requestView, then
## JobViewV3.update/terminate), and the applet's pause, resume and cancel come back as its signals.

import std/[monotimes, strutils, tables, times, uri]
import ../../browser
import ../downloads
import dbus

const
  server = "org.kde.JobViewServer"
  viewIface = "org.kde.JobViewV3"
  canCancel = 1
  canSuspend = 2

type Job = object
  path: string          ## the job view's object path, "" while requestView is on its way
  sent: string          ## the last update's text
  lastUpdate: MonoTime
  status: string
  done: bool

var
  jobs: Table[uint64, Job]
  byPath: Table[string, uint64]
  subscribed = false
  available = true       ## false once requestView failed (no Plasma): stop asking
  desktopEntry* = "webby"
  latest: Table[uint64, DownloadInfo]

proc fileUrl(path: string): string = "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")

proc props(d: DownloadInfo): string =
  var parts = @["'title': <'Downloading'>", "'descriptionLabel1': <'Source'>",
    "'descriptionValue1': <" & q(d.url) & ">", "'descriptionLabel2': <'Destination'>",
    "'descriptionValue2': <" & q(d.name) & ">", "'processedBytes': <uint64 " & $max(d.received, 0) & ">",
    "'suspended': <" & (if d.status == "paused": "true" else: "false") & ">"]
  if d.path.len > 0: parts.add "'destUrl': <" & q(fileUrl(d.path)) & ">"
  if d.total > 0:
    parts.add "'totalBytes': <uint64 " & $d.total & ">"
    parts.add "'percent': <uint32 " & $(min(100, d.received * 100 div d.total)) & ">"
  if d.rate >= 0 and d.status == "in_progress": parts.add "'speed': <uint64 " & $d.rate & ">"
  "{" & parts.join(", ") & "}"

proc terminate(path: string, d: DownloadInfo) =
  # KJob's error codes: 0 done, 1 killed (the applet shows nothing more), else a failure with its message.
  let (code, text) = case d.status
    of "completed": (0, "")
    of "canceled": (1, "")
    else: (100, if d.error.len > 0: d.error else: "Couldn't download " & d.name)
  call(server, path, viewIface, "terminate", gv("(usa{sv})", "(uint32 " & $code & ", " & q(text) & ", @a{sv} {})"))

proc onSignal(member: string): SignalHandler =
  result = proc (path: string, params: GVariant) =
    let id = byPath.getOrDefault(path, 0)
    if id == 0 or id notin jobs: return
    case member
    of "cancelRequested": cancelDownload(id)
    of "suspendRequested": pauseDownload(id)
    of "resumeRequested": resumeDownload(id)

proc subscribeOnce() =
  if subscribed: return
  subscribed = true
  for m in ["cancelRequested", "suspendRequested", "resumeRequested"]:
    discard subscribe(busSession, server, viewIface, m, "", onSignal(m))

proc update(d: DownloadInfo) =
  var j = jobs[d.id]
  if j.path.len == 0: return
  let finished = d.status notin ["in_progress", "paused"]
  let text = props(d)
  # Progress at most twice a second; other changes (pause, the end) right away.
  if text != j.sent and (finished or d.status != j.status or getMonoTime() - j.lastUpdate >= initDuration(milliseconds = 500)):
    call(server, j.path, viewIface, "update", gv("(a{sv})", "(" & text & ",)"))
    j.sent = text
    j.status = d.status
    j.lastUpdate = getMonoTime()
  if finished and not j.done:
    j.done = true
    terminate(j.path, d)
  jobs[d.id] = j

proc request(d: DownloadInfo) =
  subscribeOnce()
  jobs[d.id] = Job(status: d.status)
  let id = d.id
  let caps = canCancel or (if d.canResume: canSuspend else: 0)
  let hints = props(d)[0 .. ^2] & ", 'immediate': <true>}"   # show it now (the extension's delay is ours)
  call(server, "/JobViewServer", "org.kde.JobViewServerV2", "requestView",
    gv("(sia{sv})", "(" & q(desktopEntry) & ", " & $caps & ", " & hints & ")"),
    proc (res: GVariant, error: string) =
      if res == nil:
        available = false   # no Plasma (or an older one): downloads still show in webby's own sidebar
        jobs.del id
        return
      let path = res.stringAt(0)
      byPath[path] = id
      jobs[id].path = path
      jobs[id].sent = ""
      jobs[id].lastUpdate = MonoTime()
      update(latest.getOrDefault(id, d)))   # the full state, which may have moved on (or ended) meanwhile

proc onDownloads(list: seq[DownloadInfo]) =
  if not available: return
  for d in list:
    latest[d.id] = d
    if d.id notin jobs:
      if d.fresh and d.status in ["in_progress", "paused"]: request(d)
    elif not jobs[d.id].done: update(d)

proc install*() =
  downloadsChangedHooks.add onDownloads
