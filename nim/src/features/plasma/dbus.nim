## Serving D-Bus objects on the session bus through GIO: owning a name, exporting an object's interfaces from
## introspection XML, emitting signals, and GVariants written in GLib's text format (see `gv`). Calls to other
## services and signal subscriptions are in ../site/gio.nim.

import std/[json, strutils]
import ../site/gio
export gio

type
  MethodCall* = proc (meth: string, params: GVariant, inv: pointer)  ## answer with `reply`/`replyError`
  GetProperty* = proc (iface, name: string): GVariant                 ## a GVariant from `gv`, or nil
  SetProperty* = proc (iface, name: string, value: GVariant)
  Exported = ref object
    onCall: MethodCall
    onGet: GetProperty
    onSet: SetProperty
  VTable = object
    methodCall, getProperty, setProperty: pointer
    padding: array[8, pointer]

{.push cdecl, importc.}
proc g_dbus_node_info_new_for_xml(xml: cstring, err: ptr pointer): pointer
proc g_dbus_node_info_lookup_interface(info: pointer, name: cstring): pointer
proc g_dbus_connection_register_object(conn: pointer, path: cstring, iface: pointer, vtable: ptr VTable,
  data, free: pointer, err: ptr pointer): cuint
proc g_dbus_connection_emit_signal(conn: pointer, dest, path, iface, name: cstring, params: GVariant,
  err: ptr pointer): cint
proc g_dbus_method_invocation_return_value(inv: pointer, params: GVariant)
proc g_dbus_method_invocation_return_dbus_error(inv: pointer, name, message: cstring)
proc g_bus_own_name_on_connection(conn: pointer, name: cstring, flags: cint, acquired, lost, data, free: pointer): cuint
proc g_bus_unown_name(id: cuint)
proc g_variant_parse(kind: pointer, text, limit: cstring, endptr: pointer, err: ptr pointer): GVariant
proc g_variant_get_int64*(v: GVariant): int64
proc g_variant_get_boolean*(v: GVariant): cint
proc g_variant_is_of_type(v: GVariant, kind: pointer): cint
proc g_variant_print(v: GVariant, annotate: cint): cstring
proc g_free(p: pointer)
proc g_error_free(err: pointer)
{.pop.}

proc message(err: pointer): string =
  type GError = object
    domain: uint32
    code: cint
    message: cstring
  result = $cast[ptr GError](err).message
  g_error_free(err)

# ---------------------------------------------------------------------------------------------------------------
# GVariants as text: gv("(sa{sv})", "('x', {'k': <int64 5>})"). `q` quotes a string for it.

proc q*(s: string): string = escapeJson(s)   ## a GVariant text string ("…" with \" \\ \n \uXXXX, all of which it reads)

proc gv*(kind, text: string): GVariant =
  ## A GVariant of D-Bus type `kind` from GLib's text format (a full reference: `call`, `reply`, `emit` and
  ## property getters take care of it). nil, with a log line, when `text` doesn't parse.
  var err: pointer
  result = g_variant_parse(cast[pointer](kind.cstring), text.cstring, nil, nil, addr err)
  if err != nil: stderr.writeLine "webby: bad GVariant ", kind, " ", text, ": ", message(err)

proc `$`*(v: GVariant): string =
  if v == nil: return "nil"
  let c = g_variant_print(v, 0)
  result = $c
  g_free(c)

proc int64At*(v: GVariant, i: int): int64 =
  let c = child(v, i)
  result = g_variant_get_int64(c)
  g_variant_unref(c)

proc doubleAt*(v: GVariant, i: int): float =
  let c = child(v, i)
  result = g_variant_get_double(c)
  g_variant_unref(c)

proc isType*(v: GVariant, kind: string): bool = g_variant_is_of_type(v, cast[pointer](kind.cstring)) != 0

proc call*(dest, path, iface, meth: string, params: GVariant, done: Reply = nil) =
  ## A session bus call with `params` from `gv` (or nil).
  if params != nil: discard g_variant_ref_sink(params)
  gio.call(busSession, dest, path, iface, meth, params, done)

# ---------------------------------------------------------------------------------------------------------------
# Serving

proc onMethod(conn: pointer, sender, path, iface, meth: cstring, params: GVariant, inv, data: pointer) {.cdecl.} =
  let e = cast[Exported](data)
  if e.onCall != nil: e.onCall($meth, params, inv)
  else: g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.UnknownMethod", meth)

proc onGetProperty(conn: pointer, sender, path, iface, name: cstring, err: ptr pointer, data: pointer): GVariant {.cdecl.} =
  let e = cast[Exported](data)
  if e.onGet != nil: result = e.onGet($iface, $name)
  if result == nil: result = g_variant_new_string("")

proc onSetProperty(conn: pointer, sender, path, iface, name: cstring, value: GVariant, err: ptr pointer,
    data: pointer): cint {.cdecl.} =
  let e = cast[Exported](data)
  if e.onSet != nil: e.onSet($iface, $name, value)
  1

var vtable = VTable(methodCall: onMethod, getProperty: onGetProperty, setProperty: onSetProperty)

proc reply*(inv: pointer, value: GVariant = nil) =
  ## Answers a method call with `value` (a tuple from `gv`, nil for no out arguments).
  g_dbus_method_invocation_return_value(inv, value)
  if value != nil: g_variant_unref(value)

proc replyError*(inv: pointer, text: string) =
  g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.Failed", text.cstring)

proc exportObject*(path, xml: string, ifaces: openArray[string], onCall: MethodCall, onGet: GetProperty = nil,
    onSet: SetProperty = nil): bool =
  ## Serves `ifaces` (described in the introspection `xml`) at `path` on the session bus. False without a bus.
  let conn = bus(busSession)
  if conn == nil: return false
  var err: pointer
  let info = g_dbus_node_info_new_for_xml(xml.cstring, addr err)   # kept for good: the registrations use it
  if info == nil:
    stderr.writeLine "webby: D-Bus interface XML: ", message(err)
    return false
  let e = Exported(onCall: onCall, onGet: onGet, onSet: onSet)
  GC_ref(e)
  result = true
  for name in ifaces:
    let iface = g_dbus_node_info_lookup_interface(info, name.cstring)
    if g_dbus_connection_register_object(conn, path.cstring, iface, addr vtable, cast[pointer](e), nil,
        addr err) == 0:
      stderr.writeLine "webby: D-Bus ", path, " ", name, ": ", message(err)
      result = false

proc emit*(path, iface, name: string, params: GVariant) =
  ## Sends a signal from our object at `path` (params: a tuple from `gv`).
  let conn = bus(busSession)
  if conn != nil: discard g_dbus_connection_emit_signal(conn, nil, path.cstring, iface.cstring, name.cstring, params, nil)
  if params != nil: g_variant_unref(params)

proc propertiesChanged*(path, iface: string, changed: seq[(string, string)]) =
  ## PropertiesChanged for `iface` at `path`; `changed` holds (name, value as "<…>" variant text).
  if changed.len == 0: return
  var parts: seq[string]
  for (k, v) in changed: parts.add q(k) & ": " & v
  emit(path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
    gv("(sa{sv}as)", "(" & q(iface) & ", {" & parts.join(", ") & "}, @as [])"))

# Owning a name. GIO calls back from the main loop; the name stays ours until `unown`.
type NameState = ref object
  name: string
  owned: bool

var names: seq[(cuint, NameState)]

proc onAcquired(conn: pointer, name: cstring, data: pointer) {.cdecl.} = cast[NameState](data).owned = true
proc onLost(conn: pointer, name: cstring, data: pointer) {.cdecl.} =
  let s = cast[NameState](data)
  if s.owned: stderr.writeLine "webby: lost the D-Bus name ", s.name
  else: stderr.writeLine "webby: D-Bus name ", s.name, " is taken"
  s.owned = false

proc own*(name: string): cuint =
  ## Asks for `name` on the session bus (without queueing behind another owner); 0 without a bus.
  let conn = bus(busSession)
  if conn == nil: return 0
  let s = NameState(name: name)
  GC_ref(s)
  result = g_bus_own_name_on_connection(conn, name.cstring, 4, onAcquired, onLost, cast[pointer](s), nil)  # DO_NOT_QUEUE
  names.add (result, s)

proc unown*(id: cuint) =
  if id == 0: return
  g_bus_unown_name(id)
  for i, (n, s) in names:
    if n == id:
      GC_unref(s)
      names.delete(i)
      break
