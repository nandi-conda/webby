## The tab files of a profile, in the Flutter app's formats (app/lib/src/tabs/{sessions,open_tabs,tab_layout}.dart):
## sessions.json (saved sessions), pinned_tabs.json (pinned tabs for the next start) and tabs.json (the layout).
## Incognito windows write none of them except tabs.json, which is a preference.
##
## The session store is what sync uses: `toSyncDoc` gives the "sessions" section of a SyncDoc (one record per session
## plus tombstones), `applySyncDoc` takes a merged one back, and `sessionListeners` hear every change.

import std/[json, os, strutils, times]
import ../../browser

type
  DeviceTab* = object
    title*, url*: string

  SavedSession* = ref object
    id*, name*: string
    savedAt*: int        ## seconds since the epoch
    tabs*: seq[DeviceTab]
    active*: int         ## the tab that was in front
    updatedAt*: int      ## when it last changed (seconds), so sync keeps the newest version

const tombstoneLifetime* = 180 * 24 * 3600  ## seconds a deletion is remembered (sync_doc.dart)

var
  sessionList: seq[SavedSession]   # newest first
  deleted: seq[(string, int)]      # tombstones: id, when (seconds)
  idCounter = 0
  loaded = false
  sessionLoadError*: string        ## why sessions.json couldn't be read (it was set aside), or ""
  sessionListeners*: seq[proc ()]  ## run after every change, local or from sync

proc nowSeconds*(): int = int(epochTime())

proc isSessionUrl*(url: string): bool = url.len > 0 and url != "about:blank"

proc toJson*(t: DeviceTab): JsonNode = %*{"title": t.title, "url": t.url}

proc deviceTabFromJson*(j: JsonNode): (bool, DeviceTab) =
  if j == nil or j.kind != JObject: return
  let url = j{"url"}.getStr
  if url.len == 0: return
  (true, DeviceTab(title: j{"title"}.getStr, url: url))

proc toJson*(s: SavedSession): JsonNode =
  result = %*{"id": s.id, "name": s.name, "savedAt": s.savedAt, "active": s.active, "tabs": newJArray(),
              "updatedAt": s.updatedAt}
  for t in s.tabs: result["tabs"].add t.toJson

proc sessionFromJson*(j: JsonNode): SavedSession =
  ## nil unless it has an id and at least one tab.
  if j == nil or j.kind != JObject: return nil
  let id = j{"id"}.getStr
  if id.len == 0: return nil
  var tabs: seq[DeviceTab]
  for e in j{"tabs"}.getElems:
    let (ok, t) = deviceTabFromJson(e)
    if ok: tabs.add t
  if tabs.len == 0: return nil
  let saved = j{"savedAt"}.getInt
  let up = j{"updatedAt"}
  SavedSession(id: id, name: j{"name"}.getStr, savedAt: saved, tabs: tabs,
    active: clamp(j{"active"}.getInt, 0, tabs.high),
    updatedAt: if up != nil and up.kind in {JInt, JFloat}: int(up.getFloat) else: saved)

proc sessionsFile*(): string =
  let o = getEnv("WEBBY_SESSIONS_FILE")
  if o.len > 0: o else: profileFile("sessions.json")

proc sortSessions() =
  # Newest first.
  for i in 1 ..< sessionList.len:
    var j = i
    while j > 0 and sessionList[j - 1].savedAt < sessionList[j].savedAt:
      swap(sessionList[j - 1], sessionList[j])
      dec j

proc load() =
  if loaded: return
  loaded = true
  let path = sessionsFile()
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    if j.kind != JObject: raise newException(ValueError, "not a JSON object")
    for e in j{"sessions"}.getElems:
      let s = sessionFromJson(e)
      if s != nil: sessionList.add s
    sortSessions()
    if j{"deleted"} != nil and j["deleted"].kind == JObject:
      for k, v in j["deleted"]:
        if v.kind in {JInt, JFloat}: deleted.add (k, int(v.getFloat))
  except CatchableError as e:
    # Keep the unreadable file for the user rather than overwriting it on the next save.
    let aside = path & ".corrupt-" & $int(epochTime() * 1000)
    try: moveFile(path, aside) except CatchableError: discard
    sessionLoadError = "Could not read " & path & " (" & e.msg & "); it was moved to " & aside & "."
    sessionList.setLen 0
    deleted.setLen 0

proc save() =
  if incognito: return
  let expireBefore = nowSeconds() - tombstoneLifetime
  var kept: seq[(string, int)]
  for d in deleted:
    if d[1] >= expireBefore: kept.add d
  deleted = kept
  let j = %*{"version": 1, "sessions": newJArray()}
  for s in sessionList: j["sessions"].add s.toJson
  if deleted.len > 0:
    let d = newJObject()
    for (id, at) in deleted: d[id] = %at
    j["deleted"] = d
  try: writeJsonFile(sessionsFile(), j, pretty = true)
  except CatchableError as e: stderr.writeLine "webby: could not save ", sessionsFile(), ": ", e.msg

proc changed() =
  save()
  for h in sessionListeners: h()

proc sessions*(): seq[SavedSession] =
  ## Newest first.
  load()
  sessionList

proc touch(s: SavedSession) = s.updatedAt = max(nowSeconds(), s.updatedAt + 1)

proc tombstoneIndex(id: string): int =
  for i, d in deleted:
    if d[0] == id: return i
  -1

proc tombstone(s: SavedSession) =
  let i = tombstoneIndex(s.id)
  if i >= 0: deleted.delete(i)
  deleted.add (s.id, max(nowSeconds(), s.updatedAt + 1))

proc has(s: SavedSession): bool =
  for x in sessionList:
    if x.id == s.id: return true

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

proc defaultSessionName*(t = now()): string =
  ## "Oct 12, 14:05": the name a session gets when the user doesn't give one.
  months[ord(t.month) - 1] & " " & $t.monthday & ", " & align($t.hour, 2, '0') & ":" & align($t.minute, 2, '0')

proc sessionCreated*(seconds: int): string =
  ## "Created Oct 12, 2026, 14:05".
  let t = fromUnix(seconds).local
  let name = defaultSessionName(t)
  let comma = name.find(',')
  "Created " & name[0 ..< comma] & ", " & $t.year & name[comma .. ^1]

proc toBase36(n: int64): string =
  const digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  var v = n
  if v == 0: return "0"
  while v > 0:
    result.insert($digits[int(v mod 36)], 0)
    v = v div 36

proc saveSession*(tabs: seq[DeviceTab], name = "", active = 0): SavedSession =
  ## Saves `tabs` (blank ones left out) as a session called `name`, or one from the date when it's empty.
  ## `active` is the index in `tabs` of the tab in front. nil when there's nothing to save, or in incognito.
  if incognito: return nil
  load()
  var kept: seq[DeviceTab]
  var keptActive = 0
  for i, t in tabs:
    if not isSessionUrl(t.url): continue
    if i <= active: keptActive = kept.len
    kept.add t
  if kept.len == 0: return nil
  let micros = int64(epochTime() * 1_000_000)
  let trimmed = name.strip
  result = SavedSession(id: toBase36(micros) & toBase36(idCounter), name: (if trimmed.len == 0: defaultSessionName() else: trimmed),
    savedAt: int(micros div 1_000_000), tabs: kept, active: keptActive)
  result.updatedAt = result.savedAt
  inc idCounter
  sessionList.insert(result, 0)
  changed()

proc renameSession*(s: SavedSession, name: string) =
  let trimmed = name.strip
  if trimmed.len == 0 or trimmed == s.name or s notin sessionList: return
  s.name = trimmed
  touch(s)
  changed()

proc removeSessionTab*(s: SavedSession, index: int): (bool, DeviceTab) =
  ## Takes the tab at `index` out of `s` and returns it; the session goes when its last tab does.
  if s notin sessionList or index notin 0 ..< s.tabs.len: return
  result = (true, s.tabs[index])
  s.tabs.delete(index)
  if s.tabs.len == 0:
    sessionList.delete(sessionList.find(s))
    tombstone(s)
  else:
    if s.active >= s.tabs.len: s.active = s.tabs.high
    touch(s)
  changed()

proc restoreDeletedSession*(s: SavedSession)

proc restoreSessionTab*(s: SavedSession, tab: DeviceTab, index: int) =
  ## Puts `tab` back at `index` in `s` (undo), bringing the session back if it had gone.
  s.tabs.insert(tab, clamp(index, 0, s.tabs.len))
  if not has(s): restoreDeletedSession(s)
  else:
    touch(s)
    changed()

proc deleteSession*(s: SavedSession) =
  let i = sessionList.find(s)
  if i < 0: return
  sessionList.delete(i)
  tombstone(s)
  changed()

proc restoreDeletedSession*(s: SavedSession) =
  ## Puts back a session that was just deleted (undo).
  if has(s): return
  let i = tombstoneIndex(s.id)
  if i >= 0:
    s.updatedAt = max(s.updatedAt, deleted[i][1])
    deleted.delete(i)
  touch(s)
  sessionList.add s
  sortSessions()
  changed()

proc deleteAllSessions*() =
  if sessionList.len == 0: return
  for s in sessionList: tombstone(s)
  sessionList.setLen 0
  changed()

proc toSyncDoc*(): JsonNode =
  ## The sessions in their synced form: {id: {name, savedAt, active, tabs, updatedAt}} plus {id: {updatedAt,
  ## deleted: true}} tombstones (the "sessions" section of a SyncDoc).
  load()
  result = newJObject()
  for (id, at) in deleted: result[id] = %*{"updatedAt": at, "deleted": true}
  for s in sessionList:
    let j = s.toJson
    j.delete("id")
    result[s.id] = j

proc applySyncDoc*(doc: JsonNode): bool =
  ## Replaces the sessions with a merged "sessions" section. Sessions already shown are updated in place, so an Undo
  ## still finds them. Returns whether anything changed.
  load()
  if doc == nil or doc.kind != JObject or toSyncDoc() == doc: return false
  var next: seq[SavedSession]
  var tombs: seq[(string, int)]
  for id, rec in doc:
    if rec.kind != JObject: continue
    if rec{"deleted"}.getBool:
      let up = rec{"updatedAt"}
      tombs.add (id, if up != nil and up.kind in {JInt, JFloat}: int(up.getFloat) else: 0)
      continue
    let copy = rec.copy
    copy["id"] = %id
    let incoming = sessionFromJson(copy)
    if incoming == nil: continue
    var existing: SavedSession
    for s in sessionList:
      if s.id == id: existing = s
    if existing == nil or existing.savedAt != incoming.savedAt:
      next.add incoming
      continue
    existing.name = incoming.name
    existing.active = incoming.active
    existing.updatedAt = incoming.updatedAt
    existing.tabs = incoming.tabs
    next.add existing
  sessionList = next
  sortSessions()
  deleted = tombs
  changed()
  true

# ---------------------------------------------------------------------------------------------------------------
# pinned_tabs.json (desktop's pinned tabs for the next start) in open_tabs.dart's format.

proc pinnedTabsFile*(): string = sessionsFile().parentDir / "pinned_tabs.json"

proc readTabsFile*(path: string): tuple[tabs: seq[DeviceTab], active, pinned: int] =
  ## The tabs an OpenTabsStore file holds (blank ones left out), the front one and how many at the start are pinned.
  let j = readJsonFile(path)
  if j == nil or j.kind != JObject: return
  for e in j{"tabs"}.getElems:
    let (ok, t) = deviceTabFromJson(e)
    if ok and isSessionUrl(t.url): result.tabs.add t
  if result.tabs.len == 0: return
  result.active = clamp(j{"active"}.getInt, 0, result.tabs.high)
  result.pinned = clamp(j{"pinned"}.getInt, 0, result.tabs.len)

var pinnedWritten: string

proc writePinnedTabs*(tabs: seq[DeviceTab]) =
  ## Saves the pinned tabs for the next start (all of them pinned, the first in front). Never in incognito.
  if incognito: return
  var kept: seq[DeviceTab]
  for t in tabs:
    if isSessionUrl(t.url): kept.add t
  let j = %*{"version": 1, "active": 0, "pinned": kept.len, "tabs": newJArray()}
  for t in kept: j["tabs"].add t.toJson
  let s = $j
  if s == pinnedWritten: return
  try:
    writeFileAtomic(pinnedTabsFile(), s)
    pinnedWritten = s
  except CatchableError as e: stderr.writeLine "webby: could not save ", pinnedTabsFile(), ": ", e.msg

# ---------------------------------------------------------------------------------------------------------------
# tabs.json: the tab layout. Incognito windows read and change it too: it's a preference, not browsing data.

proc layoutFile*(): string =
  let o = getEnv("WEBBY_TABS_FILE")
  if o.len > 0: o else: profileFile("tabs.json")

proc readVerticalTabs*(): bool =
  let j = readJsonFile(layoutFile())
  j != nil and j.kind == JObject and j{"vertical"}.getBool

proc writeVerticalTabs*(vertical: bool) =
  try: writeJsonFile(layoutFile(), %*{"version": 1, "vertical": vertical})
  except CatchableError as e: stderr.writeLine "webby: could not save ", layoutFile(), ": ", e.msg
