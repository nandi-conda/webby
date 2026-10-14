## A small HTTP/1.1 client on GIO's async sockets (TLS from glib-networking), for the sync blobs: one request per
## connection, the whole response handed to a callback on the GTK thread. Not std/httpclient (see
## summarize/deepseek.nim: Nim's OpenSSL would load before libwebby's). Also one-shot timers.

import std/[strutils, uri]

when defined(android):
  # No GIO: requests go through base.httpRequest (the Android shell's Java), timers through base.startTimer.
  import ../../base

  type
    Response* = object
      status*: int           ## 0 when the request failed; `error` says why
      reason*, body*, error*: string
      headers*: seq[(string, string)]   ## names in lower case

  proc header*(r: Response, name: string): string =
    for (k, v) in r.headers:
      if k == name.toLowerAscii: return v

  proc request*(meth, url: string, headers: openArray[(string, string)], body: string,
                onDone: proc (r: Response)) =
    var u: Uri
    try: u = parseUri(url)
    except CatchableError:
      onDone(Response(error: "Bad address: " & url))
      return
    if u.scheme notin ["http", "https"] or u.hostname.len == 0:
      onDone(Response(error: "Bad address: " & url))
      return
    if httpRequest == nil:
      onDone(Response(error: "No HTTP here"))
      return
    var hs = @[("User-Agent", "webby")]
    for h in headers: hs.add h
    httpRequest(meth, url, hs, body,
      proc (status: int, reason: string, headers: seq[(string, string)], body, error: string) =
        onDone(Response(status: status, reason: reason, headers: headers, body: body, error: error)))

  type Timer* = ref object
    id: int

  proc cancel*(t: Timer) =
    if t != nil and t.id != 0:
      stopTimer(t.id)
      t.id = 0

  proc after*(ms: int, action: proc ()): Timer =
    let t = Timer()
    t.id = startTimer(ms, proc () =
      t.id = 0
      action())
    t

else:
  import ../../browser

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

    Response* = object
      status*: int           ## 0 when the request failed; `error` says why
      reason*, body*, error*: string
      headers*: seq[(string, string)]   ## names in lower case

    Request = ref object
      host: string
      onDone: proc (r: Response)
      finished: bool
      client, conn, cancellable: pointer
      request: string
      readBuf: array[16384, char]
      raw: string
      timer: cuint
      extended: bool

  proc header*(r: Response, name: string): string =
    for (k, v) in r.headers:
      if k == name.toLowerAscii: return v

  proc errorText(e: pointer): string =
    if e == nil: return "unknown error"
    result = $cast[ptr GError](e).message
    g_error_free(e)

  proc finish(q: Request, r: Response) =
    if q.finished: return
    q.finished = true
    if q.timer != 0: discard g_source_remove(q.timer)
    g_cancellable_cancel(q.cancellable)
    if q.conn != nil: g_object_unref(q.conn)
    g_object_unref(q.client)
    g_object_unref(q.cancellable)
    q.conn = nil
    GC_unref(q)
    q.onDone(r)

  proc fail(q: Request, msg: string) = q.finish(Response(error: msg))

  proc parse(q: Request): (bool, Response) =
    ## The response once complete (by Content-Length, chunked end, or the connection closing).
    let e = q.raw.find("\r\n\r\n")
    if e < 0: return
    var r: Response
    let lines = q.raw[0 ..< e].split("\r\n")
    let parts = lines[0].split(' ', 2)
    r.status = if parts.len >= 2: (try: parseInt(parts[1]) except ValueError: 0) else: 0
    r.reason = if parts.len >= 3: parts[2] else: ""
    for h in lines[1 .. ^1]:
      let colon = h.find(':')
      if colon > 0: r.headers.add (h[0 ..< colon].strip.toLowerAscii, h[colon + 1 .. ^1].strip)
    let rest = q.raw[e + 4 .. ^1]
    if "chunked" in r.header("transfer-encoding").toLowerAscii:
      var i = 0
      while true:
        let nl = rest.find("\r\n", i)
        if nl < 0: return
        let size = try: parseHexInt(rest[i ..< nl].split(';')[0].strip) except ValueError: 0
        if size == 0: return (true, r)
        if rest.len < nl + 2 + size: return
        r.body.add rest[nl + 2 ..< nl + 2 + size]
        i = nl + 2 + size + 2
    let length = r.header("content-length")
    if length.len > 0:
      let n = try: parseInt(length) except ValueError: 0
      if rest.len < n: return
      r.body = rest[0 ..< n]
      return (true, r)
    if r.status == 204 or r.status == 304 or r.status div 100 == 1: return (true, r)
    r.body = rest
    (false, r)

  proc readMore(q: Request)

  proc onRead(source, res, data: pointer) {.cdecl.} =
    let q = cast[Request](data)
    defer: GC_unref(q)
    var err: pointer
    let n = g_input_stream_read_finish(source, res, addr err)
    if q.finished:
      if err != nil: g_error_free(err)
      return
    if n < 0:
      q.fail("Can't reach " & q.host & " (" & errorText(err) & ").")
      return
    if n == 0:
      # Closed: whatever came is the response.
      let e = q.raw.find("\r\n\r\n")
      if e < 0:
        q.fail("Can't reach " & q.host & " (the connection closed).")
        return
      let (_, r) = q.parse()
      q.finish(r)
      return
    var s = newString(n)
    copyMem(addr s[0], addr q.readBuf[0], n)
    q.raw.add s
    let (complete, r) = q.parse()
    if complete: q.finish(r) else: q.readMore()

  proc readMore(q: Request) =
    GC_ref(q)
    g_input_stream_read_async(g_io_stream_get_input_stream(q.conn), addr q.readBuf[0], q.readBuf.len.csize_t, 0,
      q.cancellable, onRead, cast[pointer](q))

  proc onWritten(source, res, data: pointer) {.cdecl.} =
    let q = cast[Request](data)
    defer: GC_unref(q)
    var err: pointer
    var written: csize_t
    let ok = g_output_stream_write_all_finish(source, res, addr written, addr err) != 0
    if q.finished:
      if err != nil: g_error_free(err)
      return
    if not ok:
      q.fail("Can't reach " & q.host & " (" & errorText(err) & ").")
      return
    q.readMore()

  proc onConnected(source, res, data: pointer) {.cdecl.} =
    let q = cast[Request](data)
    defer: GC_unref(q)
    var err: pointer
    let conn = g_socket_client_connect_to_host_finish(source, res, addr err)
    if q.finished:
      if conn != nil: g_object_unref(conn)
      if err != nil: g_error_free(err)
      return
    if conn == nil:
      q.fail("Can't reach " & q.host & " (" & errorText(err) & ").")
      return
    q.conn = conn
    GC_ref(q)
    g_output_stream_write_all_async(g_io_stream_get_output_stream(conn), addr q.request[0], q.request.len.csize_t, 0,
      q.cancellable, onWritten, cast[pointer](q))

  proc onTimeout(data: pointer): gboolean {.cdecl.} =
    let q = cast[Request](data)
    q.timer = 0
    if q.conn == nil: q.fail("Can't reach " & q.host & " (no answer in 15 seconds).")
    elif not q.extended:
      q.extended = true
      q.timer = g_timeout_add(30_000, onTimeout, data)
    else: q.fail(q.host & " took too long to answer.")
    0

  proc request*(meth, url: string, headers: openArray[(string, string)], body: string,
                onDone: proc (r: Response)) =
    ## Sends one request; `onDone` runs once, on the GTK thread. 15 s to connect, 45 s in all.
    var u: Uri
    try: u = parseUri(url)
    except CatchableError:
      onDone(Response(error: "Bad address: " & url))
      return
    let tls = u.scheme == "https"
    if not tls and u.scheme != "http" or u.hostname.len == 0:
      onDone(Response(error: "Bad address: " & url))
      return
    let port = if u.port.len > 0: u.port elif tls: "443" else: "80"
    let host = if ':' in u.hostname: "[" & u.hostname & "]" else: u.hostname
    var path = if u.path.len > 0: u.path else: "/"
    if u.query.len > 0: path.add "?" & u.query
    let q = Request(host: u.hostname, onDone: onDone, client: g_socket_client_new(), cancellable: g_cancellable_new())
    q.request = meth & " " & path & " HTTP/1.1\r\nHost: " & host & (if u.port.len > 0: ":" & u.port else: "") &
      "\r\nUser-Agent: webby\r\nConnection: close\r\n"
    for (k, v) in headers: q.request.add k & ": " & v & "\r\n"
    if body.len > 0 or meth in ["PUT", "POST"]:
      q.request.add "Content-Length: " & $body.len & "\r\n"
    q.request.add "\r\n" & body
    g_socket_client_set_tls(q.client, tls.gboolean)
    GC_ref(q)
    q.timer = g_timeout_add(15_000, onTimeout, cast[pointer](q))
    GC_ref(q)
    g_socket_client_connect_to_host_async(q.client, cstring(host & ":" & port), 0, q.cancellable, onConnected,
      cast[pointer](q))

  # ---------------------------------------------------------------------------------------------------------------
  # Timers

  type Timer* = ref object
    source: cuint
    action: proc ()

  proc fire(data: pointer): gboolean {.cdecl.} =
    let t = cast[Timer](data)
    t.source = 0
    let action = t.action
    GC_unref(t)
    action()
    0

  proc cancel*(t: Timer) =
    if t != nil and t.source != 0:
      discard g_source_remove(t.source)
      t.source = 0
      GC_unref(t)

  proc after*(ms: int, action: proc ()): Timer =
    ## Runs `action` once after `ms` on the GTK loop.
    result = Timer(action: action)
    GC_ref(result)
    result.source = g_timeout_add(ms.cuint, fire, cast[pointer](result))
