## Keeps the vault, its synced secrets, bookmarks, this device's open tabs, page summaries and saved sessions in sync
## with the other devices (vault_sync.dart): at startup, a few seconds after each change, every five minutes, and when
## asked. Each kind has its own blob under the vault's sync settings. Everything runs on the GTK loop, one request at a time.

import std/[json, sets]
import ../../base
import ../passwords/[vault, manager]
from ../bookmarks/store as bookmarkStore import nil
from ../summarize/cache as summaryCache import nil
from ../tabs/store as sessionStore import nil
import doc, keys, blobs, http, devicetabs

var
  statusListeners*: seq[proc ()]  ## syncing started or stopped, settings or the last error changed
  running = false
  again = false
  debounce, tabsDebounce: Timer
  lastSynced: array[SyncBlob, string]   ## canonical form of what the server held after the last round

proc settings*(): JsonNode =
  if theVault == nil: return nil
  let s = theVault.syncSettings
  if s != nil and s.kind == JObject and s{"code"}.getStr.len > 0: s else: nil

proc enabled*(): bool = settings() != nil and not incognito and appUrl.len == 0
proc syncing*(): bool = running
proc lastError*(): string = (let s = settings(); if s == nil: "" else: s{"lastError"}.getStr)

proc notifyStatus() =
  for h in statusListeners: h()

proc syncNow*()

proc vaultDoc(): JsonNode = docFromJson(theVault.toSyncDoc())
proc secretsDoc(): JsonNode = docFromJson(theVault.secretsSyncDoc())
proc bookmarksDoc(): JsonNode = docWith("bookmarks", bookmarkStore.toSyncRecords())
proc summariesDoc(): JsonNode = docWith("summaries", summaryCache.toSyncRecords())
proc sessionsDoc(): JsonNode = docWith("sessions", sessionStore.toSyncDoc())

proc changedLocally(blob: SyncBlob, current: proc (): JsonNode) =
  ## A store changed: sync in 3 s unless it's what was just synced.
  if not enabled() or running: return
  if lastSynced[blob].len > 0 and canonical(current()) == lastSynced[blob]: return
  debounce.cancel()
  debounce = after(3000, syncNow)

proc tabsChanged() =
  # Tabs change with every page load; publish once browsing settles.
  if not enabled() or running or not needsPublish(): return
  tabsDebounce.cancel()
  tabsDebounce = after(10_000, syncNow)

proc updateSettings(change: proc (s: JsonNode)) =
  let s = settings()
  if s == nil: return
  let c = s.copy
  change(c)
  theVault.setSyncSettings(c)

proc forget() =
  for b in SyncBlob: lastSynced[b] = ""
  devicetabs.reset()

proc passkeyIds(): HashSet[string] =
  for p in theVault.passkeys: result.incl p{"credentialId"}.getStr

proc syncNow*() =
  ## One round over every blob; another follows if something changed meanwhile.
  if running:
    again = true
    return
  let s = settings()
  if s == nil or not enabled(): return
  let code = s.code
  running = true
  debounce.cancel()
  tabsDebounce.cancel()
  notifyStatus()
  let stillOn = proc (): bool = (let c = settings(); c != nil and c.code == code)

  proc finish(error: string) =
    if error.len > 0:
      stderr.writeLine "webby: sync failed: ", error
      if stillOn(): updateSettings(proc (c: JsonNode) = c["lastError"] = %error)
    running = false
    notifyStatus()
    if again:
      again = false
      discard after(0, syncNow)

  # The kinds after the vault, each: read + merge + write its blob, then take the merged state in.
  proc stores(blob: SyncBlob, current: proc (): JsonNode, apply: proc (merged: JsonNode), next: proc ()) =
    syncOnce(s, current(), blob, proc (o: Outcome) =
      if o.error.len > 0: (finish(o.error); return)
      if not stillOn(): (finish(""); return)
      let merged = mergeDocs(current(), o.doc, nowSeconds())
      lastSynced[blob] = canonical(o.doc)
      apply(merged)
      if not sameDoc(merged, o.doc): again = true
      next())

  proc sessions() =
    stores(blobSessions, sessionsDoc, proc (m: JsonNode) = discard sessionStore.applySyncDoc(m.section("sessions")),
      proc () = finish(""))
  proc summaries() =
    stores(blobSummaries, summariesDoc,
      proc (m: JsonNode) = discard summaryCache.applySyncRecords(m.section("summaries")), sessions)
  proc tabs() =
    syncOnce(s, devicetabs.toSyncDoc(), blobTabs, proc (o: Outcome) =
      if o.error.len > 0: (finish(o.error); return)
      if not stillOn(): (finish(""); return)
      # Tabs that changed during the round, or this device's record lost to another's, go up next round.
      if devicetabs.applySyncDoc(o.doc): again = true
      summaries())
  proc bookmarks() =
    stores(blobBookmarks, bookmarksDoc,
      proc (m: JsonNode) = discard bookmarkStore.applySyncRecords(m.section("bookmarks")), tabs)
  proc secrets() =
    stores(blobSecrets, secretsDoc, proc (m: JsonNode) = theVault.applySecretsSyncDoc(m), bookmarks)

  syncOnce(s, vaultDoc(), blobVault, proc (o: Outcome) =
    if o.error.len > 0: (finish(o.error); return)
    if not stillOn(): (finish(""); return)
    # The vault may have changed while we were talking to the server; keep those changes too.
    let merged = mergeDocs(vaultDoc(), o.doc, nowSeconds())
    let before = passkeyIds()
    lastSynced[blobVault] = canonical(o.doc)
    let passkeysChanged = theVault.applySyncDoc(merged)
    let etag = o.etag
    updateSettings(proc (c: JsonNode) =
      if etag.len > 0: c["etag"] = %etag
      c["lastSync"] = %nowSeconds()
      if c.hasKey("lastError"): c.delete("lastError"))
    if passkeysChanged:
      var removed: seq[string]
      let after = passkeyIds()
      for id in before:
        if id.len > 0 and id notin after: removed.add id
      passkeysSynced(removed)
    if not sameDoc(merged, o.doc): again = true
    secrets())

proc enable*(s: JsonNode) =
  ## Starts syncing with these settings (from newSettings or fromPairing). Raises BadSyncCode.
  discard keyFromCode(s.code)
  if theVault == nil: return
  forget()
  theVault.setSyncSettings(s)
  notifyStatus()
  syncNow()

proc disable*(erase: bool, onDone: proc (error: string)) =
  ## Stops syncing here; with `erase` also deletes the server's copies first, which stops every device syncing.
  let s = settings()
  if s == nil: (onDone(""); return)
  proc off() =
    debounce.cancel()
    tabsDebounce.cancel()
    forget()
    theVault.setSyncSettings(nil)
    notifyStatus()
    onDone("")
  if not erase: (off(); return)
  eraseAll(s, proc (error: string) =
    if error.len > 0: onDone(error) else: off())

proc start*() =
  ## Hooks the stores up once the vault is open, and syncs now and every five minutes.
  if theVault == nil or incognito or appUrl.len > 0: return
  theVault.onChange.add proc () = changedLocally(blobVault, vaultDoc)
  theVault.onChange.add proc () = changedLocally(blobSecrets, secretsDoc)
  bookmarkStore.changeHooks.add proc () = changedLocally(blobBookmarks, bookmarksDoc)
  summaryCache.summaryListeners.add proc () = changedLocally(blobSummaries, summariesDoc)
  sessionStore.sessionListeners.add proc () = changedLocally(blobSessions, sessionsDoc)
  deviceListeners.add tabsChanged
  proc every5min() =
    syncNow()
    discard startTimer(5 * 60 * 1000, every5min)
  discard startTimer(5 * 60 * 1000, every5min)
  if enabled(): discard after(500, syncNow)
