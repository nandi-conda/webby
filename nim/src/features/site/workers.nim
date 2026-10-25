## Workers that share the page's IndexedDB: Ladybird keeps IndexedDB per process and runs each worker in its own,
## so on the sites listed in scripts/worker_idb.js those workers' IndexedDB calls are carried out by the page.

import std/[strutils, uri]
import ../../browser

const workerIdbScript = staticRead("../../scripts/worker_idb.js")

proc bridged(url: string): bool =
  let host = try: parseUri(url).hostname.toLowerAscii except CatchableError: ""
  host == "reams.ink"

proc install*() =
  # Early: the page's own scripts start their workers while it loads.
  earlyPageScriptHooks.add proc (t: Tab): string =
    if bridged(t.url): workerIdbScript else: ""
