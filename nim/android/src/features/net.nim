## HTTP for the shared stores (base.httpRequest: sync, summaries), done by Java's HttpURLConnection on a worker
## thread ("http" events); the answer comes back on the main thread as the "http.done" command. Bodies travel in
## base64 so any bytes survive.

import std/base64
import ../core

type Done = proc (status: int, reason: string, headers: seq[(string, string)], body, error: string)

var
  pending: Table[int, Done]
  nextId = 1

proc start(meth, url: string, headers: seq[(string, string)], body: string, done: Done) =
  let id = nextId
  inc nextId
  pending[id] = done
  var hs = newJArray()
  for (k, v) in headers: hs.add %*[k, v]
  event("http", %*{"id": id, "method": meth, "url": url, "headers": hs, "body": encode(body)})

proc finished(args: JsonNode): JsonNode =
  let id = args{"id"}.getInt
  let done = pending.getOrDefault(id)
  pending.del id
  if done == nil: return nil
  var hs: seq[(string, string)]
  for h in args{"headers"}.getElems: hs.add (h[0].getStr, h[1].getStr)
  var body = ""
  try: body = decode(args{"body"}.getStr) except CatchableError: discard
  done(args{"status"}.getInt, args{"reason"}.getStr, hs, body, args{"error"}.getStr)
  nil

proc install*() =
  base.httpRequest = start
  commands["http.done"] = finished
