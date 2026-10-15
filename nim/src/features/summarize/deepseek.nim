## DeepSeek chat completions, streamed (the HTTP half of app/lib/src/summarize.dart). A small HTTP/1.1 client on
## GIO's async sockets (TLS from glib-networking), so it runs on the GTK main loop: nothing blocks, every callback
## is on the GTK thread. Not std/httpclient: with -d:ssl, Nim loads the system's OpenSSL at startup, and then
## libwebby.so can't load the runtime's newer libcrypto. WEBBY_DEEPSEEK_ENDPOINT overrides the endpoint (tests
## use a local fake server; http:// works too). On Android the bytes come from Java's HttpURLConnection instead
## (base.httpStream); the parsing and the messages are the same.

import std/[json, monotimes, os, strutils, times]
when defined(android):
  import ../../base
else:
  import std/uri
  import ../../browser

const
  defaultEndpoint = "https://api.deepseek.com/chat/completions"
  busyLimit = initDuration(seconds = 90)   ## how long DeepSeek may keep a request queued before we give up
  busyMessage* = "DeepSeek kept the request waiting in its queue for 90 seconds without starting on it, which it " &
    "does when it's overloaded. Try again in a while."

when not defined(android):
 {.push cdecl, importc.}
 proc g_socket_client_new(): pointer
 proc g_socket_client_set_tls(c: pointer, on: gboolean)
 proc g_socket_client_connect_to_host_async(c: pointer, hostAndPort: cstring, defaultPort: uint16,
                                            cancellable, callback, data: pointer)
 proc g_socket_client_connect_to_host_finish(c, res: pointer, error: ptr pointer): pointer
 proc g_io_stream_get_input_stream(s: pointer): pointer
 proc g_io_stream_get_output_stream(s: pointer): pointer
 proc g_output_stream_write_all_async(s: pointer, buffer: pointer, count: csize_t, priority: cint,
                                      cancellable, callback, data: pointer)
 proc g_output_stream_write_all_finish(s, res: pointer, written: ptr csize_t, error: ptr pointer): gboolean
 proc g_input_stream_read_async(s: pointer, buffer: pointer, count: csize_t, priority: cint,
                                cancellable, callback, data: pointer)
 proc g_input_stream_read_finish(s, res: pointer, error: ptr pointer): int
 proc g_cancellable_new(): pointer
 proc g_cancellable_cancel(c: pointer)
 proc g_error_free(e: pointer)
 {.pop.}

type
  GError = object
    domain: uint32
    code: cint
    message: cstring

  BodyMode = enum bodyUntilClose, bodyLength, bodyChunked

  Chat* = ref object
    ## One streaming request. `onPiece` gets each piece of the reply; `onDone` gets "" or an error message, once.
    onPiece*: proc (piece: string)
    onDone*: proc (error: string)
    onQueued*: proc ()          ## called when DeepSeek says it has queued the request (": keep-alive" lines)
    queued*: bool               ## DeepSeek holds the request in its queue and hasn't sent a piece yet
    gotPiece: bool
    lastPiece: MonoTime         ## when the last piece came (or the request was sent)
    finished: bool
    client, conn, cancellable: pointer
    request: string
    readBuf: array[16384, char]
    raw, body, events: string   ## bytes not parsed yet; the decoded body; body not yet split into SSE lines
    gotHeaders, done: bool
    status: int
    mode: BodyMode
    remaining: int              ## content-length bytes left, or bytes left in the current chunk
    inChunk: bool
    started, lastData: MonoTime
    stream: int                 ## Android: the base.httpStream id

var
  chats: seq[Chat]
  tickSource: cuint

when not defined(android):
  proc errorText(e: pointer): string =
    if e == nil: return "unknown error"
    result = $cast[ptr GError](e).message
    g_error_free(e)

proc release(c: Chat) =
  when defined(android):
    if base.httpStreamCancel != nil: base.httpStreamCancel(c.stream)
  else:
    g_cancellable_cancel(c.cancellable)
    if c.conn != nil: g_object_unref(c.conn)
    g_object_unref(c.client)
    g_object_unref(c.cancellable)
    c.conn = nil

proc finish(c: Chat, error: string) =
  if c.finished: return
  c.finished = true
  let i = chats.find(c)
  if i >= 0: chats.delete i
  c.release()
  if c.onDone != nil: c.onDone(error)

proc cancel*(c: Chat) =
  ## Stops the request without calling `onDone`.
  if c == nil or c.finished: return
  c.onDone = nil
  c.finish("")

proc describeFailure(status: int, body: string): string =
  var detail = ""
  try:
    let e = parseJson(body){"error"}
    if e != nil and e.kind == JObject: detail = e{"message"}.getStr
  except CatchableError: discard
  case status
  of 401: "DeepSeek didn't accept the API key. Check it under Summarize settings."
  of 402: "The DeepSeek account is out of balance."
  of 429: "DeepSeek is rate limiting requests; try again in a moment."
  else: "DeepSeek answered with an error (" & $status & ")" & (if detail.len > 0: ": " & detail else: "") & "."

proc handleEvents(c: Chat) =
  ## Server-sent events: each `data: {...}` line carries a piece in choices[0].delta.content.
  while not c.finished and not c.done:
    let nl = c.events.find('\n')
    if nl < 0: return
    let line = c.events[0 ..< nl].strip(leading = false, chars = {'\r'})
    c.events = c.events[nl + 1 .. ^1]
    if line.startsWith(":"):
      # A comment: DeepSeek sends ": keep-alive" every few seconds while the request waits in its queue (when it's
      # overloaded). They keep the connection alive, so the reply timeout never fires: give up after busyLimit.
      if not c.gotPiece:
        if not c.queued:
          c.queued = true
          if c.onQueued != nil: c.onQueued()
        if getMonoTime() - c.lastPiece > busyLimit:
          c.finish(busyMessage)
          return
      continue
    if not line.startsWith("data:"): continue
    let data = line[5 .. ^1].strip
    if data == "[DONE]":
      c.done = true
      return
    try:
      let choices = parseJson(data){"choices"}
      if choices == nil or choices.kind != JArray or choices.len == 0: continue
      let content = choices[0]{"delta", "content"}
      if content != nil and content.kind == JString and content.getStr.len > 0:
        c.gotPiece = true
        c.queued = false
        c.lastPiece = getMonoTime()
        if c.onPiece != nil: c.onPiece(content.getStr)
    except CatchableError: discard

proc addBody(c: Chat, data: string) =
  if c.status == 200:
    c.events.add data
    c.handleEvents()
  else: c.body.add data

proc parseRaw(c: Chat) =
  ## Status line and headers, then the body as it comes (chunked, sized, or up to the end).
  if not c.gotHeaders:
    let e = c.raw.find("\r\n\r\n")
    if e < 0: return
    let lines = c.raw[0 ..< e].split("\r\n")
    c.raw = c.raw[e + 4 .. ^1]
    c.gotHeaders = true
    let parts = lines[0].splitWhitespace
    c.status = if parts.len >= 2: (try: parseInt(parts[1]) except ValueError: 0) else: 0
    c.mode = bodyUntilClose
    for h in lines[1 .. ^1]:
      let colon = h.find(':')
      if colon < 0: continue
      let (name, value) = (h[0 ..< colon].strip.toLowerAscii, h[colon + 1 .. ^1].strip)
      if name == "transfer-encoding" and "chunked" in value.toLowerAscii: c.mode = bodyChunked
      elif name == "content-length" and c.mode != bodyChunked:
        c.mode = bodyLength
        c.remaining = try: parseInt(value) except ValueError: 0
  case c.mode
  of bodyUntilClose:
    c.addBody(c.raw)
    c.raw.setLen 0
  of bodyLength:
    let n = min(c.remaining, c.raw.len)
    c.addBody(c.raw[0 ..< n])
    c.raw = c.raw[n .. ^1]
    c.remaining -= n
    if c.remaining == 0: c.done = true
  of bodyChunked:
    while not c.done and not c.finished:
      if not c.inChunk:
        let nl = c.raw.find("\r\n")
        if nl < 0: return
        let size = c.raw[0 ..< nl].split(';')[0].strip
        c.raw = c.raw[nl + 2 .. ^1]
        if size.len == 0: continue          # the CRLF after a chunk's data
        c.remaining = try: parseHexInt(size) except ValueError: 0
        if c.remaining == 0:
          c.done = true
          return
        c.inChunk = true
      let n = min(c.remaining, c.raw.len)
      if n == 0: return
      c.addBody(c.raw[0 ..< n])
      c.raw = c.raw[n .. ^1]
      c.remaining -= n
      if c.remaining == 0: c.inChunk = false

proc ended(c: Chat) =
  ## The response is complete (or the server closed the connection).
  if not c.gotHeaders: c.finish("Couldn't reach DeepSeek (the connection closed).")
  elif c.status != 200: c.finish(describeFailure(c.status, c.body))
  else:
    if not c.done: c.events.add "\n"
    c.handleEvents()
    c.finish("")

when defined(android):
  proc streamChat*(apiKey: string, body: JsonNode, onPiece: proc (piece: string), onDone: proc (error: string),
                   onQueued: proc () = nil): Chat =
    ## Posts a chat completions `body` (with "stream": true) and streams the reply. Java times the connection out
    ## after 15 s and the reply after 60 s without data.
    let e = getEnv("WEBBY_DEEPSEEK_ENDPOINT")
    let c = Chat(onPiece: onPiece, onDone: onDone, onQueued: onQueued, started: getMonoTime(),
      lastData: getMonoTime(), lastPiece: getMonoTime())
    result = c
    if base.httpStream == nil:
      c.finish("Couldn't reach DeepSeek (no network here).")
      return
    chats.add c
    c.stream = base.httpStream("POST", (if e.len > 0: e else: defaultEndpoint),
      @[("Authorization", "Bearer " & apiKey), ("Content-Type", "application/json"), ("Accept", "text/event-stream"),
        ("User-Agent", "webby")], $body,
      proc (status: int) =
        c.gotHeaders = true
        c.status = status,
      proc (data: string) =
        if c.finished: return
        c.lastData = getMonoTime()
        c.addBody(data)
        if c.done and not c.finished: c.ended(),
      proc (error: string) =
        if c.finished: return
        if error.len == 0: c.ended()
        elif c.gotHeaders: c.finish("The answer from DeepSeek broke off (" & error & ").")
        else: c.finish("Couldn't reach DeepSeek (" & error & ")."))
else:
  proc readMore(c: Chat)

  proc onRead(source, res, data: pointer) {.cdecl.} =
    let c = cast[Chat](data)
    defer: GC_unref(c)
    var err: pointer
    let n = g_input_stream_read_finish(source, res, addr err)
    if c.finished:
      if err != nil: g_error_free(err)
      return
    if n < 0:
      let msg = errorText(err)
      c.finish(if c.gotHeaders: "The answer from DeepSeek broke off (" & msg & ")." else:
        "Couldn't reach DeepSeek (" & msg & ").")
      return
    if n == 0:
      c.ended()
      return
    c.lastData = getMonoTime()
    var s = newString(n)
    copyMem(addr s[0], addr c.readBuf[0], n)
    c.raw.add s
    c.parseRaw()
    if c.finished: return
    if c.done: c.ended()
    else: c.readMore()

  proc readMore(c: Chat) =
    GC_ref(c)
    g_input_stream_read_async(g_io_stream_get_input_stream(c.conn), addr c.readBuf[0], c.readBuf.len.csize_t, 0,
      c.cancellable, onRead, cast[pointer](c))

  proc onWritten(source, res, data: pointer) {.cdecl.} =
    let c = cast[Chat](data)
    defer: GC_unref(c)
    var err: pointer
    var written: csize_t
    let ok = g_output_stream_write_all_finish(source, res, addr written, addr err) != 0
    if c.finished:
      if err != nil: g_error_free(err)
      return
    if not ok:
      c.finish("Couldn't reach DeepSeek (" & errorText(err) & ").")
      return
    c.readMore()

  proc onConnected(source, res, data: pointer) {.cdecl.} =
    let c = cast[Chat](data)
    defer: GC_unref(c)
    var err: pointer
    let conn = g_socket_client_connect_to_host_finish(source, res, addr err)
    if c.finished:
      if conn != nil: g_object_unref(conn)
      if err != nil: g_error_free(err)
      return
    if conn == nil:
      c.finish("Couldn't reach DeepSeek (" & errorText(err) & ").")
      return
    c.conn = conn
    GC_ref(c)
    g_output_stream_write_all_async(g_io_stream_get_output_stream(conn), addr c.request[0], c.request.len.csize_t, 0,
      c.cancellable, onWritten, cast[pointer](c))

  proc tick(data: pointer): gboolean {.cdecl.} =
    # Timeouts as in the Dart client: 15 s to connect, then 60 s for the headers and between pieces.
    let now = getMonoTime()
    for c in chats:
      let late = if c.conn == nil: now - c.started > initDuration(seconds = 15)
                 else: now - c.lastData > initDuration(seconds = 60)
      if late:
        c.finish("DeepSeek took too long to answer.")
        break
      if c.queued and now - c.lastPiece > busyLimit:
        c.finish(busyMessage)
        break
    if chats.len > 0: return 1
    tickSource = 0
    0

  proc streamChat*(apiKey: string, body: JsonNode, onPiece: proc (piece: string), onDone: proc (error: string),
                   onQueued: proc () = nil): Chat =
    ## Posts a chat completions `body` (with "stream": true) and streams the reply.
    let e = getEnv("WEBBY_DEEPSEEK_ENDPOINT")
    let u = parseUri(if e.len > 0: e else: defaultEndpoint)
    let tls = u.scheme != "http"
    let port = if u.port.len > 0: u.port elif tls: "443" else: "80"
    let host = if ':' in u.hostname: "[" & u.hostname & "]" else: u.hostname
    let payload = $body
    var path = if u.path.len > 0: u.path else: "/"
    if u.query.len > 0: path.add "?" & u.query
    result = Chat(onPiece: onPiece, onDone: onDone, onQueued: onQueued, client: g_socket_client_new(),
      cancellable: g_cancellable_new(), started: getMonoTime(), lastData: getMonoTime(), lastPiece: getMonoTime())
    result.request = "POST " & path & " HTTP/1.1\r\n" &
      "Host: " & host & (if u.port.len > 0: ":" & u.port else: "") & "\r\n" &
      "Authorization: Bearer " & apiKey & "\r\n" &
      "Content-Type: application/json\r\nAccept: text/event-stream\r\nUser-Agent: webby\r\nConnection: close\r\n" &
      "Content-Length: " & $payload.len & "\r\n\r\n" & payload
    g_socket_client_set_tls(result.client, tls.gboolean)
    chats.add result
    GC_ref(result)
    g_socket_client_connect_to_host_async(result.client, cstring(host & ":" & port), 0, result.cancellable,
      onConnected, cast[pointer](result))
    if tickSource == 0: tickSource = g_timeout_add(1000, tick, nil)
