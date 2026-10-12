## GIO D-Bus and GVariant declarations for the site features (notifications, GeoClue, the desktop's colour
## scheme), with a callback-style wrapper around asynchronous method calls.

type GVariant* = pointer

const
  busSystem* = 1.cint
  busSession* = 2.cint

{.push cdecl, importc.}
proc g_bus_get_sync(busType: cint, cancellable: pointer, err: ptr pointer): pointer
proc g_dbus_connection_call(conn: pointer, busName, path, iface, meth: cstring, params: GVariant,
  replyType: pointer, flags: cint, timeoutMs: cint, cancellable: pointer, callback, data: pointer)
proc g_dbus_connection_call_finish(conn, res: pointer, err: ptr pointer): GVariant
proc g_dbus_connection_signal_subscribe(conn: pointer, sender, iface, member, path, arg0: cstring, flags: cint,
  callback, data, destroy: pointer): cuint
proc g_dbus_connection_signal_unsubscribe(conn: pointer, id: cuint)
proc g_variant_new*(fmt: cstring): GVariant {.varargs.}
proc g_variant_get*(v: GVariant, fmt: cstring) {.varargs.}
proc g_variant_new_string*(s: cstring): GVariant
proc g_variant_new_uint32*(u: uint32): GVariant
proc g_variant_ref_sink*(v: GVariant): GVariant
proc g_variant_unref*(v: GVariant)
proc g_variant_n_children*(v: GVariant): csize_t
proc g_variant_get_child_value*(v: GVariant, i: csize_t): GVariant
proc g_variant_get_variant*(v: GVariant): GVariant
proc g_variant_get_type_string*(v: GVariant): cstring
proc g_variant_get_double*(v: GVariant): cdouble
proc g_variant_get_uint32*(v: GVariant): uint32
proc g_variant_get_string*(v: GVariant, length: pointer): cstring
proc g_variant_lookup_value*(dict: GVariant, key: cstring, expected: pointer): GVariant
proc g_variant_builder_new*(kind: pointer): pointer
proc g_variant_builder_add*(b: pointer, fmt: cstring) {.varargs.}
proc g_variant_builder_unref*(b: pointer)
proc g_error_free(err: pointer)
{.pop.}

proc variantType*(s: static string): pointer = cast[pointer](cstring(s))  ## G_VARIANT_TYPE("...")

proc errorText(err: pointer): string =
  type GError = object
    domain: uint32
    code: cint
    message: cstring
  result = $cast[ptr GError](err).message
  g_error_free(err)

var buses: array[3, pointer]

proc bus*(kind: cint): pointer =
  ## The session or system bus, or nil when there is none (logged once).
  if buses[kind] == nil:
    var err: pointer
    buses[kind] = g_bus_get_sync(kind, nil, addr err)
    if err != nil: stderr.writeLine "webby: D-Bus ", (if kind == busSystem: "system" else: "session"), " bus: ",
      errorText(err)
  buses[kind]

type
  Reply* = proc (result: GVariant, error: string)   ## result is nil on error and freed after the call
  CallState = ref object
    done: Reply

proc onCallDone(source, res, data: pointer) {.cdecl.} =
  let state = cast[CallState](data)
  var err: pointer
  let v = g_dbus_connection_call_finish(source, res, addr err)
  let error = if err != nil: errorText(err) else: ""
  if state.done != nil: state.done(v, error)
  if v != nil: g_variant_unref(v)
  GC_unref(state)

proc call*(kind: cint, dest, path, iface, meth: string, params: GVariant, done: Reply = nil, timeoutMs = 25000) =
  ## Calls a D-Bus method asynchronously. `params` (floating) is consumed.
  let conn = bus(kind)
  if conn == nil:
    if params != nil: g_variant_unref(g_variant_ref_sink(params))
    if done != nil: done(nil, "no D-Bus bus")
    return
  let state = CallState(done: done)
  GC_ref(state)
  g_dbus_connection_call(conn, dest.cstring, path.cstring, iface.cstring, meth.cstring, params, nil, 0,
    timeoutMs.cint, nil, onCallDone, cast[pointer](state))

type
  SignalHandler* = proc (path: string, params: GVariant)
  SignalState = ref object
    handler: SignalHandler

proc onSignal(conn: pointer, sender, path, iface, name: cstring, params: GVariant, data: pointer) {.cdecl.} =
  cast[SignalState](data).handler($path, params)

proc subscribe*(kind: cint, sender, iface, member: string, path = "", handler: SignalHandler): cuint =
  ## Listens to a D-Bus signal; returns the subscription id (0 when there is no bus).
  let conn = bus(kind)
  if conn == nil: return 0
  let state = SignalState(handler: handler)
  GC_ref(state)
  g_dbus_connection_signal_subscribe(conn, sender.cstring, iface.cstring, member.cstring,
    (if path.len > 0: path.cstring else: nil), nil, 0, onSignal, cast[pointer](state), nil)

proc unsubscribe*(kind: cint, id: cuint) =
  if id != 0 and bus(kind) != nil: g_dbus_connection_signal_unsubscribe(bus(kind), id)

proc child*(v: GVariant, i: int): GVariant =
  ## Child `i` of a tuple, with variants unwrapped (free with g_variant_unref).
  result = g_variant_get_child_value(v, i.csize_t)
  while result != nil and $g_variant_get_type_string(result) == "v":
    let inner = g_variant_get_variant(result)
    g_variant_unref(result)
    result = inner

proc stringAt*(v: GVariant, i: int): string =
  let c = child(v, i)
  result = $g_variant_get_string(c, nil)
  g_variant_unref(c)

proc uint32At*(v: GVariant, i: int): uint32 =
  let c = child(v, i)
  result = g_variant_get_uint32(c)
  g_variant_unref(c)
