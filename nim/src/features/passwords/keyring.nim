## The vault key in the desktop keyring (Secret Service) through libsecret, as app/webby_keyring/linux does: schema
## "dev.webby.Vault", attributes {application: webby, profile: <profile>}, label "Webby password vault (<profile>)".
## libsecret is loaded at run time so the browser still starts without it (the vault then keeps its key in a file).
## Calls block on D-Bus (and may show an unlock prompt).
## On Android the key goes to the Android Keystore instead, through `androidKeyring` (set by features/android.nim).

type KeyringError* = object of CatchableError  ## no keyring to talk to, or it refused

when defined(android):
  var androidKeyring*: tuple[lookup: proc (profile: string): (bool, string), store: proc (profile, secret: string)]

  proc keyringLookup*(profile: string): (bool, string) =
    if androidKeyring.lookup == nil: raise newException(KeyringError, "no Android keystore")
    androidKeyring.lookup(profile)

  proc keyringStore*(profile, secret: string) =
    if androidKeyring.store == nil: raise newException(KeyringError, "no Android keystore")
    androidKeyring.store(profile, secret)

  proc keyringLocked*(profile: string): bool = false

else:
  import std/dynlib

  {.passL: gorge("pkg-config --libs glib-2.0").}

  type
    SchemaAttribute = object
      name: cstring
      kind: cint
    SecretSchema = object
      name: cstring
      flags: cint
      attributes: array[32, SchemaAttribute]
      reserved: cint
      reserved1, reserved2, reserved3, reserved4, reserved5, reserved6, reserved7: pointer
    GError = object
      domain: uint32
      code: cint
      message: cstring


  {.push cdecl, importc.}
  proc g_hash_table_new(hash, equal: pointer): pointer
  proc g_hash_table_insert(table: pointer, key, value: pointer): cint
  proc g_hash_table_unref(table: pointer)
  proc g_str_hash(v: pointer): cuint
  proc g_str_equal(a, b: pointer): cint
  proc g_error_free(e: ptr GError)
  {.pop.}

  type
    LookupV = proc (schema: ptr SecretSchema, attributes, cancellable: pointer, error: ptr ptr GError): cstring {.cdecl.}
    StoreV = proc (schema: ptr SecretSchema, attributes: pointer, collection, label, password: cstring,
      cancellable: pointer, error: ptr ptr GError): cint {.cdecl.}
    PasswordFree = proc (p: cstring) {.cdecl.}
    ServiceGet = proc (flags: cint, cancellable: pointer, error: ptr ptr GError): pointer {.cdecl.}
    ServiceSearch = proc (service: pointer, schema: ptr SecretSchema, attributes: pointer, flags: cint,
      cancellable: pointer, error: ptr ptr GError): ptr GList {.cdecl.}
    ItemGetLocked = proc (item: pointer): cint {.cdecl.}
    ObjectUnref = proc (o: pointer) {.cdecl.}
    ListFree = proc (l: ptr GList) {.cdecl.}
    CollectionForAlias = proc (service: pointer, alias: cstring, flags: cint, cancellable: pointer,
      error: ptr ptr GError): pointer {.cdecl.}
    CollectionGetLocked = proc (collection: pointer): cint {.cdecl.}
    ServiceUnlock = proc (service: pointer, objects: ptr GList, cancellable: pointer, unlocked: ptr ptr GList,
      error: ptr ptr GError): cint {.cdecl.}
    GList = object
      data: pointer
      next, prev: ptr GList

  var
    loaded = false
    lookupV: LookupV
    storeV: StoreV
    passwordFree: PasswordFree
    serviceGet: ServiceGet
    serviceSearch: ServiceSearch
    itemGetLocked: ItemGetLocked
    objectUnref: ObjectUnref
    listFree: ListFree
    collectionForAlias: CollectionForAlias
    collectionGetLocked: CollectionGetLocked
    serviceUnlock: ServiceUnlock
    schema = SecretSchema(name: "dev.webby.Vault")

  proc load(): bool =
    if loaded: return lookupV != nil
    loaded = true
    let lib = loadLib("libsecret-1.so.0")
    if lib == nil: return false
    lookupV = cast[LookupV](lib.symAddr("secret_password_lookupv_sync"))
    storeV = cast[StoreV](lib.symAddr("secret_password_storev_sync"))
    passwordFree = cast[PasswordFree](lib.symAddr("secret_password_free"))
    # Only for telling a locked item from a missing one; optional.
    serviceGet = cast[ServiceGet](lib.symAddr("secret_service_get_sync"))
    serviceSearch = cast[ServiceSearch](lib.symAddr("secret_service_search_sync"))
    itemGetLocked = cast[ItemGetLocked](lib.symAddr("secret_item_get_locked"))
    objectUnref = cast[ObjectUnref](lib.symAddr("g_object_unref"))
    listFree = cast[ListFree](lib.symAddr("g_list_free"))
    collectionForAlias = cast[CollectionForAlias](lib.symAddr("secret_collection_for_alias_sync"))
    collectionGetLocked = cast[CollectionGetLocked](lib.symAddr("secret_collection_get_locked"))
    serviceUnlock = cast[ServiceUnlock](lib.symAddr("secret_service_unlock_sync"))
    if lookupV == nil or storeV == nil or passwordFree == nil:
      lookupV = nil
      return false
    schema.attributes[0] = SchemaAttribute(name: "application", kind: 0)
    schema.attributes[1] = SchemaAttribute(name: "profile", kind: 0)
    true

  proc attributes(profile: string): pointer =
    result = g_hash_table_new(cast[pointer](g_str_hash), cast[pointer](g_str_equal))
    discard g_hash_table_insert(result, cstring"application", cstring"webby")
    discard g_hash_table_insert(result, cstring"profile", profile.cstring)

  proc raiseFrom(error: ptr GError, fallback: string) =
    let message = if error != nil and error.message != nil: $error.message else: fallback
    if error != nil: g_error_free(error)
    raise newException(KeyringError, message)

  proc canInspect(): bool =
    serviceGet != nil and serviceSearch != nil and itemGetLocked != nil and objectUnref != nil and listFree != nil and
      collectionForAlias != nil and collectionGetLocked != nil and serviceUnlock != nil

  proc withService(body: proc (service: pointer)) =
    var error: ptr GError
    let service = serviceGet(0, nil, addr error)
    if error != nil: g_error_free(error)
    if service == nil: return
    body(service)
    objectUnref(service)

  proc withDefaultCollection(service: pointer, body: proc (collection: pointer)) =
    var error: ptr GError
    let collection = collectionForAlias(service, "default", 0, nil, addr error)
    if error != nil: g_error_free(error)
    if collection == nil: return
    body(collection)
    objectUnref(collection)

  proc keyringLocked*(profile: string): bool =
    ## Whether the profile's key may be in a locked collection: a matching item is locked, or the default collection
    ## (where it is stored) is. Some keyrings (oo7) don't match attributes of items in a locked collection at all.
    if not load() or not canInspect(): return false
    var locked = false
    withService proc (service: pointer) =
      let attrs = attributes(profile)
      const searchAll = 1 shl 1   # SECRET_SEARCH_ALL, without SECRET_SEARCH_UNLOCK
      var error: ptr GError
      let items = serviceSearch(service, addr schema, attrs, searchAll, nil, addr error)
      g_hash_table_unref(attrs)
      if error != nil: g_error_free(error)
      var node = items
      while node != nil:
        if itemGetLocked(node.data) != 0: locked = true
        objectUnref(node.data)
        node = node.next
      if items != nil: listFree(items)
      withDefaultCollection(service, proc (collection: pointer) =
        if collectionGetLocked(collection) != 0: locked = true)
    locked

  proc unlockDefaultCollection(): bool =
    ## Asks the keyring to unlock its default collection (it shows its own password prompt). True if it did.
    var unlockedAny = false
    withService proc (service: pointer) =
      withDefaultCollection(service, proc (collection: pointer) =
        if collectionGetLocked(collection) == 0: return
        var objects = GList(data: collection)
        var unlocked: ptr GList
        var error: ptr GError
        let n = serviceUnlock(service, addr objects, nil, addr unlocked, addr error)
        if error != nil:
          stderr.writeLine "webby: the keyring didn't unlock: ", (if error.message != nil: $error.message else: "")
          g_error_free(error)
        var node = unlocked
        while node != nil:
          objectUnref(node.data)
          node = node.next
        if unlocked != nil: listFree(unlocked)
        unlockedAny = n > 0)
    unlockedAny

  proc lookupOnce(profile: string): (bool, string) =
    var error: ptr GError
    let attrs = attributes(profile)
    let secret = lookupV(addr schema, attrs, nil, addr error)
    g_hash_table_unref(attrs)
    if error != nil:
      if secret != nil: passwordFree(secret)
      raiseFrom(error, "")
    if secret == nil: return (false, "")
    result = (true, $secret)
    passwordFree(secret)   # libsecret wipes it

  proc keyringLookup*(profile: string): (bool, string) =
    ## (found, secret). Raises KeyringError when the keyring can't be reached. When nothing is found and the default
    ## collection is locked, asks the keyring to unlock it and looks again: libsecret only unlocks items its search
    ## matched, and some keyrings (oo7) match nothing in a locked collection.
    if not load(): raise newException(KeyringError, "libsecret-1.so.0 not found")
    result = lookupOnce(profile)
    if not result[0] and canInspect() and unlockDefaultCollection(): result = lookupOnce(profile)

  proc keyringStore*(profile, secret: string) =
    if not load(): raise newException(KeyringError, "libsecret-1.so.0 not found")
    var error: ptr GError
    let attrs = attributes(profile)
    let ok = storeV(addr schema, attrs, "default", cstring("Webby password vault (" & profile & ")"), secret.cstring,
      nil, addr error)
    g_hash_table_unref(attrs)
    if error != nil or ok == 0: raiseFrom(error, "The keyring refused the request")

