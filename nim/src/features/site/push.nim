## Web Push, which Ladybird can't do: it accepts serviceWorker.register() but never runs the worker, and has no
## PushManager. The page script (scripts/push.js) stands in for registrations and subscriptions; this module keeps
## them in the profile's push.json, gets each subscription an endpoint from the push service (push/autopush.nim:
## Mozilla's, over one WebSocket) with its own P-256 keys, and decrypts what arrives (push/ece.nim). The site's own
## worker script then handles the message: it runs in a hidden view of the script's URL, inside a stand-in worker
## scope (scripts/push_worker.js), where `self.registration.showNotification` reaches the desktop through
## features/site/notifications.nim and a click comes back as its notificationclick. No fetch handling, no offline.
##
## Several webby processes can share a profile (web app windows): the one holding push.lock keeps the connection;
## another connects only for as long as it takes to subscribe, and takes over when the holder quits.
## Desktop only: there's no WebSocket client on Android yet. Not in incognito windows (like Chrome's).

import std/[monotimes, os, posix, random, strutils, tables, times]
import ../../browser
import notifications, permissions
import push/[autopush, ece]

const
  pageScript = staticRead("../../scripts/push.js")
  workerScript = staticRead("../../scripts/push_worker.js")
  idleWorker = initDuration(seconds = 30)    ## a worker with nothing to do is closed after this
  eventTimeout = initDuration(seconds = 30)  ## an event whose waitUntil hasn't settled by then counts as done
  startTimeout = initDuration(seconds = 20)  ## the worker script must have run by then

type
  Registration = object
    origin, scope, script, kind: string   ## kind: "classic" or "module" (which we can't run)

  Subscription = object
    origin, scope, channel, endpoint, appKey: string
    priv, pub, auth: string               ## binary

  Worker = ref object
    reg: Registration
    view: View
    prefix: string
    stateSerial: uint64
    fetching, ready, failed: bool
    created, lastUsed: MonoTime
    queue: seq[(int, string)]             ## events (id, dispatch() call) waiting for the script to have run
    fallbacks: Table[int, proc ()]        ## what to do instead for queued events if it never runs
    busy: Table[int, MonoTime]            ## events in flight

var
  uaidSaved: string
  registrations: seq[Registration]
  subscriptions: seq[Subscription]
  workers: seq[Worker]
  owner = false                           ## this process holds push.lock
  lockFd: cint = -1
  nextEvent = 1
  nextNotification = 1
  shownNotifications: Table[int, uint32]  ## our notification id -> the system's
  broken: Table[string, MonoTime]         ## worker scripts that didn't run here, and when
  enabled = false
  debug = getEnv("WEBBY_PUSH_DEBUG") == "1"   ## log what pages and workers send

proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}

# ---------------------------------------------------------------------------------------------------------------
# The store: {"version": 1, "uaid": "...", "registrations": [...], "subscriptions": [...]}, keys in base64url.

proc storeFile(): string = profileFile("push.json")

proc loadStore() =
  ## Reads push.json again (another webby process may have changed it).
  registrations = @[]
  subscriptions = @[]
  let j = readJsonFile(storeFile())
  if j == nil or j.kind != JObject: return
  uaidSaved = j{"uaid"}.getStr
  for r in j{"registrations"}.getElems:
    let reg = Registration(origin: r{"origin"}.getStr, scope: r{"scope"}.getStr, script: r{"script"}.getStr,
      kind: r{"type"}.getStr("classic"))
    if reg.origin.len > 0 and reg.scope.len > 0 and reg.script.len > 0: registrations.add reg
  for s in j{"subscriptions"}.getElems:
    let sub = Subscription(origin: s{"origin"}.getStr, scope: s{"scope"}.getStr, channel: s{"channel"}.getStr,
      endpoint: s{"endpoint"}.getStr, appKey: s{"key"}.getStr, priv: unb64url(s{"priv"}.getStr),
      pub: unb64url(s{"pub"}.getStr), auth: unb64url(s{"auth"}.getStr))
    if sub.channel.len > 0 and sub.priv.len > 0: subscriptions.add sub

proc saveStore() =
  var regs = newJArray()
  for r in registrations: regs.add %*{"origin": r.origin, "scope": r.scope, "script": r.script, "type": r.kind}
  var subs = newJArray()
  for s in subscriptions:
    subs.add %*{"origin": s.origin, "scope": s.scope, "channel": s.channel, "endpoint": s.endpoint, "key": s.appKey,
      "priv": b64url(s.priv), "pub": b64url(s.pub), "auth": b64url(s.auth)}
  try: writeJsonFile(storeFile(), %*{"version": 1, "uaid": uaidSaved, "registrations": regs, "subscriptions": subs},
    pretty = true)
  except CatchableError as e: logPush "could not save " & storeFile() & ": " & e.msg

proc findReg(scope: string): int =
  for i, r in registrations:
    if r.scope == scope: return i
  -1

proc findSub(scope: string): int =
  for i, s in subscriptions:
    if s.scope == scope: return i
  -1

proc subJson(s: Subscription): JsonNode =
  %*{"endpoint": s.endpoint, "p256dh": b64url(s.pub), "auth": b64url(s.auth), "key": s.appKey}

proc uuid(): string =
  const hex = "0123456789abcdef"
  for i in 0 ..< 32:
    if i in [8, 12, 16, 20]: result.add '-'
    result.add (if i == 12: '4' elif i == 16: hex[8 + rand(3)] else: hex[rand(15)])

# ---------------------------------------------------------------------------------------------------------------
# Pages

proc pageState(t: Tab, origin: string): string =
  case permissionFor(t, origin, "notifications")
  of allow: "granted"
  of blocked: "denied"
  of ask: "default"

proc script(t: Tab): string =
  if not enabled: return ""
  let origin = secureOrigin(t.url)
  if origin.len == 0: return ""
  var regs = newJArray()
  var subs = newJObject()
  for r in registrations:
    if r.origin == origin: regs.add %*{"scope": r.scope, "scriptURL": r.script}
  for s in subscriptions:
    if s.origin == origin: subs[s.scope] = subJson(s)
  let state = %*{"permission": pageState(t, origin), "registrations": regs, "subscriptions": subs}
  pageScript.replace("${jsonEncode(prefix)}", $(%t.messagePrefix)).replace("${jsonEncode(state)}", $state)

proc refreshPages() =
  for t in tabs:
    let js = script(t)
    if js.len > 0: t.runJs(js)

proc settle(t: Tab, id: int, ok: bool, value: JsonNode) =
  if not t.closed: t.runJs("window.__webbyPush && window.__webbyPush.settle(" & $id & ", " & $ok & ", " & $value & ")")

proc fail(name, message: string): JsonNode = %*{"name": name, "message": message}

proc allowedFor(origin: string): bool =
  ## Whether `origin` may show notifications (remembered, or allowed this time in one of its tabs).
  if get(origin, "notifications") == allow: return true
  for t in tabs:
    if secureOrigin(t.url) == origin and permissionFor(t, origin, "notifications") == allow: return true

# ---------------------------------------------------------------------------------------------------------------
# Clients: the tabs a worker sees (every open page in its scope counts as controlled by it).

proc clientId(t: Tab): string =
  result = t.props.getOrDefault("push.client")
  if result.len == 0:
    result = uuid()
    t.props["push.client"] = result

proc clientInfo(t: Tab, url = ""): JsonNode =
  %*{"id": clientId(t), "url": (if url.len > 0: url else: t.url), "focused": t == currentTab(),
     "visibilityState": (if t == currentTab(): "visible" else: "hidden")}

proc clientsOf(reg: Registration): seq[Tab] =
  for t in tabs:
    if not t.closed and t.view != nil and t.url.startsWith(reg.scope): result.add t

proc clientTab(reg: Registration, id: string): Tab =
  for t in clientsOf(reg):
    if t.props.getOrDefault("push.client") == id: return t

proc present() =
  when not defined(android): gtk_window_present(window)

# ---------------------------------------------------------------------------------------------------------------
# Workers

proc runJs(w: Worker, js: string) =
  if w.view != nil:
    webby_view_run_javascript(w.view, js.cstring)
    wake()

proc closeWorker(w: Worker) =
  let i = workers.find(w)
  if i >= 0: workers.delete i
  if w.view != nil:
    webby_view_destroy(w.view)
    w.view = nil

proc failWorker(w: Worker, why: string) =
  ## The script can't run here: queued events get their fallbacks.
  if w.failed: return
  logPush w.reg.script & ": the worker script didn't run (" & why & ")"
  w.failed = true
  broken[w.reg.script] = getMonoTime()
  w.queue = @[]
  let fallbacks = w.fallbacks
  w.fallbacks.clear()
  for _, f in fallbacks: f()
  closeWorker(w)

proc startWorker(reg: Registration): Worker =
  for w in workers:
    if w.reg.scope == reg.scope and w.reg.script == reg.script: return w
  result = Worker(reg: reg, created: getMonoTime(), lastUsed: getMonoTime())
  result.prefix = "webby-sw-" & uuid() & ":"
  result.view = webby_view_create(400, 300, 1.0)
  webby_view_set_message_prefix(result.view, result.prefix.cstring)
  webby_view_set_visible(result.view, 0)
  # The script's own URL: the right origin and location, and no page of the site's running alongside.
  webby_view_load(result.view, reg.script.cstring)
  workers.add result
  logPush "starting the worker " & reg.script
  wake()

proc dispatch(reg: Registration, kind: string, payload: JsonNode, fallback: proc () = nil) =
  ## Fires an event in the registration's worker (starting it), or runs `fallback` if its script can't run here.
  if reg.kind == "module" or (reg.script in broken and getMonoTime() - broken[reg.script] < initDuration(minutes = 10)):
    if fallback != nil: fallback()
    return
  let w = startWorker(reg)
  let id = nextEvent
  inc nextEvent
  w.lastUsed = getMonoTime()
  let js = "window.__webbySW && window.__webbySW.dispatch(" & $(%kind) & ", " & $id & ", " & $payload & ")"
  if w.ready:
    w.busy[id] = getMonoTime()
    w.runJs(js)
  else:
    w.queue.add (id, js)
    if fallback != nil: w.fallbacks[id] = fallback

proc showWorkerNotification(reg: Registration, title: string, options: JsonNode): int =
  ## Shows a notification of `reg`'s; clicks and dismissals go to its worker. The id the worker knows it by.
  let nid = nextNotification
  inc nextNotification
  let payload = %*{"nid": nid, "title": title, "options": options}
  notify(reg.origin, options{"tag"}.getStr, title, options{"body"}.getStr,
    onClick = proc () =
      shownNotifications.del nid
      dispatch(reg, "notificationclick", payload, proc () =
        let tabsHere = clientsOf(reg)
        if tabsHere.len > 0: activateTab(tabsHere[0]) else: discard openTab(reg.scope)
        present()),
    onClosed = proc () =
      shownNotifications.del nid
      dispatch(reg, "notificationclose", payload),
    done = proc (id: uint32) = shownNotifications[nid] = id)
  nid

proc fallbackNotification(reg: Registration, clear: string) =
  ## What a push shows when the site's worker can't run: the payload's title and body if it has them.
  var title = siteName(reg.origin)
  var body = ""
  try:
    let j = parseJson(clear)
    let n = if j{"notification"} != nil and j{"notification"}.kind == JObject: j{"notification"} else: j
    if n{"title"}.getStr.len > 0: title = n{"title"}.getStr
    body = n{"body"}.getStr
  except CatchableError:
    body = clear
  if body.len > 300: body = body[0 ..< 300] & "…"
  if allowedFor(reg.origin): discard showWorkerNotification(reg, title, %*{"body": body})

proc reply(w: Worker, id: int, ok: bool, value: JsonNode) =
  w.runJs("window.__webbySW && window.__webbySW.settle(" & $id & ", " & $ok & ", " & $value & ")")

proc subscribe(reg: Registration, key: string, done: proc (ok: bool, value: JsonNode))

proc unsubscribe(scope: string): bool =
  loadStore()
  let i = findSub(scope)
  if i < 0: return false
  autopush.unregister(subscriptions[i].channel)
  subscriptions.delete i
  saveStore()
  if subscriptions.len == 0: autopush.stop()
  refreshPages()
  true

proc onWorkerMessage(w: Worker, m: JsonNode) =
  if debug: logPush "worker -> " & ($m)[0 ..< min(($m).len, 300)]
  let id = m{"id"}.getInt
  let reg = w.reg
  w.lastUsed = getMonoTime()
  case m{"op"}.getStr
  of "source":
    w.fetching = false
    if not m{"ok"}.getBool:
      failWorker(w, "couldn't fetch it")
      return
    let prelude = workerScript.replace("${jsonEncode(prefix)}", $(%w.prefix))
      .replace("${jsonEncode(scope)}", $(%reg.scope)).replace("${jsonEncode(script)}", $(%reg.script))
    w.runJs(prelude)
    w.runJs("try {\nwith (window.__webbySW.scope) {\nwindow.__webbySW.run = (source) => eval(source);\n" &
      m{"text"}.getStr & "\n}\nwindow.__webbySW.started();\n} catch (e) { window.__webbySW.failed(e); }")
  of "started":
    logPush "worker running: " & reg.script
    w.ready = true
    w.fallbacks.clear()
    let queued = w.queue
    w.queue = @[]
    for (id, js) in queued:
      w.busy[id] = getMonoTime()
      w.runJs(js)
  of "failed": failWorker(w, m{"error"}.getStr)
  of "done":
    w.busy.del m{"event"}.getInt
  of "showNotification":
    if not allowedFor(reg.origin):
      w.reply(id, false, fail("TypeError", "No notification permission has been granted for this origin."))
    else:
      w.reply(id, true, %showWorkerNotification(reg, m{"title"}.getStr, m{"options"}))
  of "closeNotification":
    let nid = m{"nid"}.getInt
    if nid in shownNotifications:
      closeNotification(shownNotifications[nid])
      shownNotifications.del nid
  of "matchAll":
    var list = newJArray()
    for t in clientsOf(reg): list.add clientInfo(t)
    w.reply(id, true, list)
  of "focus":
    let t = clientTab(reg, m{"client"}.getStr)
    if t == nil:
      w.reply(id, false, fail("InvalidAccessError", "The client is gone."))
    else:
      activateTab(t)
      present()
      w.reply(id, true, clientInfo(t))
  of "navigate":
    let t = clientTab(reg, m{"client"}.getStr)
    if t == nil: w.reply(id, true, newJNull())
    else:
      t.loadUrl(m{"url"}.getStr)
      w.reply(id, true, clientInfo(t, m{"url"}.getStr))
  of "openWindow":
    let url = m{"url"}.getStr
    let t = openTab(url)
    present()
    w.reply(id, true, if originOf(url) == reg.origin: clientInfo(t, url) else: newJNull())
  of "clientPostMessage":
    let t = clientTab(reg, m{"client"}.getStr)
    if t != nil:
      let data = try: parseJson(m{"data"}.getStr) except CatchableError: newJNull()
      t.runJs("window.__webbyPush && window.__webbyPush.message(" & $(%reg.scope) & ", " & $data & ")")
  of "subscribe":
    if not allowedFor(reg.origin):
      w.reply(id, false, fail("NotAllowedError", "Registration failed - permission denied"))
    else:
      subscribe(reg, m{"key"}.getStr, proc (ok: bool, value: JsonNode) = w.reply(id, ok, value))
  of "getSubscription":
    loadStore()
    let i = findSub(reg.scope)
    w.reply(id, true, if i >= 0: subJson(subscriptions[i]) else: newJNull())
  of "unsubscribe": w.reply(id, true, %unsubscribe(reg.scope))
  of "permission":
    w.reply(id, true, %(if allowedFor(reg.origin): "granted" elif get(reg.origin, "notifications") == blocked: "denied"
                        else: "prompt"))
  of "unregister": w.reply(id, true, %false)   # leave that to the page
  else: discard

const sourceScript = """
(async () => {
  const prompt = window.prompt;
  const send = (m) => { const text = $1 + JSON.stringify(m); setTimeout(() => { try { prompt.call(window, text); } catch (e) {} }, 0); };
  try {
    const r = await fetch($2, { cache: 'no-cache', credentials: 'same-origin' });
    if (!r.ok) throw 0;
    send({ type: 'sw', op: 'source', ok: true, text: await r.text() });
  } catch (e) {
    send({ type: 'sw', op: 'source', ok: false });
  }
})();
"""

proc pumpWorkers() =
  let now = getMonoTime()
  for w in workers[0 .. ^1]:
    if w.view == nil: continue
    let ss = webby_view_state_serial(w.view)
    if ss != w.stateSerial:
      w.stateSerial = ss
      let url = str(webby_view_url(w.view))
      if not w.ready and not w.fetching and webby_view_is_loading(w.view) == 0 and url == w.reg.script:
        w.fetching = true
        w.runJs(sourceScript % [$(%w.prefix), $(%w.reg.script)])
    while true:
      let v = webby_view_take_new_view(w.view)   # window.open from a worker: not a thing
      if v == nil: break
      webby_view_destroy(v)
    while w.view != nil:
      let m = str(webby_view_next_message(w.view))
      if m.len == 0: break
      let j = try: parseJson(m) except CatchableError: continue
      if j{"type"}.getStr == "sw": onWorkerMessage(w, j)
    if w.view == nil: continue
    for k, since in w.busy:
      if now - since > eventTimeout:
        w.busy.del k
        break
    if not w.ready and now - w.created > startTimeout: failWorker(w, "it took too long")
    elif w.busy.len == 0 and w.queue.len == 0 and now - w.lastUsed > idleWorker:
      logPush "closing the idle worker " & w.reg.script
      closeWorker(w)

# ---------------------------------------------------------------------------------------------------------------
# Subscriptions and messages

proc tryLock(): bool =
  if owner: return true
  if lockFd < 0:
    createDir(profileDir())
    lockFd = posix.open(cstring(profileFile("push.lock")), O_RDWR or O_CREAT, 0o600)
    if lockFd < 0: return false
  owner = flock(lockFd, 2 or 4) == 0   # LOCK_EX | LOCK_NB
  owner

proc subscribe(reg: Registration, key: string, done: proc (ok: bool, value: JsonNode)) =
  loadStore()
  let i = findSub(reg.scope)
  if i >= 0:
    if subscriptions[i].appKey == key: done(true, subJson(subscriptions[i]))
    else: done(false, fail("InvalidStateError",
      "A subscription with a different applicationServerKey already exists; unsubscribe first."))
    return
  let channel = uuid()
  let keys = try: newKeyPair() except CatchableError as e:
    done(false, fail("AbortError", "Couldn't make the subscription's keys: " & e.msg))
    return
  let auth = randomBytes(16)
  if uaidSaved.len > 0: autopush.uaid = uaidSaved
  autopush.register(channel, key, proc (endpoint, error: string) =
    if error.len > 0:
      logPush "subscribing " & reg.scope & " failed: " & error
      done(false, fail("AbortError", "Registration failed - " & error))
    else:
      loadStore()
      subscriptions.add Subscription(origin: reg.origin, scope: reg.scope, channel: channel, endpoint: endpoint,
        appKey: key, priv: keys.priv, pub: keys.pub, auth: auth)
      saveStore()
      logPush "subscribed " & reg.scope & " at " & endpoint
      done(true, subJson(subscriptions[^1]))
      refreshPages()
    if not owner: autopush.stop())

proc helloFromService(id: string) =
  loadStore()
  if uaidSaved.len > 0 and id != uaidSaved and subscriptions.len > 0:
    # The service forgot us: every endpoint is dead. Workers hear it as pushsubscriptionchange and can subscribe again.
    logPush "the push service gave us a new id: " & $subscriptions.len & " subscriptions are gone"
    let lost = subscriptions
    subscriptions = @[]
    uaidSaved = id
    saveStore()
    for s in lost:
      let r = findReg(s.scope)
      if r >= 0: dispatch(registrations[r], "pushsubscriptionchange", %*{"old": subJson(s)})
    refreshPages()
  elif id != uaidSaved:
    uaidSaved = id
    saveStore()

proc messageFromService(channel, data: string, headers: JsonNode): int =
  var i = -1
  for k, s in subscriptions:
    if s.channel == channel: i = k
  if i < 0:
    loadStore()
    for k, s in subscriptions:
      if s.channel == channel: i = k
  if i < 0:
    logPush "a message for a channel we don't have; dropping it"
    autopush.unregister(channel)
    return 102
  let sub = subscriptions[i]
  let r = findReg(sub.scope)
  if r < 0: return 102
  var clear = ""
  if data.len > 0:
    let encoding = if headers != nil: headers{"encoding"}.getStr else: ""
    if encoding != "aes128gcm":
      logPush sub.origin & " sent a message in the " & encoding & " encoding, which we don't decrypt"
      return 101
    try: clear = decrypt(sub.priv, sub.pub, sub.auth, data)
    except CatchableError as e:
      logPush sub.origin & ": " & e.msg
      return 101
  logPush "message for " & sub.scope & " (" & $clear.len & " bytes)"
  let reg = registrations[r]
  dispatch(reg, "push", %*{"data": (if data.len > 0: %b64url(clear) else: newJNull())},
    proc () = fallbackNotification(reg, clear))
  100

proc onPageMessage(t: Tab, text: string): bool =
  if not text.startsWith("{\"type\":\"push\""): return false
  let m = try: parseJson(text) except CatchableError: return true
  let origin = secureOrigin(t.url)
  if debug: logPush "page -> " & text[0 ..< min(text.len, 300)]
  if origin.len == 0 or not enabled: return true
  let id = m{"id"}.getInt
  let scope = m{"scope"}.getStr
  if scope.len > 0 and originOf(scope) != origin: return true
  case m{"op"}.getStr
  of "register":
    let scriptUrl = m{"scriptURL"}.getStr
    if originOf(scriptUrl) != origin:
      t.settle(id, false, fail("SecurityError", "The script's origin doesn't match the page's."))
      return true
    loadStore()
    let reg = Registration(origin: origin, scope: scope, script: scriptUrl, kind: m{"kind"}.getStr("classic"))
    let i = findReg(scope)
    if i < 0 or registrations[i] != reg:
      if i >= 0: registrations[i] = reg else: registrations.add reg
      saveStore()
      logPush "registered " & scriptUrl & " for " & scope
    t.settle(id, true, %true)
  of "unregister":
    loadStore()
    let i = findReg(scope)
    if i >= 0:
      for w in workers[0 .. ^1]:
        if w.reg.scope == scope: closeWorker(w)
      discard unsubscribe(scope)
      loadStore()
      let j = findReg(scope)
      if j >= 0: registrations.delete j
      saveStore()
      refreshPages()
    t.settle(id, true, %(i >= 0))
  of "subscribe":
    let i = findReg(scope)
    if i < 0:
      t.settle(id, false, fail("InvalidStateError", "Subscription failed - no active Service Worker"))
      return true
    let reg = registrations[i]
    askPermission(t, origin, "notifications", proc (allowed: bool) =
      if t.closed: return
      if not allowed: t.settle(id, false, fail("NotAllowedError", "Registration failed - permission denied"))
      else: subscribe(reg, m{"key"}.getStr, proc (ok: bool, value: JsonNode) = t.settle(id, ok, value)))
  of "unsubscribe": t.settle(id, true, %unsubscribe(scope))
  of "showNotification":
    let i = findReg(scope)
    if i < 0 or not allowedFor(origin):
      t.settle(id, false, fail("TypeError", "No notification permission has been granted for this origin."))
    else: t.settle(id, true, %showWorkerNotification(registrations[i], m{"title"}.getStr, m{"options"}))
  of "postMessage":
    # Only to a worker that's running: starting a hidden view for every message isn't worth it.
    for w in workers:
      if w.reg.scope == scope:
        let data = try: parseJson(m{"data"}.getStr) except CatchableError: newJNull()
        dispatch(w.reg, "message", %*{"data": data, "source": clientInfo(t)})
        break
  else: discard
  true

proc install*() =
  when not defined(android):
    autopush.wanted = proc (): bool = owner and subscriptions.len > 0
    autopush.channels = proc (): seq[string] =
      for s in subscriptions: result.add s.channel
    autopush.onHello = helloFromService
    autopush.onNotification = messageFromService
    pageScriptHooks.add script
    pageMessageHooks.add onPageMessage
    pumpHooks.add proc () = (if workers.len > 0: pumpWorkers())
    storeListeners.add refreshPages
    windowHooks.add proc () =
      if incognito: return
      enabled = true
      loadStore()
      autopush.uaid = uaidSaved
      if tryLock(): discard after(2_000, autopush.connect)
      else:
        logPush "another webby has the push connection"
        discard every(60_000, proc () =
          if not owner and tryLock():
            loadStore()
            autopush.uaid = uaidSaved
            autopush.connect())
    shutdownHooks.add proc () =
      for w in workers[0 .. ^1]: closeWorker(w)
