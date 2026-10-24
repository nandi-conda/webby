## The non-widget services every backend provides, with one API: timers on the UI thread, a small key-value store
## for the app's data, and HTTP. The backend fills in the hooks when it is imported; apps call the procs below.

import std/strutils

type
  Response* = object
    status*: int                        ## 0 when the request failed; `error` says why
    reason*, body*, error*: string
    headers*: seq[(string, string)]     ## names in lower case

  Timer* = ref object
    id*: int

  Services* = object
    startTimer*: proc (ms: int, action: proc ()): int
    stopTimer*: proc (id: int)
    load*: proc (key: string): string
    store*: proc (key, value: string)
    request*: proc (meth, url: string, headers: seq[(string, string)], body: string, onDone: proc (r: Response))
    log*: proc (text: string)
    copyText*: proc (text: string)
    pasteText*: proc (onDone: proc (text: string))
    hostCall*: proc (name, arg: string): string

var
  serviceImpl*: Services
  platform*: string                     ## "gtk", "android" or "web", set by the backend
  appName* = "nimkit-app"               ## names the app's data folder (desktop) or key prefix (web)
  userAgent* = ""                       ## the User-Agent of `request` where the backend sets it (default: appName)
  hostEventHooks*: seq[proc (name, data: string)]  ## events from the app's own platform code (see hostCall)

proc log*(text: string)

proc shielded*(where: string, action: proc ()) =
  ## Runs `action`, logging instead of passing on anything it raises, Defects included (panics are off). An error
  ## escaping a timer or signal reaches GLib's C code, which can't unwind it: Nim's error flag stays set and every
  ## later Nim call on the UI thread returns early, so the window stops responding without exiting.
  try: action()
  except Exception as e:
    log(where & ": " & $e.name & ": " & e.msg & (let t = e.getStackTrace(); if t.len > 0: "\n" & t else: ""))

proc after*(ms: int, action: proc ()): Timer =
  ## Runs `action` once, `ms` from now, on the UI thread.
  let t = Timer()
  t.id = serviceImpl.startTimer(ms, proc () =
    t.id = 0
    shielded("timer", action))
  t

proc every*(ms: int, action: proc ()): Timer =
  ## Runs `action` every `ms` until the timer is cancelled.
  let t = Timer()
  proc tick() =
    t.id = serviceImpl.startTimer(ms, tick)
    shielded("timer", action)
  t.id = serviceImpl.startTimer(ms, tick)
  t

proc cancel*(t: Timer) =
  if t != nil and t.id != 0:
    serviceImpl.stopTimer(t.id)
    t.id = 0

proc load*(key: string): string =
  ## The app's stored value for `key` ("" if none): a file in the app's data folder, or localStorage on the web.
  serviceImpl.load(key)

proc store*(key, value: string) = serviceImpl.store(key, value)

proc header*(r: Response, name: string): string =
  let name = name.toLowerAscii
  for (k, v) in r.headers:
    if k == name: return v

proc request*(meth, url: string, onDone: proc (r: Response), headers: seq[(string, string)] = @[], body = "") =
  ## An HTTP(S) request; `onDone` runs on the UI thread with the whole response. On the web this is fetch(), so
  ## the server must allow the page's origin (CORS).
  serviceImpl.request(meth, url, headers, body, proc (r: Response) = shielded("request " & url, proc () = onDone(r)))

proc copyText*(text: string) =
  ## Puts `text` on the system clipboard.
  if serviceImpl.copyText != nil: serviceImpl.copyText(text)

proc pasteText*(onDone: proc (text: string)) =
  ## The system clipboard's text ("" if none or not allowed), soon: the web asks the user's leave first.
  if serviceImpl.pasteText != nil: serviceImpl.pasteText(onDone) else: onDone("")

proc log*(text: string) =
  if serviceImpl.log != nil: serviceImpl.log(text) else: echo text

proc hostCall*(name: string, arg = ""): string =
  ## Calls app-specific platform code the app added to its host, synchronously: on Android its Host subclass's
  ## onHostCall(name, arg). "" where there is none. The host answers later through hostEvent when it must wait.
  if serviceImpl.hostCall != nil: serviceImpl.hostCall(name, arg) else: ""

proc hostEvent*(name, data: string) =
  ## Backends call this when the app's platform code reports something (on Android, Host.hostEvent).
  for h in hostEventHooks: h(name, data)
