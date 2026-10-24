## Media controls (MPRIS): a page playing audio or video shows up in Plasma's media player applet, the lock screen
## and the media keys (GNOME's too), with its title, artist and artwork, play/pause, seeking and, when the page
## offers them (navigator.mediaSession action handlers), next and previous. The page side is
## scripts/media_session.js; this is one player for the whole window, following the tab that played last, as the
## browser extension did. The name (org.mpris.MediaPlayer2.webby.instance<pid>) is only held while some tab has media.

import std/[json, monotimes, os, strutils, tables, times]
import ../../browser
import dbus, common

const
  pagePath = "/org/mpris/MediaPlayer2"
  rootIface = "org.mpris.MediaPlayer2"
  playerIface = "org.mpris.MediaPlayer2.Player"
  pageScript = staticRead("../../scripts/media_session.js")
  xml = """<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="CanSetFullscreen" type="b" access="read"/>
    <property name="Fullscreen" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek"><arg direction="in" name="Offset" type="x"/></method>
    <method name="SetPosition"><arg direction="in" name="TrackId" type="o"/><arg direction="in" name="Position" type="x"/></method>
    <method name="OpenUri"><arg direction="in" name="Uri" type="s"/></method>
    <signal name="Seeked"><arg name="Position" type="x"/></signal>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Rate" type="d" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>"""

type Media = object
  state, title, artist, album, art, url: string
  duration, position, rate, volume: float
  at: MonoTime              ## when `position` was reported
  canNext, canPrevious, canSeek: bool
  track: int                ## changes with the title, for mpris:trackid

var
  media: Table[string, Media]   ## tab's messagePrefix -> what it plays (only tabs with state playing or paused)
  playerTab: Tab                ## the tab the controls are for
  nameId: cuint
  exported = false
  sent: Table[string, string]   ## property -> the variant text last announced
  tracks = 0
  desktopEntry* = "webby"       ## set by plasma.nim from the installed launcher

proc tabFor(prefix: string): Tab =
  for t in tabs:
    if t.messagePrefix == prefix: return t

proc current(): Media = (if playerTab != nil: media.getOrDefault(playerTab.messagePrefix) else: Media(state: "none"))

proc positionNow(m: Media): float =
  result = m.position
  if m.state == "playing": result += (getMonoTime() - m.at).inMilliseconds.float / 1000 * m.rate
  if m.duration > 0: result = min(result, m.duration)

proc us(seconds: float): int64 = int64(seconds * 1e6)
proc b(v: bool): string = (if v: "<true>" else: "<false>")
proc d(v: float): string = "<" & formatFloat(v, ffDecimal, 6) & ">"
proc trackId(m: Media): string = "/dev/webby/track/" & $m.track

proc status(m: Media): string =
  case m.state
  of "playing": "Playing"
  of "paused": "Paused"
  else: "Stopped"

proc metadata(m: Media): string =
  ## The Metadata property's value as variant text.
  if m.state notin ["playing", "paused"]: return "<@a{sv} {}>"
  var parts = @["'mpris:trackid': <objectpath " & q(trackId(m)) & ">", "'xesam:title': <" & q(m.title) & ">"]
  if m.artist.len > 0: parts.add "'xesam:artist': <[" & q(m.artist) & "]>"
  if m.album.len > 0: parts.add "'xesam:album': <" & q(m.album) & ">"
  if m.art.len > 0: parts.add "'mpris:artUrl': <" & q(m.art) & ">"
  if m.url.len > 0: parts.add "'xesam:url': <" & q(m.url) & ">"
  if m.duration > 0: parts.add "'mpris:length': <int64 " & $us(m.duration) & ">"
  "<@a{sv} {" & parts.join(", ") & "}>"

proc playerProps(m: Media): seq[(string, string)] =
  let has = m.state in ["playing", "paused"]
  @[("PlaybackStatus", "<" & q(status(m)) & ">"), ("Metadata", metadata(m)), ("Rate", d(if has: m.rate else: 1.0)),
    ("Volume", d(if has: m.volume else: 1.0)), ("CanGoNext", b(m.canNext)), ("CanGoPrevious", b(m.canPrevious)),
    ("CanPlay", b(has)), ("CanPause", b(has)), ("CanSeek", b(has and m.canSeek)), ("CanControl", b(true)),
    ("MinimumRate", d(0.25)), ("MaximumRate", d(4.0))]

proc rootProps(): seq[(string, string)] =
  @[("CanQuit", b(false)), ("CanRaise", b(true)), ("CanSetFullscreen", b(false)), ("Fullscreen", b(false)),
    ("HasTrackList", b(false)), ("Identity", "<'Webby'>"), ("DesktopEntry", "<" & q(desktopEntry) & ">"),
    ("SupportedUriSchemes", "<@as []>"), ("SupportedMimeTypes", "<@as []>")]

proc control(action: string, value = 0.0) =
  let t = playerTab
  if t == nil or t.view == nil: return
  t.runJs("window.__webbyMedia && window.__webbyMedia(" & $(%action) & ", " & $value & ")")
  wake()

proc onCall(meth: string, params: GVariant, inv: pointer) =
  let m = current()
  case meth
  of "Raise":
    if playerTab != nil: showTab(playerTab) else: raiseWindow()
  of "Quit": discard
  of "Next": control("next")
  of "Previous": control("previous")
  of "Pause": control("pause")
  of "PlayPause": control("playpause")
  of "Stop": control("stop")
  of "Play": control("play")
  of "Seek": control("seek", params.int64At(0).float / 1e6)
  of "SetPosition":
    if params.stringAt(0) == trackId(m): control("position", params.int64At(1).float / 1e6)
  of "OpenUri": discard openTab(params.stringAt(0))
  else:
    replyError(inv, "no method " & meth)
    return
  reply(inv)

proc onGet(iface, name: string): GVariant =
  let m = current()
  if name == "Position": return gv("x", $us(positionNow(m)))
  for (k, v) in (if iface == rootIface: rootProps() else: playerProps(m)):
    if k == name:
      let outer = gv("v", v)
      result = g_variant_get_variant(outer)   # the value inside the "<…>"
      g_variant_unref(outer)
      return

proc onSet(iface, name: string, value: GVariant) =
  if name == "Volume": control("volume", g_variant_get_double(value))
  # Rate: pages pick their own playback speed; not settable from outside.

proc announce() =
  ## PropertiesChanged for whatever differs from what was last sent (a Seeked when the position jumped).
  let m = current()
  var changed: seq[(string, string)]
  for (k, v) in playerProps(m):
    if sent.getOrDefault(k, "") != v:
      sent[k] = v
      changed.add (k, v)
  propertiesChanged(pagePath, playerIface, changed)

proc pickPlayer() =
  ## The tab that played last keeps the controls while it has media; else another tab with media, playing first.
  for t in tabs:
    if t.view == nil: media.del t.messagePrefix   # asleep: its page is gone
  if playerTab != nil and (playerTab.closed or playerTab.messagePrefix notin media): playerTab = nil
  if playerTab == nil or media[playerTab.messagePrefix].state != "playing":
    for t in tabs:
      if t.messagePrefix in media and media[t.messagePrefix].state == "playing":
        playerTab = t
        break
  if playerTab == nil:
    for t in tabs:
      if t.messagePrefix in media:
        playerTab = t
        break
  # The bus name comes and goes with the media, so the applet doesn't list an idle browser.
  if playerTab != nil and nameId == 0:
    if not exported: exported = exportObject(pagePath, xml, [rootIface, playerIface], onCall, onGet, onSet)
    if exported:
      sent.clear()
      for (k, v) in playerProps(current()): sent[k] = v
      nameId = own("org.mpris.MediaPlayer2.webby.instance" & $getCurrentProcessId())
  elif playerTab == nil and nameId != 0:
    unown(nameId)
    nameId = 0
  if nameId != 0: announce()

proc onMessage(t: Tab, msg: string): bool =
  if not msg.startsWith("{\"type\":\"media\""): return false
  try:
    let j = parseJson(msg)
    let state = j{"state"}.getStr
    if state notin ["playing", "paused"]:
      media.del t.messagePrefix
    else:
      let before = media.getOrDefault(t.messagePrefix)
      var m = Media(state: state, title: j{"title"}.getStr, artist: j{"artist"}.getStr, album: j{"album"}.getStr,
        art: j{"art"}.getStr, url: t.url, duration: j{"duration"}.getFloat, position: j{"position"}.getFloat,
        rate: j{"rate"}.getFloat(1), volume: j{"volume"}.getFloat(1), at: getMonoTime(),
        canNext: j{"canNext"}.getBool, canPrevious: j{"canPrevious"}.getBool, canSeek: j{"canSeek"}.getBool,
        track: before.track)
      if m.track == 0 or m.title != before.title:
        inc tracks
        m.track = tracks
      let jumped = before.state.len > 0 and m.track == before.track and abs(positionNow(before) - m.position) > 1.5
      media[t.messagePrefix] = m
      if state == "playing": playerTab = t
      if jumped and t == playerTab and nameId != 0:
        pickPlayer()
        emit(pagePath, playerIface, "Seeked", gv("(x)", "(int64 " & $us(m.position) & ",)"))
        return true
  except CatchableError: discard
  pickPlayer()
  true

proc forget(t: Tab) =
  if t.messagePrefix in media:
    media.del t.messagePrefix
    pickPlayer()

proc install*() =
  pageScriptHooks.add proc (t: Tab): string =
    pageScript.replace("__WEBBY_MEDIA_PREFIX__", $(%t.messagePrefix))
  pageMessageHooks.add onMessage
  tabClosedHooks.add forget
  tabStateHooks.add proc (t: Tab) =
    # A new page loading ends the old one's media (the page script reports what the new one plays).
    if t.loading or t.view == nil: forget(t)
  shutdownHooks.add proc () =
    if nameId != 0: unown(nameId)
