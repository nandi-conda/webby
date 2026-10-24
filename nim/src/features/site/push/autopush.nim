## The connection to the push service: Mozilla's autopush, the one Firefox uses (no account or key needed). One
## WebSocket (RFC 6455, a small client on GIO's async sockets like summarize/deepseek.nim, so everything runs on the
## GTK main loop) speaks its JSON protocol: "hello" with our user agent id, "register" for each subscription (the
## answer is the endpoint sites send to), "notification" for each message, which we "ack". The service keeps
## messages while we're away and sends them when we're back. WEBBY_PUSH_SERVER overrides the server (tests: ws://).
## https://mozilla-services.github.io/autopush-rs/

import std/[base64, json, monotimes, os, random, strutils, tables, times, uri]
import ../../../browser

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

  Registered* = proc (endpoint, error: string)   ## error = "" when it worked

const
  pingEvery = initDuration(minutes = 5)     ## an idle connection sends "{}" this often, so NATs keep it
  pingAnswer = initDuration(seconds = 30)   ## no reply by then and the connection is dead
  registerTimeout = initDuration(seconds = 20)

var
  # Set by push.nim
  uaid*: string                              ## our id at the service ("" before the first hello)
  wanted*: proc (): bool                     ## whether to stay connected (there are subscriptions)
  channels*: proc (): seq[string]            ## the channels we have, sent with hello
  onHello*: proc (uaid: string)              ## the service's id for us (a new one means our channels are gone)
  onNotification*: proc (channel: string, data: string, headers: JsonNode): int  ## the ack code (100 = delivered)
  onConnectionChange*: proc ()               ## connected or not, for logs

  gen = 0                                     ## which connection the GIO callbacks belong to
  client, conn, cancellable: pointer
  connecting, upgraded, helloDone: bool
  readBuf: array[16384, char]
  raw: string                                 ## bytes not parsed yet
  message: string                             ## a fragmented message's text so far
  outbox, writing: string
  waitingForHello: seq[string]                ## messages to send once hello is answered
  pending: Table[string, tuple[done: Registered, since: MonoTime]]   ## channel -> its register's caller
  backoff = 5_000
  reconnectTimer, tickTimer: Timer
  lastHeard, lastSent, pingSent: MonoTime

proc errorText(e: pointer): string =
  if e == nil: return "unknown error"
  result = $cast[ptr GError](e).message
  g_error_free(e)

proc logPush*(text: string) = stderr.writeLine "webby: push: ", text

proc connected*(): bool = helloDone

proc connect*()

proc scheduleReconnect() =
  cancel(reconnectTimer)
  if wanted == nil or not wanted(): return
  logPush "reconnecting in " & $(backoff div 1000) & " s"
  reconnectTimer = after(backoff, connect)
  backoff = min(backoff * 2, 300_000)

proc disconnect(reason: string, retry = true) =
  if conn == nil and not connecting: return
  logPush "disconnected: " & reason
  inc gen
  g_cancellable_cancel(cancellable)
  if conn != nil: g_object_unref(conn)
  g_object_unref(client)
  g_object_unref(cancellable)
  conn = nil
  client = nil
  cancellable = nil
  connecting = false
  upgraded = false
  helloDone = false
  raw = ""
  message = ""
  outbox = ""
  writing = ""
  waitingForHello = @[]
  let failed = pending
  pending.clear()
  for _, p in failed: p.done("", "the push service connection closed (" & reason & ")")
  if onConnectionChange != nil: onConnectionChange()
  if retry: scheduleReconnect()

proc stop*() =
  ## Closes the connection (nothing wants it any more).
  cancel(reconnectTimer)
  disconnect("not needed", retry = false)

# ---------------------------------------------------------------------------------------------------------------
# Writing: one write in flight at a time; what comes meanwhile waits in `outbox`.

proc flush()

proc onWritten(source, res, data: pointer) {.cdecl.} =
  var err: pointer
  var written: csize_t
  let ok = g_output_stream_write_all_finish(source, res, addr written, addr err) != 0
  if cast[int](data) != gen:
    if err != nil: g_error_free(err)
    return
  writing = ""
  if not ok:
    disconnect(errorText(err))
    return
  flush()

proc flush() =
  if conn == nil or writing.len > 0 or outbox.len == 0: return
  writing = move outbox
  outbox = ""
  g_output_stream_write_all_async(g_io_stream_get_output_stream(conn), addr writing[0], writing.len.csize_t, 0,
    cancellable, onWritten, cast[pointer](gen))

proc sendFrame(opcode: int, payload: string) =
  ## A client frame: always masked (RFC 6455 section 5.3).
  var f = newStringOfCap(payload.len + 14)
  f.add chr(0x80 or opcode)
  let n = payload.len
  if n < 126: f.add chr(0x80 or n)
  elif n < 65536:
    f.add chr(0x80 or 126)
    f.add chr(n shr 8)
    f.add chr(n and 0xff)
  else:
    f.add chr(0x80 or 127)
    for i in countdown(7, 0): f.add chr((n shr (8 * i)) and 0xff)
  var mask: array[4, int]
  for i in 0 ..< 4:
    mask[i] = rand(255)
    f.add chr(mask[i])
  for i, c in payload: f.add chr(ord(c) xor mask[i and 3])
  outbox.add f
  lastSent = getMonoTime()
  flush()

proc send(j: JsonNode) =
  if helloDone: sendFrame(1, $j) else: waitingForHello.add $j

# ---------------------------------------------------------------------------------------------------------------
# The protocol

proc handle(text: string) =
  if getEnv("WEBBY_PUSH_DEBUG") == "1": logPush "<- " & text
  let m = try: parseJson(text) except CatchableError: return
  if m.kind != JObject: return    # "{}": the answer to our ping
  case m{"messageType"}.getStr
  of "hello":
    if m{"status"}.getInt != 200:
      disconnect("hello refused (" & $m{"status"}.getInt & ")")
      return
    helloDone = true
    backoff = 5_000
    let id = m{"uaid"}.getStr
    logPush "connected" & (if id != uaid: " (new id)" else: "")
    if onHello != nil: onHello(id)
    uaid = id
    for s in waitingForHello: sendFrame(1, s)
    waitingForHello = @[]
    if onConnectionChange != nil: onConnectionChange()
  of "register":
    let ch = m{"channelID"}.getStr
    if ch notin pending: return
    let p = pending[ch]
    pending.del ch
    if m{"status"}.getInt == 200 and m{"pushEndpoint"}.getStr.len > 0: p.done(m{"pushEndpoint"}.getStr, "")
    else: p.done("", "the push service refused the subscription (" & $m{"status"}.getInt & ")")
  of "notification":
    let ch = m{"channelID"}.getStr
    var data = ""
    if m{"data"}.getStr.len > 0:
      var t = m{"data"}.getStr.multiReplace(("-", "+"), ("_", "/"))
      while t.len mod 4 != 0: t.add '='
      data = try: base64.decode(t) except ValueError: ""
    let code = if onNotification != nil: onNotification(ch, data, m{"headers"}) else: 100
    send(%*{"messageType": "ack", "updates": [{"channelID": ch, "version": m{"version"}.getStr, "code": code}]})
  of "ping": send(%*{"messageType": "ping"})
  else: discard

proc readFrames() =
  while true:
    if raw.len < 2: return
    let b0 = ord(raw[0])
    let b1 = ord(raw[1])
    var n = b1 and 0x7f
    var head = 2
    if n == 126:
      if raw.len < 4: return
      n = (ord(raw[2]) shl 8) or ord(raw[3])
      head = 4
    elif n == 127:
      if raw.len < 10: return
      n = 0
      for i in 2 ..< 10: n = (n shl 8) or ord(raw[i])
      head = 10
    let masked = (b1 and 0x80) != 0
    if masked: head += 4
    if raw.len < head + n: return
    var payload = raw[head ..< head + n]
    if masked:
      for i in 0 ..< payload.len: payload[i] = chr(ord(payload[i]) xor ord(raw[head - 4 + (i and 3)]))
    raw = raw[head + n .. ^1]
    let fin = (b0 and 0x80) != 0
    case b0 and 0x0f
    of 0, 1:
      message.add payload
      if fin:
        let text = move message
        message = ""
        handle(text)
        if conn == nil: return
    of 8:
      disconnect("closed by the service")
      return
    of 9: sendFrame(10, payload)
    else: discard

proc readMore()

proc onRead(source, res, data: pointer) {.cdecl.} =
  var err: pointer
  let n = g_input_stream_read_finish(source, res, addr err)
  if cast[int](data) != gen:
    if err != nil: g_error_free(err)
    return
  if n <= 0:
    disconnect(if n < 0: errorText(err) else: "closed")
    return
  lastHeard = getMonoTime()
  pingSent = MonoTime()
  var s = newString(n)
  copyMem(addr s[0], addr readBuf[0], n)
  raw.add s
  try:
    if not upgraded:
      let e = raw.find("\r\n\r\n")
      if e >= 0:
        let status = raw[0 ..< e].split("\r\n")[0]
        raw = raw[e + 4 .. ^1]
        if " 101 " notin status & " ":
          disconnect("no WebSocket (" & status & ")")
          return
        upgraded = true
        var hello = %*{"messageType": "hello", "use_webpush": true, "uaid": uaid}
        if channels != nil: hello["channelIDs"] = %channels()
        sendFrame(1, $hello)
    if upgraded: readFrames()
  except CatchableError as e:
    disconnect(e.msg)
    return
  if conn != nil and cast[int](data) == gen: readMore()

proc readMore() =
  g_input_stream_read_async(g_io_stream_get_input_stream(conn), addr readBuf[0], readBuf.len.csize_t, 0,
    cancellable, onRead, cast[pointer](gen))

proc onConnected(source, res, data: pointer) {.cdecl.} =
  var err: pointer
  let c = g_socket_client_connect_to_host_finish(source, res, addr err)
  if cast[int](data) != gen:
    if c != nil: g_object_unref(c)
    if err != nil: g_error_free(err)
    return
  if c == nil:
    disconnect(errorText(err))
    return
  conn = c
  connecting = false
  let u = parseUri(getEnv("WEBBY_PUSH_SERVER", "wss://push.services.mozilla.com/"))
  var key = newString(16)
  for i in 0 ..< 16: key[i] = chr(rand(255))
  let path = (if u.path.len > 0: u.path else: "/") & (if u.query.len > 0: "?" & u.query else: "")
  outbox.add "GET " & path & " HTTP/1.1\r\nHost: " & u.hostname & "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & base64.encode(key) & "\r\nSec-WebSocket-Version: 13\r\n" &
    "Sec-WebSocket-Protocol: push-notification\r\nUser-Agent: webby\r\n\r\n"
  lastHeard = getMonoTime()
  flush()
  readMore()

proc tick() =
  let now = getMonoTime()
  for ch, p in pending:
    if now - p.since > registerTimeout:
      pending.del ch
      p.done("", "the push service didn't answer")
      break
  if conn == nil: return
  if not helloDone:
    if now - lastHeard > pingAnswer: disconnect("no answer")
  elif pingSent != MonoTime():
    if now - pingSent > pingAnswer: disconnect("no answer to ping")
  elif now - max(lastHeard, lastSent) > pingEvery:
    pingSent = now
    sendFrame(1, "{}")

proc connect*() =
  ## Connects unless connected (or nothing wants it); reconnects on its own after a failure.
  if conn != nil or connecting: return
  if wanted != nil and not wanted() and pending.len == 0: return
  cancel(reconnectTimer)
  if tickTimer == nil: tickTimer = every(5_000, tick)
  let u = parseUri(getEnv("WEBBY_PUSH_SERVER", "wss://push.services.mozilla.com/"))
  let tls = u.scheme == "wss"
  let port = if u.port.len > 0: u.port else: (if tls: "443" else: "80")
  inc gen
  connecting = true
  client = g_socket_client_new()
  g_socket_client_set_tls(client, tls.gboolean)
  cancellable = g_cancellable_new()
  g_socket_client_connect_to_host_async(client, cstring(u.hostname & ":" & port), 443, cancellable, onConnected,
    cast[pointer](gen))

proc register*(channel, appServerKey: string, done: Registered) =
  ## Asks for an endpoint for `channel`; `appServerKey` (base64url, may be "") limits it to that site's VAPID key.
  pending[channel] = (done, getMonoTime())
  var m = %*{"messageType": "register", "channelID": channel}
  if appServerKey.len > 0: m["key"] = %appServerKey
  send(m)
  connect()

proc unregister*(channel: string) =
  if conn == nil and not connecting: return    # the next hello's channel list leaves it out anyway
  send(%*{"messageType": "unregister", "channelID": channel, "code": 200})
