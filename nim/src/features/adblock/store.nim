## Ad and tracker blocking, shared by the desktop and Android front ends.
##
## The engine is Ladybird's own content blocker (Brave's adblock engine: network rules and element hiding), fed
## EasyList and EasyPrivacy, which Ladybird downloads into the profile's ContentBlocking/Lists and refreshes daily.
## It is off in a fresh Ladybird profile, so prepareEngine writes the switch into the profile's Settings.json before
## webby_init. Runtimes with webby_set_content_blocking also switch it while running; older ones at the next start.
## The choice is <data>/webby/profiles/<profile>/content_blocking.json ({"enabled": bool}), on by default.

import std/[os, strutils]
import ../../[base, ffi]

proc prefFile(): string = profileFile("content_blocking.json")

var enabledCache = -1

proc enabled*(): bool =
  if enabledCache < 0:
    let j = readJsonFile(prefFile())
    enabledCache = if j != nil and j{"enabled"} != nil and j{"enabled"}.kind == JBool: ord(j{"enabled"}.getBool) else: 1
  enabledCache == 1

proc appliesLive*(): bool = webby_set_content_blocking != nil
  ## Whether the running engine follows setEnabled at once (else at the next start).

proc setEnabled*(on: bool) =
  if enabled() == on: return
  enabledCache = ord(on)
  # Incognito windows follow the normal profile's choice but don't change it.
  if not incognito:
    try: writeJsonFile(prefFile(), %*{"enabled": on}) except CatchableError: discard
  if appliesLive(): webby_set_content_blocking(on.cint)

proc configHome(): string =
  let x = getEnv("XDG_CONFIG_HOME")
  if x.len > 0: x else: getHomeDir() / ".config"

proc ladybirdProfileDirs*(args: seq[string]): tuple[ok: bool, config, data: string] =
  ## The config and data directories of the Ladybird profile `args` select (LibWebView/Profile.cpp); not ok for a
  ## temporary profile, which has no fixed path.
  when defined(android):
    # Ladybird's legacy layout under $XDG_CONFIG_HOME / $XDG_DATA_HOME (LadybirdRuntime.java).
    return (true, configHome() / "Ladybird", dataHome() / "Ladybird")
  else:
    var name = "default"
    var path = ""
    for i, a in args:
      let next = if i + 1 < args.len: args[i + 1] else: ""
      if a in ["--temporary-profile", "--force-new-process"]: return (false, "", "")
      if a == "--profile-path": path = next
      if a.startsWith("--profile-path="): path = a["--profile-path=".len .. ^1]
      if a == "--profile": name = next
      if a.startsWith("--profile="): name = a["--profile=".len .. ^1]
    if path.len > 0: return (true, path / "config", path / "data")
    (true, configHome() / "Ladybird" / "Profiles" / name, dataHome() / "Ladybird" / "Profiles" / name)

proc writeLadybirdSettings*(file: string, on, updateLists: bool) =
  ## Sets the content blocker (and its EasyList and EasyPrivacy lists) on or off in Ladybird's Settings.json `file`,
  ## keeping everything else. `updateLists` lets Ladybird download and refresh the lists.
  let before = try: readFile(file) except CatchableError: ""
  var j = try: parseJson(before) except CatchableError: newJObject()
  if j.kind != JObject: j = newJObject()
  proc obj(parent: JsonNode, key: string): JsonNode =
    if parent{key} == nil or parent{key}.kind != JObject: parent[key] = newJObject()
    parent[key]
  let blockers = j.obj("contentBlockers")
  blockers["enabled"] = %on
  let lists = blockers.obj("builtInLists")
  lists["easyList"] = %true
  lists["easyPrivacy"] = %true
  j.obj("backgroundNetworking").obj("features")["contentBlockerSubscriptionUpdates"] = %updateLists
  let after = j.pretty(4)
  if after == before: return
  try: writeFileAtomic(file, after) except CatchableError: discard

proc ladybirdArgs*(): seq[string] = getEnv("WEBBY_LADYBIRD_ARGS").splitWhitespace

proc prepareEngine*() =
  ## Writes the switch into the Ladybird profile's Settings.json. Runs right before webby_init.
  let dirs = ladybirdProfileDirs(ladybirdArgs())
  if dirs.ok: writeLadybirdSettings(dirs.config / "Settings.json", enabled(), updateLists = not incognito)

proc downloadedLists*(args: seq[string]): seq[string] =
  ## The lists Ladybird downloaded for the profile `args` select (incognito windows copy the normal profile's).
  let dirs = ladybirdProfileDirs(args)
  if not dirs.ok: return
  for id in ["easyList", "easyPrivacy"]:
    let f = dirs.data / "ContentBlocking" / "Lists" / (id & ".txt")
    if fileExists(f): result.add f
