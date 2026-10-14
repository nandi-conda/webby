## HTTP for the shared stores, done by Java's HttpURLConnection on worker threads: base.httpRequest (sync) as "http"
## events answered on the main thread with the "http.done" command, and base.httpStream (summaries) as "httpStream"
## events answered piece by piece. Bodies travel in base64 so any bytes survive.

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

# Streams ("httpStream" events; Java answers with httpStream.status, .data and .done as the body comes in)

type Stream = object
  onStatus: proc (status: int)
  onData: proc (data: string)
  onDone: proc (error: string)

var streams: Table[int, Stream]

proc startStream(meth, url: string, headers: seq[(string, string)], body: string, onStatus: proc (status: int),
                 onData: proc (data: string), onDone: proc (error: string)): int =
  let id = nextId
  inc nextId
  streams[id] = Stream(onStatus: onStatus, onData: onData, onDone: onDone)
  var hs = newJArray()
  for (k, v) in headers: hs.add %*[k, v]
  event("httpStream", %*{"id": id, "method": meth, "url": url, "headers": hs, "body": encode(body)})
  id

proc cancelStream(id: int) =
  if id in streams:
    streams.del id
    event("httpStreamCancel", %*{"id": id})

proc streamStatus(args: JsonNode): JsonNode =
  let s = streams.getOrDefault(args{"id"}.getInt)
  if s.onStatus != nil: s.onStatus(args{"status"}.getInt)
  nil

proc streamData(args: JsonNode): JsonNode =
  let s = streams.getOrDefault(args{"id"}.getInt)
  if s.onData != nil:
    var data = ""
    try: data = decode(args{"data"}.getStr) except CatchableError: discard
    s.onData(data)
  nil

proc streamDone(args: JsonNode): JsonNode =
  let id = args{"id"}.getInt
  if id notin streams: return nil
  let s = streams[id]
  streams.del id
  s.onDone(args{"error"}.getStr)
  nil

proc install*() =
  base.httpRequest = start
  base.httpStream = startStream
  base.httpStreamCancel = cancelStream
  commands["http.done"] = finished
  commands["httpStream.status"] = streamStatus
  commands["httpStream.data"] = streamData
  commands["httpStream.done"] = streamDone
