## The parts of the browser core that know nothing about a window: the profile's files, the process's mode, and
## hooks a store may call. browser.nim (the GTK front end) and nim/android build on it; feature stores import only
## this so both front ends can use them.

import std/[json, os, tables]
export json, tables

var
  appUrl*: string              ## --app=<url>: an installed web app's own window (no tab strip, no URL bar)
  incognito*: bool             ## --incognito: this process keeps nothing (see app/lib/src/incognito.dart)
  incognitoProfile*: string    ## incognito: the throwaway Ladybird profile directory (deleted on exit)
  originalLadybirdArgs*: seq[string]  ## $WEBBY_LADYBIRD_ARGS before incognito swapped the profile out

  # Secrets kept in the password vault (e.g. the DeepSeek key), set by the passwords feature. nil until it installs;
  # getSecret returns "" when there is none. A secret syncs to the other devices unless secretSyncs says no.
  getSecret*: proc (name: string): string
  setSecret*: proc (name, value: string, sync: bool)
  secretSyncs*: proc (name: string): bool

  # Timers on the front end's main loop, set by it (GLib on the desktop, the pump on Android): `action` runs once,
  # `ms` from now; the id stops it.
  startTimer*: proc (ms: int, action: proc ()): int
  stopTimer*: proc (id: int)

  # HTTP for front ends without GIO (Android: Java's HttpURLConnection). `done` gets (status (0 = failed), reason,
  # headers with lower-case names, body, error) on the main loop.
  httpRequest*: proc (meth, url: string, headers: seq[(string, string)], body: string,
                      done: proc (status: int, reason: string, headers: seq[(string, string)], body, error: string))

  # Streamed HTTP (Android: DeepSeek summaries): `onStatus` once the headers are in, `onData` for each piece of the
  # body, then `onDone` with "" or an error; all on the main loop. Returns an id for httpStreamCancel.
  httpStream*: proc (meth, url: string, headers: seq[(string, string)], body: string, onStatus: proc (status: int),
                     onData: proc (data: string), onDone: proc (error: string)): int
  httpStreamCancel*: proc (id: int)

  deviceDescription*: string   ## e.g. "Pixel 6a" on Android (sync names the device after it); "" on the desktop

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
