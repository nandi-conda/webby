## One profile's encrypted store of passwords, passkeys and secrets: a port of
## app/lib/src/passwords/vault.dart that reads and writes the same file, so a profile works in both front ends.
##
## On disk: `${XDG_DATA_HOME:-~/.local/share}/webby/profiles/<profile>/vault.json` (or $WEBBY_VAULT_FILE), a JSON
## envelope {format: "webby-vault", version: 1, cipher: "AES-256-GCM", nonce, data, mac} (base64; 12-byte nonce,
## 16-byte tag, AAD "webby-vault-v1") around the JSON contents. The 256-bit key is random, base64 in the desktop
## keyring under {application: webby, profile: <profile>}, or in `vault.key` beside the vault when there is no
## keyring ($WEBBY_VAULT_KEYRING=0 forces the file).
##
## API for sync (passwords/sync in the Dart app does the same on top of Vault):
##   openVault(readOnly), vaultExists(), v.save(), v.onChange (listeners, run after every change)
##   v.passwords / passwordsFor / find / savePassword / updatePassword / deletePassword
##   v.neverSave / isNeverSave / setNeverSave, v.passkeys / setPasskeys, secret / setSecret / secretSyncs
##   v.secretsSyncDoc() / applySecretsSyncDoc(doc): the secrets that sync ({"secrets": {name: {value, updatedAt}}}),
##     in their own blob; names in localSecrets stay on this device
##   v.syncSettings / setSyncSettings: the "sync" object of the contents, kept as raw JSON (SyncSettings in Dart)
##   v.toSyncDoc(): {"passwords": {id: record}, "passkeys": {credentialId: record}, "neverSave": {origin: record}},
##     records carry "updatedAt" (seconds) and deletions are tombstones {"updatedAt", "deleted": true}, like SyncDoc
##   v.applySyncDoc(doc): replaces the contents with a merged doc of that shape; true if the passkeys changed (hand
##     them to the authenticator then, see passwords.passkeysSynced)

import std/[algorithm, base64, json, os, sequtils, strutils, tables, times, uri]
import crypto, keyring

type
  SavedPassword* = ref object
    id*: string
    origin*: string      ## scheme://host[:port] of the page it was saved on; only offered there
    username*, password*: string
    createdAt*, updatedAt*: int64  ## seconds since the epoch

  KeyStore* = enum
    ksKeyring  ## the desktop keyring, the normal case
    ksFile     ## vault.key next to the vault, readable only by the user

  VaultUnavailable* = object of CatchableError  ## nothing is read or written until the cause is fixed

  Vault* = ref object
    profile*, path*: string
    keyStore*: KeyStore
    readOnly*: bool       ## incognito: changes stay in memory
    key: string
    passwords*: seq[SavedPassword]
    neverSave*: seq[string]                  ## sorted
    neverSaveAt*: OrderedTable[string, int64]
    passkeys*: seq[JsonNode]                 ## the authenticator's JSON (webby_passkeys_export), as is
    deleted*: OrderedTable[string, OrderedTable[string, int64]]  ## section -> key -> when deleted
    syncSettings*: JsonNode                  ## nil when sync is off
    secrets: OrderedTable[string, string]
    secretsAt: OrderedTable[string, int64]   ## when each secret was set (seconds), for sync
    localSecrets: seq[string]                 ## secrets that never sync (sorted)
    onChange*: seq[proc ()]

const aad = "webby-vault-v1"
const sections = ["passwords", "passkeys", "neverSave"]
const deletedSections = ["passwords", "passkeys", "neverSave", "secrets"]  ## sections of "deleted"

proc now(): int64 = getTime().toUnix

proc originOf*(url: string): string =
  ## The canonical origin of a page URL, or "" for pages that can't have saved passwords (about:, file:, data:...).
  try:
    let u = parseUri(url)
    let scheme = u.scheme.toLowerAscii
    if scheme notin ["http", "https"] or u.hostname.len == 0: return ""
    let host = u.hostname.toLowerAscii
    result = scheme & "://" & (if ':' in host: "[" & host & "]" else: host)
    if u.port.len > 0 and not (scheme == "http" and u.port == "80" or scheme == "https" and u.port == "443"):
      result.add ":" & u.port
  except CatchableError: result = ""

proc hostOf*(origin: string): string =
  try: parseUri(origin).hostname except CatchableError: origin

# ---------------------------------------------------------------------------------------------------------------
# Files

proc profileName(): string =
  let name = getEnv("WEBBY_PROFILE")
  # Profile names become directory names.
  if name.len > 0 and name.allIt(it in {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}) and name notin [".", ".."]: name
  else: "default"

proc dataHome(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  if xdg.len > 0: xdg else: getEnv("HOME", "/tmp") / ".local" / "share"

proc vaultFile*(): string =
  let override = getEnv("WEBBY_VAULT_FILE")
  if override.len > 0: override else: dataHome() / "webby" / "profiles" / profileName() / "vault.json"

proc vaultExists*(): bool = fileExists(vaultFile())

proc writePrivate(path, content: string) =
  ## Atomically, readable only by the user.
  let tmp = path & ".tmp"
  writeFile(tmp, "")
  setFilePermissions(tmp, {fpUserRead, fpUserWrite})
  writeFile(tmp, content)
  moveFile(tmp, path)

# ---------------------------------------------------------------------------------------------------------------
# Contents

proc toJson*(p: SavedPassword): JsonNode =
  %*{"id": p.id, "origin": p.origin, "username": p.username, "password": p.password,
     "createdAt": p.createdAt, "updatedAt": p.updatedAt}

proc passwordFromJson*(j: JsonNode): SavedPassword =
  SavedPassword(id: j["id"].getStr, origin: j["origin"].getStr, username: j{"username"}.getStr,
    password: j{"password"}.getStr, createdAt: j{"createdAt"}.getBiggestInt, updatedAt: j{"updatedAt"}.getBiggestInt)

proc load(v: Vault, contents: JsonNode) =
  for s in sections: v.deleted[s] = initOrderedTable[string, int64]()
  v.deleted["secrets"] = initOrderedTable[string, int64]()
  for e in contents{"passwords"}.getElems:
    if e.kind == JObject and e{"id"}.kind == JString and e{"origin"}.kind == JString:
      v.passwords.add passwordFromJson(e)
  for o in contents{"neverSave"}.getElems:
    if o.kind == JString and o.getStr notin v.neverSave: v.neverSave.add o.getStr
  v.neverSave.sort
  for p in contents{"passkeys"}.getElems:
    if p.kind == JObject: v.passkeys.add p
  for k, t in contents{"neverSaveAt"}.getFields:
    if t.kind == JInt: v.neverSaveAt[k] = t.getBiggestInt
  let deleted = contents{"deleted"}
  if deleted != nil and deleted.kind == JObject:
    for s in deletedSections:
      for k, t in deleted{s}.getFields:
        if t.kind == JInt: v.deleted[s][k] = t.getBiggestInt
  for k, s in contents{"secrets"}.getFields:
    if s.kind == JString: v.secrets[k] = s.getStr
  for k, t in contents{"secretsAt"}.getFields:
    if t.kind == JInt: v.secretsAt[k] = t.getBiggestInt
  for n in contents{"localSecrets"}.getElems:
    if n.kind == JString and n.getStr notin v.localSecrets: v.localSecrets.add n.getStr
  v.localSecrets.sort
  let sync = contents{"sync"}
  if sync != nil and sync.kind == JObject: v.syncSettings = sync

proc contents(v: Vault): JsonNode =
  result = %*{"version": 1, "passwords": newJArray(), "neverSave": %v.neverSave, "neverSaveAt": newJObject(),
    "passkeys": %v.passkeys, "deleted": newJObject()}
  for p in v.passwords: result["passwords"].add p.toJson
  for k, t in v.neverSaveAt: result["neverSaveAt"][k] = %t
  for s in deletedSections:
    let section = newJObject()
    for k, t in v.deleted[s]: section[k] = %t
    result["deleted"][s] = section
  if v.syncSettings != nil: result["sync"] = v.syncSettings
  if v.secrets.len > 0:
    let secrets = newJObject()
    for k, s in v.secrets: secrets[k] = %s
    result["secrets"] = secrets
  if v.secretsAt.len > 0:
    let at = newJObject()
    for k, t in v.secretsAt: at[k] = %t
    result["secretsAt"] = at
  if v.localSecrets.len > 0: result["localSecrets"] = %v.localSecrets

proc encryptVault*(key: string, contents: JsonNode): string =
  ## The envelope vault.json holds.
  let box = seal(key, $contents, aad)
  $(%*{"format": "webby-vault", "version": 1, "cipher": "AES-256-GCM", "nonce": encode(box.nonce),
       "data": encode(box.cipherText), "mac": encode(box.mac)})

proc decryptVault*(key, text: string): JsonNode =
  var envelope: JsonNode
  try:
    envelope = parseJson(text)
  except CatchableError as e:
    raise newException(VaultUnavailable, "The password vault is damaged (" & e.msg & ").")
  if envelope.kind != JObject or envelope{"format"}.getStr != "webby-vault" or envelope{"version"}.getInt != 1:
    raise newException(VaultUnavailable, "The password vault was written by a newer webby.")
  var clear: string
  try:
    clear = unseal(key, (decode(envelope["nonce"].getStr), decode(envelope["data"].getStr),
      decode(envelope["mac"].getStr)), aad)
  except CryptoError as e:
    if e.msg == "authentication failed":
      raise newException(VaultUnavailable, "The password vault doesn't match the key in the keyring.")
    raise newException(VaultUnavailable, "The password vault is damaged (" & e.msg & ").")
  except CatchableError as e:
    raise newException(VaultUnavailable, "The password vault is damaged (" & e.msg & ").")
  try:
    result = parseJson(clear)
  except CatchableError as e:
    raise newException(VaultUnavailable, "The password vault is damaged (" & e.msg & ").")
  if result.kind != JObject: raise newException(VaultUnavailable, "The password vault is damaged.")

proc save*(v: Vault) =
  ## Writes the vault now (a no-op when read-only). Errors are logged, not raised.
  if v.readOnly: return
  try:
    writePrivate(v.path, encryptVault(v.key, v.contents))
  except CatchableError as e:
    stderr.writeLine "webby: could not save the password vault: ", e.msg

proc notify*(v: Vault) =
  for h in v.onChange: h()

proc changed(v: Vault) =
  v.save()
  v.notify()

# ---------------------------------------------------------------------------------------------------------------
# Opening

proc openVault*(readOnly = false): Vault =
  ## Opens (or creates) the vault of the current profile ($WEBBY_PROFILE, default "default"). Raises VaultUnavailable.
  let profile = profileName()
  let file = vaultFile()
  let dir = file.parentDir
  createDir(dir)
  try: setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec}) except CatchableError: discard
  let keyFile = dir / "vault.key"

  var keyringError = ""
  var encodedKey = ""
  var found = false
  var keyStore = ksKeyring
  if getEnv("WEBBY_VAULT_KEYRING") != "0":
    try:
      (found, encodedKey) = keyringLookup(profile)
    except KeyringError as e:
      keyringError = if e.msg.len > 0: e.msg else: "unavailable"
  else:
    keyringError = "disabled by WEBBY_VAULT_KEYRING=0"

  if not found and fileExists(keyFile):
    encodedKey = readFile(keyFile).strip
    found = true
    keyStore = ksFile
    # A keyring has turned up since the key was written to a file: move the key into it.
    if keyringError.len == 0 and not readOnly:
      try:
        keyringStore(profile, encodedKey)
        removeFile(keyFile)
        keyStore = ksKeyring
      except CatchableError as e:
        stderr.writeLine "webby: keeping the vault key in ", keyFile, ": ", e.msg

  if not found:
    if fileExists(file):
      # Never replace a vault we can't read with an empty one.
      raise newException(VaultUnavailable, if keyringError.len > 0:
        "The password vault at " & file & " is locked: its key is in the keyring, which isn't reachable (" &
          keyringError & ")."
      else: "The key for the password vault at " & file & " is missing from the keyring.")
    encodedKey = encode(randomBytes(32))
    if keyringError.len == 0:
      try: keyringStore(profile, encodedKey)
      except CatchableError as e: keyringError = e.msg
    if keyringError.len > 0:
      stderr.writeLine "webby: no keyring (", keyringError, "); keeping the vault key in ", keyFile
      writePrivate(keyFile, encodedKey)
      keyStore = ksFile

  var key: string
  try: key = decode(encodedKey) except CatchableError: discard
  if key.len != 32: raise newException(VaultUnavailable, "The password vault key is damaged.")

  result = Vault(profile: profile, path: file, keyStore: keyStore, readOnly: readOnly, key: key)
  let existed = fileExists(file)
  result.load(if existed: decryptVault(key, readFile(file)) else: newJObject())
  if not existed: result.save()

# ---------------------------------------------------------------------------------------------------------------
# Passwords

proc passwordsFor*(v: Vault, origin: string): seq[SavedPassword] =
  ## Newest first.
  for p in v.passwords:
    if p.origin == origin: result.add p
  result.sort(proc (a, b: SavedPassword): int = cmp(b.updatedAt, a.updatedAt))

proc find*(v: Vault, origin, username: string): SavedPassword =
  for p in v.passwords:
    if p.origin == origin and p.username == username: return p

proc newId(): string = randomBytes(16).toHex.toLowerAscii

proc savePassword*(v: Vault, origin, username, password: string): SavedPassword {.discardable.} =
  ## Saves a password, replacing the one for the same site and username.
  result = v.find(origin, username)
  if result != nil:
    result.password = password
    result.updatedAt = now()
  else:
    result = SavedPassword(id: newId(), origin: origin, username: username, password: password,
      createdAt: now(), updatedAt: now())
    v.passwords.add result
  v.changed()

proc updatePassword*(v: Vault, entry: SavedPassword, origin, username, password: string) =
  entry.origin = origin
  entry.username = username
  entry.password = password
  entry.updatedAt = now()
  v.changed()

proc deletePassword*(v: Vault, entry: SavedPassword) =
  for i in countdown(v.passwords.high, 0):
    if v.passwords[i].id == entry.id: v.passwords.delete(i)
  v.deleted["passwords"][entry.id] = now()
  v.changed()

proc isNeverSave*(v: Vault, origin: string): bool = origin in v.neverSave

proc setNeverSave*(v: Vault, origin: string, never: bool) =
  if never == v.isNeverSave(origin): return
  if never:
    v.neverSave.add origin
    v.neverSave.sort
    v.neverSaveAt[origin] = now()
    v.deleted["neverSave"].del origin
  else:
    v.neverSave.delete(v.neverSave.find(origin))
    v.neverSaveAt.del origin
    v.deleted["neverSave"][origin] = now()
  v.changed()

# ---------------------------------------------------------------------------------------------------------------
# Passkeys, secrets, sync settings

proc setPasskeys*(v: Vault, passkeys: seq[JsonNode]) =
  ## Replaces the stored passkeys with the authenticator's current list (see webby_passkeys_export).
  var kept: seq[string]
  for p in passkeys: kept.add p{"credentialId"}.getStr
  for old in v.passkeys:
    let id = old{"credentialId"}
    if id != nil and id.kind == JString and id.getStr notin kept: v.deleted["passkeys"][id.getStr] = now()
  for id in kept: v.deleted["passkeys"].del id
  v.passkeys = passkeys
  v.changed()

proc secret*(v: Vault, name: string): string =
  ## The secret stored as `name`, or "".
  v.secrets.getOrDefault(name)

proc secretSyncs*(v: Vault, name: string): bool =
  ## Whether the secret syncs to the other devices (when sync is on); they do unless the user said not to.
  name notin v.localSecrets

proc setSecret*(v: Vault, name, value: string, sync: bool) =
  ## Stores (or with "" removes) a secret and sets whether it syncs. A synced secret's removal reaches the other
  ## devices too.
  let wasSyncing = v.secretSyncs(name)
  if sync and not wasSyncing: v.localSecrets.delete(v.localSecrets.find(name))
  elif not sync and wasSyncing: (v.localSecrets.add name; v.localSecrets.sort)
  let had = name in v.secrets
  let old = v.secrets.getOrDefault(name)
  if value.len == 0:
    if not had and sync == wasSyncing: return
    v.secrets.del name
    v.secretsAt.del name
    if had and sync: v.deleted["secrets"][name] = now()
  else:
    if had and old == value and sync == wasSyncing: return
    if not had or old != value or sync:
      # A new value, or one starting to sync: the newest copy wins on the other devices.
      v.secrets[name] = value
      v.secretsAt[name] = now()
      v.deleted["secrets"].del name
  v.changed()

proc setSecret*(v: Vault, name, value: string) =
  ## Stores (or with "" removes) a secret, keeping whether it syncs.
  v.setSecret(name, value, v.secretSyncs(name))

proc setSyncSettings*(v: Vault, settings: JsonNode) =
  v.syncSettings = settings
  v.changed()

# ---------------------------------------------------------------------------------------------------------------
# Sync form (SyncDoc's vault sections)

proc isDeleted*(record: JsonNode): bool = record{"deleted"}.getBool
proc updatedAtOf*(record: JsonNode): int64 =
  let t = record{"updatedAt"}
  if t == nil: 0'i64 elif t.kind == JInt: t.getBiggestInt elif t.kind == JFloat: t.getFloat.int64 else: 0'i64

proc toSyncDoc*(v: Vault): JsonNode =
  ## The vault's contents in their synced form (secrets stay out).
  proc tombstone(at: int64, id = ""): JsonNode =
    result = newJObject()
    if id.len > 0: result["id"] = %id
    result["updatedAt"] = %at
    result["deleted"] = %true
  result = %*{"passwords": {}, "passkeys": {}, "neverSave": {}}
  for id, at in v.deleted["passwords"]: result["passwords"][id] = tombstone(at, id)
  for p in v.passwords: result["passwords"][p.id] = p.toJson
  for id, at in v.deleted["passkeys"]: result["passkeys"][id] = tombstone(at)
  for p in v.passkeys:
    if p{"credentialId"}.kind == JString:
      let r = p.copy
      r["updatedAt"] = %p{"createdAt"}.getBiggestInt
      result["passkeys"][p["credentialId"].getStr] = r
  for o, at in v.deleted["neverSave"]: result["neverSave"][o] = tombstone(at)
  for o in v.neverSave: result["neverSave"][o] = %*{"updatedAt": v.neverSaveAt.getOrDefault(o)}

proc applySyncDoc*(v: Vault, doc: JsonNode): bool =
  ## Replaces the contents with a merged doc; returns whether the set of passkeys changed.
  var before: seq[string]
  for p in v.passkeys: before.add p{"credentialId"}.getStr
  v.passwords.setLen 0
  for _, r in doc{"passwords"}.getFields:
    if not r.isDeleted and r{"id"}.kind == JString and r{"origin"}.kind == JString: v.passwords.add passwordFromJson(r)
  v.neverSave.setLen 0
  v.neverSaveAt.clear
  for o, r in doc{"neverSave"}.getFields:
    if not r.isDeleted:
      v.neverSave.add o
      v.neverSaveAt[o] = updatedAtOf(r)
  v.neverSave.sort
  v.passkeys.setLen 0
  for _, r in doc{"passkeys"}.getFields:
    if not r.isDeleted and r{"credentialId"}.kind == JString:
      let p = r.copy
      if p.hasKey("updatedAt"): p.delete("updatedAt")
      v.passkeys.add p
  for s in sections:
    v.deleted[s] = initOrderedTable[string, int64]()
    for k, r in doc{s}.getFields:
      if r.isDeleted: v.deleted[s][k] = updatedAtOf(r)
  v.changed()
  var after: seq[string]
  for p in v.passkeys: after.add p{"credentialId"}.getStr
  before.len != after.len or after.anyIt(it notin before)

proc secretsSyncDoc*(v: Vault): JsonNode =
  ## The secrets that sync, in their synced form: {"secrets": {name: {value, updatedAt}}}, plus removals.
  result = %*{"secrets": {}}
  for name, at in v.deleted["secrets"]:
    if name notin v.localSecrets: result["secrets"][name] = %*{"updatedAt": at, "deleted": true}
  for name, value in v.secrets:
    if name notin v.localSecrets:
      result["secrets"][name] = %*{"value": value, "updatedAt": v.secretsAt.getOrDefault(name)}

proc applySecretsSyncDoc*(v: Vault, doc: JsonNode) =
  ## Takes in merged synced secrets; the ones kept on this device only are left alone.
  var changed = false
  var kept: seq[string]
  for name, r in doc{"secrets"}.getFields:
    if name in v.localSecrets or r.kind != JObject: continue
    let at = updatedAtOf(r)
    if r.isDeleted:
      kept.add name
      if name in v.secrets: (v.secrets.del name; changed = true)
      v.secretsAt.del name
      if v.deleted["secrets"].getOrDefault(name, -1) != at: (v.deleted["secrets"][name] = at; changed = true)
    elif r{"value"}.kind == JString and r["value"].getStr.len > 0:
      let value = r["value"].getStr
      if v.secrets.getOrDefault(name) != value or v.secretsAt.getOrDefault(name, -1) != at: changed = true
      v.secrets[name] = value
      v.secretsAt[name] = at
      v.deleted["secrets"].del name
  # Removals too old to remember dropped out of the merged copy.
  var expired: seq[string]
  for name in v.deleted["secrets"].keys:
    if name notin kept and name notin v.localSecrets: expired.add name
  for name in expired: (v.deleted["secrets"].del name; changed = true)
  if changed: v.changed()
