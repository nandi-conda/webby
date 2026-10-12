## The device's location for pages' navigator.geolocation (app/lib/src/geolocation.dart): GeoClue over the system
## D-Bus, running only while a page that was allowed to is waiting for a position or watching.

import std/[monotimes, strutils, times]
import ../../browser
import gio

const
  geoclue = "org.freedesktop.GeoClue2"
  errorPermissionDenied = 1.cint
  errorPositionUnavailable = 2.cint
  fresh = initDuration(seconds = 30)      ## a fix this recent answers a new one-off request straight away
  linger = initDuration(seconds = 5)      ## the service keeps running this long after the last page stopped
  retryAfter = initDuration(seconds = 5)  ## after a failure, how long before trying the service again
  accuracyExact = 8'u32

type Fix = tuple[lat, lon, accuracy, altitude, heading, speed: float]

var
  client: string          ## the GeoClue client's object path while it runs
  starting = false
  signalId: cuint
  last: Fix
  lastAt, idleSince, failedAt: MonoTime
  hasFix, idle, failed = false

proc deliver(f: Fix) =
  let nan = NaN
  # GeoClue reports what it doesn't know as -1 (speed, heading) or -DBL_MAX (altitude).
  webby_geolocation_set_position(f.lat, f.lon, f.accuracy, (if f.altitude > -1e300: f.altitude else: nan), nan,
    (if f.heading >= 0 and f.speed > 0: f.heading else: nan), (if f.speed >= 0: f.speed else: nan))
  wake()

proc fail(code: cint, message: string) =
  stderr.writeLine "webby: location: ", message
  failed = true
  failedAt = getMonoTime()
  webby_geolocation_set_error(code, message.cstring)
  wake()

proc stop() =
  if client.len > 0:
    let path = client
    call(busSystem, geoclue, path, geoclue & ".Client", "Stop", nil, proc (r: GVariant, e: string) =
      call(busSystem, geoclue, "/org/freedesktop/GeoClue2/Manager", geoclue & ".Manager", "DeleteClient",
        g_variant_new("(o)", path.cstring)))
  unsubscribe(busSystem, signalId)
  signalId = 0
  client = ""
  idle = false

proc readLocation(path: string) =
  call(busSystem, geoclue, path, "org.freedesktop.DBus.Properties", "GetAll",
    g_variant_new("(s)", cstring(geoclue & ".Location")), proc (r: GVariant, e: string) =
      if r == nil: return
      let props = child(r, 0)
      proc num(name: string, fallback = NaN): float =
        let v = g_variant_lookup_value(props, name.cstring, variantType("d"))
        if v == nil: return fallback
        result = g_variant_get_double(v)
        g_variant_unref(v)
      last = (num("Latitude"), num("Longitude"), num("Accuracy"), num("Altitude", -Inf), num("Heading", -1.0),
        num("Speed", -1.0))
      g_variant_unref(props)
      hasFix = true
      failed = false
      lastAt = getMonoTime()
      if client.len > 0: deliver(last))

proc start() =
  starting = true
  proc failStart(e: string) =
    starting = false
    stop()
    fail(if "AccessDenied" in e or "denied" in e: errorPermissionDenied else: errorPositionUnavailable, e)
  call(busSystem, geoclue, "/org/freedesktop/GeoClue2/Manager", geoclue & ".Manager", "GetClient", nil,
    proc (r: GVariant, e: string) =
      if r == nil:
        failStart("GeoClue: " & e)
        return
      let path = stringAt(r, 0)
      client = path
      signalId = subscribe(busSystem, geoclue, geoclue & ".Client", "LocationUpdated", path,
        proc (p: string, params: GVariant) = readLocation(stringAt(params, 1)))
      let setProp = proc (name: string, value: GVariant, next: proc ()) =
        call(busSystem, geoclue, path, "org.freedesktop.DBus.Properties", "Set",
          g_variant_new("(ssv)", cstring(geoclue & ".Client"), name.cstring, value), proc (r: GVariant, e: string) =
            if r == nil: failStart("GeoClue: " & e) else: next())
      setProp("DesktopId", g_variant_new_string("webby"), proc () =
        setProp("RequestedAccuracyLevel", g_variant_new_uint32(accuracyExact), proc () =
          call(busSystem, geoclue, path, geoclue & ".Client", "Start", nil, proc (r: GVariant, e: string) =
            if r == nil: failStart("GeoClue: " & e) else: starting = false))))

proc poll(data: pointer): gboolean {.cdecl.} =
  let wanted = webby_geolocation_wanted()
  let now = getMonoTime()
  if wanted == 0:
    if client.len > 0:
      if not idle: (idle = true; idleSince = now)
      if now - idleSince >= linger: stop()
    return 1
  idle = false
  # While the service runs it reports every move, so its last fix is the current position.
  if (wanted and geolocationRequested) != 0 and hasFix and (client.len > 0 or now - lastAt < fresh):
    deliver(last)
    return 1
  if client.len > 0 or starting: return 1
  if failed and now - failedAt < retryAfter: return 1
  start()
  1

proc install*() =
  windowHooks.add proc () = discard g_timeout_add(250, poll, nil)
