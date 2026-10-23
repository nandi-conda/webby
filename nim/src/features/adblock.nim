## Ad and tracker blocking on the desktop: ⋮ > "Block ads and trackers" (on by default). The engine and the switch
## are in adblock/store.nim; this seeds the engine before Ladybird starts and adds the menu item.
## YouTube serves its ads from the video hosts, out of reach of URL rules, so YouTube pages also get a page script
## (scripts/youtube_ads.js) that strips the ads from the player's data and skips any that still play.

import std/[os, strutils, uri]
import ../browser
import adblock/store
import tabs/common


proc toggle(on: bool) =
  setEnabled(on)
  let what = if on: "Blocking ads and trackers" else: "Ads and trackers allowed"
  if appliesLive():
    let t = currentTab()
    if t != nil and t.view != nil and t.url.len > 0:
      webby_view_reload(t.view)
      wake()
    toast(what)
  else:
    toast(what & " from the next start")

proc seedIncognitoProfile() =
  ## Incognito windows' throwaway profile gets the switch and a copy of the normal profile's lists (it doesn't
  ## download its own).
  writeLadybirdSettings(incognitoProfile / "config" / "Settings.json", enabled(), updateLists = false)
  if not enabled(): return
  let lists = incognitoProfile / "data" / "ContentBlocking" / "Lists"
  try:
    createDir(lists)
    for f in downloadedLists(originalLadybirdArgs): copyFile(f, lists / f.extractFilename)
  except CatchableError: discard

const youTubeScript = staticRead("../scripts/youtube_ads.js")

proc isYouTube(url: string): bool =
  let host = try: parseUri(url).hostname.toLowerAscii except CatchableError: ""
  host == "youtube.com" or host.endsWith(".youtube.com")

proc youTubePageScript(t: Tab): string =
  if enabled() and isYouTube(t.url): youTubeScript else: ""

proc install*() =
  pageScriptHooks.add youTubePageScript
  startupHooks.add proc () =
    if incognito and incognitoProfile.len > 0: seedIncognitoProfile()
    else: prepareEngine()
  windowHooks.add proc () =
    addMenuSeparator()
    addMenuCheck("Block ads and trackers", enabled, proc () = toggle(not enabled()))
