## Where the encrypted blobs live and one round of sync (sync_store.dart and sync_engine.dart): one blob per kind
## behind GET/PUT with ETags, on the webby-sync server (sync-server/) or in a WebDAV folder.
##
## Settings are SyncSettings.toJson() as the Dart app keeps them inside the vault: {code, backend: "webby-sync" |
## "webdav", server, username?, password?, etag?, lastSync?, lastError?}.

import std/[base64, json, strutils, times, uri]
import doc, keys, http

const defaultSyncServer* = "https://webby-sync.nandithebull.workers.dev"
const retiredSyncServers = ["https://webby-sync.fly.dev", "https://webby-sync.fly.dev/"]
  ## Earlier defaults, still saved in older settings and pairing links; they mean the default server now.

type
  SyncBlob* = enum blobVault, blobBookmarks, blobTabs, blobSummaries, blobSessions, blobSecrets

  BlobStore = object
    url, auth: string
    webdav: bool

  Outcome* = object
    doc*: JsonNode       ## the merged state the server now holds; nil on failure
    etag*, error*: string

proc nowSeconds*(): int64 = getTime().toUnix

# ---------------------------------------------------------------------------------------------------------------
# Settings

proc newSettings*(code: string, webdav = false, server = defaultSyncServer, username = "", password = ""): JsonNode =
  result = %*{"code": code, "backend": (if webdav: "webdav" else: "webby-sync"), "server": server}
  if username.len > 0: result["username"] = %username
  if password.len > 0: result["password"] = %password

proc code*(s: JsonNode): string = s{"code"}.getStr
proc isWebdav*(s: JsonNode): bool = s{"backend"}.getStr == "webdav"
proc server*(s: JsonNode): string =
  let v = s{"server"}
  if v == nil or v.kind != JString or v.getStr in retiredSyncServers: defaultSyncServer else: v.getStr

proc pairingLink*(s: JsonNode): string =
  ## What another device needs to join: the code, plus where to sync when it isn't the default.
  var query = @[("code", s.code)]
  if s.isWebdav: query.add ("webdav", s.server)
  elif s.server != defaultSyncServer: query.add ("server", s.server)
  "webby-sync:pair?" & encodeQuery(query)

proc fromPairing*(text: string): JsonNode =
  ## Settings from a pairing link or a bare code. Raises BadSyncCode.
  let t = text.strip
  if t.startsWith("webby-sync:"):
    var code, webdav, server: string
    var hasWebdav = false
    let q = t.find('?')
    if q >= 0:
      for (k, v) in decodeQuery(t[q + 1 .. ^1]):
        case k
        of "code": code = v
        of "webdav": (webdav = v; hasWebdav = true)
        of "server": server = v
        else: discard
    discard keyFromCode(code)
    if hasWebdav: return newSettings(code, webdav = true, server = webdav)
    return newSettings(code, server = if server.len > 0 and server notin retiredSyncServers: server else: defaultSyncServer)
  newSettings(normalizeCode(t))

# ---------------------------------------------------------------------------------------------------------------
# Blobs

proc store(s: JsonNode, k: SyncKeys, blob: SyncBlob): BlobStore =
  var base = s.server
  if base.endsWith("/"): base.setLen(base.len - 1)
  let id = case blob
    of blobVault: k.blobId
    of blobBookmarks: k.bookmarksBlobId
    of blobTabs: k.tabsBlobId
    of blobSummaries: k.summariesBlobId
    of blobSessions: k.sessionsBlobId
    of blobSecrets: k.secretsBlobId
  if s.isWebdav:
    BlobStore(url: base & "/webby-sync-" & id[0 ..< 32] & ".json", webdav: true,
      auth: "Basic " & encode(s{"username"}.getStr & ":" & s{"password"}.getStr))
  else:
    BlobStore(url: base & "/v1/blobs/" & id, auth: "Bearer " & k.authToken)

proc failure(b: BlobStore, r: Response): string =
  if r.status == 0: return r.error
  case r.status
  of 401, 403:
    if b.webdav: "The WebDAV server didn't accept the username and password."
    else: "The sync server refused this device's key."
  of 404, 405, 409: "There's no sync folder at " & b.url & "."
  of 413: "The vault is too big for the sync server."
  of 507: "The sync server is out of space."
  else: "The sync server answered " & $r.status & " " & r.reason & "."

proc read(b: BlobStore, onDone: proc (found: bool, bytes, etag, error: string)) =
  request("GET", b.url, [("Authorization", b.auth), ("Cache-Control", "no-cache")], "", proc (r: Response) =
    if r.status == 404: onDone(false, "", "", "")
    elif r.status != 200: onDone(false, "", "", b.failure(r))
    else: onDone(true, r.body, r.header("etag"), ""))

proc write(b: BlobStore, bytes: string, ifMatch: string, create: bool,
           onDone: proc (etag: string, conflict: bool, error: string)) =
  ## A conditional PUT: if still at `ifMatch`, or (`create`) still absent.
  let cond = if create: ("If-None-Match", "*") else: ("If-Match", ifMatch)
  request("PUT", b.url, [("Authorization", b.auth), ("Content-Type", "application/octet-stream"), cond], bytes,
    proc (r: Response) =
      if r.status == 412: onDone("", true, "")
      elif r.status < 200 or r.status > 299: onDone("", false, b.failure(r))
      else: onDone(r.header("etag"), false, ""))

proc deleteBlob(b: BlobStore, onDone: proc (error: string)) =
  request("DELETE", b.url, [("Authorization", b.auth)], "", proc (r: Response) =
    if r.status != 404 and (r.status < 200 or r.status > 299): onDone(b.failure(r)) else: onDone(""))

proc eraseAll*(s: JsonNode, onDone: proc (error: string)) =
  ## Deletes every blob of the sync key, one after another; stops at the first error.
  var k: SyncKeys
  try: k = deriveKeys(s.code)
  except CatchableError as e:
    onDone(e.msg)
    return
  proc step(blob: SyncBlob) =
    deleteBlob(store(s, k, blob), proc (error: string) =
      if error.len > 0: onDone(error)
      elif blob == high(SyncBlob): onDone("")
      else: step(succ(blob)))
  step(low(SyncBlob))

proc syncOnce*(s: JsonNode, local: JsonNode, blob: SyncBlob, onDone: proc (o: Outcome)) =
  ## Merges `local` with the server's copy and makes the server hold the result, retrying when another device
  ## writes in between.
  var k: SyncKeys
  try: k = deriveKeys(s.code)
  except CatchableError as e:
    onDone(Outcome(error: e.msg))
    return
  let b = store(s, k, blob)
  proc attempt(n: int) =
    if n >= 5:
      onDone(Outcome(error: "Other devices kept syncing at the same moment; try again."))
      return
    b.read(proc (found: bool, bytes, etag, error: string) =
      if error.len > 0:
        onDone(Outcome(error: error))
        return
      var remote: JsonNode
      try: remote = if found: k.open(bytes) else: newDoc()
      except CatchableError as e:
        onDone(Outcome(error: e.msg))
        return
      let merged = mergeDocs(local, remote, nowSeconds())
      if found and sameDoc(merged, remote):
        onDone(Outcome(doc: merged, etag: etag))
        return
      var sealed: string
      try: sealed = k.seal(merged)
      except CatchableError as e:
        onDone(Outcome(error: e.msg))
        return
      b.write(sealed, if etag.len > 0: etag else: "*", not found, proc (newTag: string, conflict: bool, error: string) =
        if conflict: attempt(n + 1)
        elif error.len > 0: onDone(Outcome(error: error))
        else: onDone(Outcome(doc: merged, etag: newTag))))
  attempt(0)
