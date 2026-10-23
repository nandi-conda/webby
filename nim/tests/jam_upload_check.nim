## Uploads a screenshot Jam and a video Jam through features/bugreport/jam.nim with made-up console, network and
## user events, and prints their links. Run by .github/workflows/jam-upload-check.yml with the JAM_TOKEN secret.
##
## Usage: JAM_TOKEN=jam_pat_... jam_upload_check <screenshot.png> <recording.webm>

import std/[json, os, times]
from nimkit/backend/gtk as nkgtk import nil   # nimkit's services on GLib: HTTP over GIO, timers
import ../src/features/bugreport/[events, jam]

proc g_main_loop_new(ctx: pointer, running: cint): pointer {.importc, cdecl.}
proc g_main_loop_run(loop: pointer) {.importc, cdecl.}
proc g_main_loop_quit(loop: pointer) {.importc, cdecl.}

let loop = g_main_loop_new(nil, 0)
var failed = false

proc sample(start: int64): Captured =
  result = newCaptured()
  let dump = %*{"doc": "d1", "seq": 6, "url": "https://example.com/checkout",
    "console": [
      {"seq": 1, "t": start + 500, "level": "info", "args": ["checkout loaded", "{\"items\":2}"]},
      {"seq": 2, "t": start + 1500, "level": "error", "args": ["Payment failed", "502"],
       "trace": ["pay (https://example.com/app.js:10:5)"]}],
    "network": [
      {"seq": 3, "t": start + 800, "kind": "fetch", "method": "GET", "url": "https://example.com/api/cart",
       "status": 200, "duration": 120, "type": "application/json", "size": 42},
      {"seq": 4, "t": start + 1400, "kind": "fetch", "method": "POST", "url": "https://example.com/api/pay",
       "status": 502, "statusText": "Bad Gateway", "duration": 300, "type": "application/json",
       "requestBody": "{\"card\":\"***\"}", "responseBody": "{\"error\":\"upstream timeout\"}"}],
    "actions": [
      {"seq": 5, "t": start + 1300, "kind": "click", "x": 100, "y": 200,
       "target": {"attributes": {"tagName": "button", "id": "pay"}, "text": "Pay now"}},
      {"seq": 6, "t": start + 1200, "kind": "input", "text": "Ada",
       "target": {"attributes": {"tagName": "input", "name": "name"}, "text": ""}}],
    "resources": []}
  result.addDump(dump, 1)
  result.addNavigation(start + 100, "https://example.com/checkout", "Checkout", 1, "load")

proc check(video: bool, media: string, next: proc ()) =
  let start = (epochTime() * 1000).int64 - 3000
  var u = Upload(token: getEnv("JAM_TOKEN"), video: video, media: readFile(media),
    mediaType: (if video: "video/webm" else: "image/png"), poster: readFile(paramStr(1)),
    title: "webby jam.nim check (" & (if video: "video" else: "screenshot") & ") - safe to delete",
    description: "Made by nim/tests/jam_upload_check.nim.\n- console, network and actions attached\n- safe to delete",
    url: "https://example.com/checkout", width: 640, height: 360, durationMs: 3000, viewport: (640, 360),
    browser: "Webby", browserVersion: "check", os: "Linux", osVersion: "ci")
  # The video starts 1 s in, after the navigation, the first console message and the first request.
  u.events = sample(start).jamEvents((if video: start + 1000 else: start), u.url, (640, 360), video)
  jam.upload(u, proc (text: string) = echo("  ", text), proc (ok: bool, url, error: string) =
    if ok: echo (if video: "VIDEO " else: "SCREENSHOT "), url
    else:
      echo "FAILED ", error
      failed = true
    next())

check(false, paramStr(1), proc () =
  check(true, paramStr(2), proc () = g_main_loop_quit(loop)))
g_main_loop_run(loop)
quit(if failed: 1 else: 0)
