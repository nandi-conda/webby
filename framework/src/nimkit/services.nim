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

var
  serviceImpl*: Services
  platform*: string                     ## "gtk", "android" or "web", set by the backend
  appName* = "nimkit-app"               ## names the app's data folder (desktop) or key prefix (web)
  userAgent* = ""                       ## the User-Agent of `request` where the backend sets it (default: appName)

proc after*(ms: int, action: proc ()): Timer =
  ## Runs `action` once, `ms` from now, on the UI thread.
  let t = Timer()
  t.id = serviceImpl.startTimer(ms, proc () =
    t.id = 0
    action())
  t

proc every*(ms: int, action: proc ()): Timer =
  ## Runs `action` every `ms` until the timer is cancelled.
  let t = Timer()
  proc tick() =
    t.id = serviceImpl.startTimer(ms, tick)
    action()
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
  serviceImpl.request(meth, url, headers, body, onDone)

proc log*(text: string) =
  if serviceImpl.log != nil: serviceImpl.log(text) else: echo text
