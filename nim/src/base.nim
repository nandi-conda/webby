## The parts of the browser core that know nothing about a window: the profile's files, the process's mode, and
## hooks a store may call. browser.nim (the GTK front end) and nim/android build on it; feature stores import only
## this so both front ends can use them.

import std/[json, os, tables]
export json, tables

var
  appUrl*: string              ## --app=<url>: an installed web app's own window (no tab strip, no URL bar)
  incognito*: bool             ## --incognito: this process keeps nothing (see app/lib/src/incognito.dart)

  # Device-only secrets kept in the password vault (e.g. the DeepSeek key), set by the passwords feature.
  # nil until it installs; getSecret returns "" when there is none.
  getSecret*: proc (name: string): string
  setSecret*: proc (name, value: string)

  # Timers on the front end's main loop, set by it (GLib on the desktop, the pump on Android): `action` runs once,
  # `ms` from now; the id stops it.
  startTimer*: proc (ms: int, action: proc ()): int
  stopTimer*: proc (id: int)

# ---------------------------------------------------------------------------------------------------------------
# Files: the same places the Flutter app keeps its data, so both front ends share a profile.

proc dataHome*(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  if xdg.len > 0: xdg else: getHomeDir() / ".local" / "share"

proc profileName*(): string =
  let p = getEnv("WEBBY_PROFILE")
  if p.len > 0: p else: "default"

proc profileDir*(): string = dataHome() / "webby" / "profiles" / profileName()

proc profileFile*(name: string): string = profileDir() / name

proc readJsonFile*(path: string): JsonNode =
  ## The file's JSON, or nil if it's missing or unreadable.
  try: parseJson(readFile(path)) except CatchableError: nil

proc writeFileAtomic*(path, content: string) =
  createDir(path.parentDir)
  let tmp = path & ".tmp"
  writeFile(tmp, content)
  moveFile(tmp, path)

proc writeJsonFile*(path: string, node: JsonNode, pretty = false) =
  writeFileAtomic(path, if pretty: node.pretty else: $node)
