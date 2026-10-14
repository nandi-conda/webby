## This device's open tabs as other devices see them, and the tabs they published (app/lib/src/tabs/device_tabs.dart).
## The device id, its name and whether it shares its tabs are in `<profile>/device.json` (or $WEBBY_DEVICE_FILE), the
## same file as the Flutter app's. Other devices' tabs live only in memory and come from the tabs blob.

import std/[algorithm, json, os, posix, strutils, uri]
from std/unicode import runes, Rune, `$`
import ../../base
import doc, blobs
from ../passwords/crypto import randomBytes

const
  heartbeat = 3600     ## seconds between republishing an unchanged record
  maxTabs = 200
  maxTitle = 300
  maxUrl = 4096

type
  DeviceTab* = tuple[title, url: string]
  RemoteDevice* = object
    id*, name*, platform*: string
    seenAt*: int64
    tabs*: seq[DeviceTab]

var
  deviceId*: string
  myName: string
  shareOn = true
  openTabs: seq[DeviceTab]
  published: JsonNode     ## what this device last put on the server (nil: nothing yet)
  remote = newJObject()
  loaded = false
  deviceListeners*: seq[proc ()]   ## name, sharing, this device's tabs or the other devices' changed

proc notify() =
  for h in deviceListeners: h()

proc deviceFile(): string =
  let o = getEnv("WEBBY_DEVICE_FILE")
  if o.len > 0: o else: profileFile("device.json")

proc defaultName(): string =
  if deviceDescription.len > 0: return deviceDescription
  var buf: array[256, char]
  if gethostname(cast[cstring](addr buf[0]), buf.len) == 0:
    let host = $cast[cstring](addr buf[0])
    if host.len > 0 and host != "localhost": return host
  "Linux computer"

proc save() =
  try: writeJsonFile(deviceFile(), %*{"id": deviceId, "name": myName, "share": shareOn}, pretty = true)
  except CatchableError as e: stderr.writeLine "webby: could not save ", deviceFile(), ": ", e.msg

proc load() =
  if loaded: return
  loaded = true
  let j = readJsonFile(deviceFile())
  if j != nil and j.kind == JObject and j{"id"}.getStr.len > 0:
    deviceId = j["id"].getStr
    let n = j{"name"}.getStr
    myName = if n.strip.len > 0: n else: defaultName()
    shareOn = if j{"share"} != nil and j["share"].kind == JBool: j["share"].getBool else: true
    return
  deviceId = randomBytes(16).toHex.toLowerAscii
  myName = defaultName()
  save()

proc deviceName*(): string = (load(); myName)
proc setDeviceName*(value: string) =
  load()
  let t = value.strip
  if t.len == 0 or t == myName: return
  myName = t
  save()
  notify()

proc sharing*(): bool = (load(); shareOn)
proc setSharing*(on: bool) =
  load()
  if on == shareOn: return
  shareOn = on
  save()
  notify()

proc sharedTabs*(): seq[DeviceTab] = openTabs

proc isShareableUrl*(url: string): bool =
  ## Worth showing on another device: not blank pages, nothing only this device can open.
  try:
    let u = parseUri(url)
    let scheme = u.scheme.toLowerAscii
    scheme in ["http", "https", "ftp", "file"] and (scheme == "file" or u.hostname.len > 0)
  except CatchableError: false

proc cut(text: string, max: int): string =
  ## The first `max` UTF-16 code units, as Dart's substring would keep.
  if utf16Len(text) <= max: return text
  var n = 0
  for r in text.runes:
    let w = if r.int >= 0x10000: 2 else: 1
    if n + w > max: break
    result.add $r
    n += w

proc setTabs*(list: seq[DeviceTab]) =
  ## Called whenever the browser's tabs change; tabs that make no sense elsewhere are left out.
  var shareable: seq[DeviceTab]
  for t in list:
    if isShareableUrl(t.url) and shareable.len < maxTabs: shareable.add (cut(t.title, maxTitle), cut(t.url, maxUrl))
  if shareable == openTabs: return
  openTabs = shareable
  notify()

proc devices*(): seq[RemoteDevice] =
  ## The other devices, most recently seen first.
  load()
  for id, r in remote:
    if id == deviceId or isDeleted(r): continue
    var d = RemoteDevice(id: id, name: (if r{"name"} != nil and r["name"].kind == JString: r["name"].getStr
                                        else: "Unnamed device"),
      platform: r{"platform"}.getStr, seenAt: updatedAtOf(r))
    for t in r{"tabs"}.getElems:
      if t.kind == JObject and t{"url"} != nil and t["url"].kind == JString and t["url"].getStr.len > 0:
        d.tabs.add ((if t{"title"} != nil and t["title"].kind == JString: t["title"].getStr else: ""), t["url"].getStr)
    result.add d
  result.sort(proc (a, b: RemoteDevice): int = cmp(b.seenAt, a.seenAt))

proc record(updatedAt: int64): JsonNode =
  if not shareOn: return %*{"updatedAt": updatedAt, "deleted": true}
  result = %*{"name": myName, "platform": (when defined(android): "android" else: "linux"), "updatedAt": updatedAt, "tabs": []}
  for t in openTabs: result["tabs"].add %*{"title": t.title, "url": t.url}

proc withoutTime(r: JsonNode): string =
  let c = r.copy
  if c.hasKey("updatedAt"): c.delete("updatedAt")
  canonicalValue(c)

proc needsPublish*(): bool =
  ## This device's record changed, or is due for the heartbeat.
  load()
  if published == nil: return true
  if withoutTime(record(0)) != withoutTime(published): return true
  not isDeleted(published) and nowSeconds() - updatedAtOf(published) >= heartbeat

proc toSyncDoc*(): JsonNode =
  ## This device's own record for the tabs blob, refreshed if needsPublish.
  load()
  let r = if needsPublish(): record(max(nowSeconds(), if published == nil: 0'i64 else: updatedAtOf(published) + 1))
          else: published
  docWith("devices", %*{deviceId: r})

proc applySyncDoc*(d: JsonNode): bool =
  ## Takes in the merged tabs blob. True if this device's record there differs from what it would publish.
  load()
  let all = d.section("devices")
  published = all{deviceId}
  let others = newJObject()
  for k, r in all:
    if k != deviceId: others[k] = r
  let changed = canonicalValue(others) != canonicalValue(remote)
  remote = others
  if changed: notify()
  needsPublish()

proc reset*() =
  ## Forgets what was synced (sync turned off or re-keyed).
  published = nil
  if remote.len == 0: return
  remote = newJObject()
  notify()
