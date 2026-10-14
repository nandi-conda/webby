## Saved summaries (app/lib/src/summary_cache.dart): by page (and by selection), newest last, in
## profiles/<profile>/summaries.json, the same file and format as the Flutter app. Incognito keeps them in memory only.

import std/[algorithm, os, strutils, times]
import ../../base

type
  CachedSummary* = object
    title*, url*, text*: string
    at*: int64                 ## when it was made, ms since the epoch
    selection*: bool
    questions*: seq[tuple[question, answer: string]]
    updatedAt*: int64          ## when it last changed, seconds; the newest copy wins in sync

const summaryLimit* = 300

var
  entries: OrderedTable[string, CachedSummary]
  deleted: OrderedTable[string, int64]
  cacheFile: string
  loaded = false
  summaryListeners*: seq[proc ()]  ## run after every change (sync listens)

proc fromJson(j: JsonNode): CachedSummary =
  result = CachedSummary(title: j{"title"}.getStr, url: j{"url"}.getStr, text: j{"text"}.getStr,
    at: j{"at"}.getBiggestInt, selection: j{"selection"}.getBool)
  result.updatedAt = if j{"updatedAt"} != nil: j{"updatedAt"}.getFloat.int64 else: result.at div 1000
  for qa in j{"questions"}.getElems:
    if qa{"q"} != nil and qa{"q"}.kind == JString and qa{"a"} != nil and qa{"a"}.kind == JString:
      result.questions.add (qa["q"].getStr, qa["a"].getStr)

proc toJson(s: CachedSummary): JsonNode =
  result = %*{"title": s.title, "url": s.url, "text": s.text, "at": s.at}
  if s.selection: result["selection"] = %true
  if s.questions.len > 0:
    var qs = newJArray()
    for qa in s.questions: qs.add %*{"q": qa.question, "a": qa.answer}
    result["questions"] = qs
  result["updatedAt"] = %s.updatedAt

proc summariesFile(): string =
  let o = getEnv("WEBBY_SUMMARIES_FILE")
  if o.len > 0: o else: profileFile("summaries.json")

proc load() =
  if loaded: return
  loaded = true
  if incognito: return
  cacheFile = summariesFile()
  let j = readJsonFile(cacheFile)
  if j == nil or j.kind != JObject: return
  for k, v in j{"summaries"}.getFields:
    if v.kind == JObject: entries[k] = fromJson(v)
  for k, v in j{"deleted"}.getFields:
    if v.kind == JInt: deleted[k] = v.getBiggestInt

proc save() =
  if cacheFile.len == 0: return
  var s = newJObject()
  for k, v in entries: s[k] = toJson(v)
  var j = %*{"version": 1, "summaries": s}
  if deleted.len > 0:
    var d = newJObject()
    for k, v in deleted: d[k] = %v
    j["deleted"] = d
  try: writeJsonFile(cacheFile, j)
  except CatchableError as e: stderr.writeLine "webby: could not save summaries: ", e.msg
  for h in summaryListeners: h()

proc fnv1a(text: string): string =
  # FNV-1a, 64-bit: enough to tell selections apart.
  var h = 0xcbf29ce484222325'u64
  for c in text: h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  result = toHex(h).toLowerAscii.strip(trailing = false, chars = {'0'})
  if result.len == 0: result = "0"

proc summaryKey*(url: string, selection = ""): string =
  ## The URL without its #fragment, or for a selection, the URL and a hash of the selected text.
  let hash = url.find('#')
  let page = if hash >= 0: url[0 ..< hash] else: url
  if selection.len == 0: page else: page & "\n" & fnv1a(selection)

proc lookupSummary*(key: string): (bool, CachedSummary) =
  load()
  if key in entries: (true, entries[key]) else: (false, CachedSummary())

proc nowSeconds(): int64 = getTime().toUnix

proc storeSummary*(key: string, summary: CachedSummary) =
  load()
  var previous = deleted.getOrDefault(key, 0)
  if key in entries:
    previous = entries[key].updatedAt
    entries.del key
  var s = summary
  s.updatedAt = max(nowSeconds(), previous + 1)
  entries[key] = s
  deleted.del key
  while entries.len > summaryLimit:
    for k in entries.keys:
      entries.del k
      break
  save()

proc clearSummaries*(sinceMs: int64 = 0) =
  ## Forgets summaries made since `sinceMs` (all of them when 0), for Clear browsing data.
  load()
  let now = nowSeconds()
  var gone: seq[string]
  for k, v in entries:
    if sinceMs == 0 or v.at >= sinceMs: gone.add k
  for k in gone:
    deleted[k] = max(now, entries[k].updatedAt + 1)
    entries.del k
  save()

proc toSyncRecords*(): JsonNode =
  ## The summaries in their synced form (SyncDoc.summaries): a record per key plus tombstones for cleared ones.
  load()
  result = newJObject()
  for k, at in deleted: result[k] = %*{"updatedAt": at, "deleted": true}
  for k, v in entries: result[k] = toJson(v)

proc applySyncRecords*(records: JsonNode): bool =
  ## Replaces the summaries with merged sync records. Returns whether anything changed.
  load()
  if records == nil or records.kind != JObject or records == toSyncRecords(): return false
  var live: seq[(string, CachedSummary)]
  deleted.clear
  for k, r in records:
    if r.kind != JObject: continue
    if r{"deleted"}.getBool: deleted[k] = r{"updatedAt"}.getBiggestInt
    else: live.add (k, fromJson(r))
  live.sort(proc (a, b: (string, CachedSummary)): int = cmp(a[1].updatedAt, b[1].updatedAt))
  entries.clear
  for (k, v) in live: entries[k] = v
  while entries.len > summaryLimit:
    for k in entries.keys:
      entries.del k
      break
  save()
  true
