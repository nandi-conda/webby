## The profile's open Vault and the passkeys in it (password_manager.dart's PasswordManager): libwebby's
## authenticator keeps passkeys in memory (webby_passkeys_use_vault) and the vault saves them whenever they change.

import std/json
import ../../[base, ffi]
import vault

var
  theVault*: Vault           ## nil until opened, or when it couldn't be
  vaultError*: string        ## why it couldn't be opened
  passkeysInVault*: bool     ## the authenticator's passkeys live in the vault (else in its own passkeys.json)
  passkeySerial: uint64
  vaultOpenHooks*: seq[proc ()]  ## run once the vault opens (at start, or on a later retryVault)

proc exportPasskeys(): seq[JsonNode] =
  try:
    for p in parseJson(str(webby_passkeys_export())).getElems:
      if p.kind == JObject: result.add p
  except CatchableError: discard

proc usePasskeyVault(passkeys: seq[JsonNode]): bool =
  webby_passkeys_use_vault(cstring($(%passkeys))) == 0

proc syncPasskeys*() =
  ## Saves the authenticator's passkeys into the vault if they changed.
  if theVault == nil or not passkeysInVault: return
  let serial = webby_passkeys_serial()
  if serial == passkeySerial: return
  passkeySerial = serial
  theVault.setPasskeys(exportPasskeys())

proc passkeysSynced*(removed: seq[string]) =
  ## Hands passkeys that came in from another device to the authenticator and takes away ones deleted elsewhere
  ## (call after applySyncDoc returned true).
  if theVault == nil or not passkeysInVault: return
  for id in removed: discard webby_passkeys_remove(id.cstring)
  discard usePasskeyVault(theVault.passkeys)
  passkeySerial = high(uint64)   # save whatever the authenticator ends up with on the next tick

proc deletePasskey*(credentialId: string) =
  if not passkeysInVault: return
  discard webby_passkeys_remove(credentialId.cstring)
  syncPasskeys()

proc startManager*() =
  ## Opens the vault once Ladybird is up and moves passkeys into it. Incognito windows fill from an existing vault
  ## but never write it, and their passkeys live only in the authenticator's memory.
  if incognito:
    try:
      if vaultExists(): theVault = openVault(readOnly = true)
    except CatchableError as e:
      stderr.writeLine "webby: incognito window without saved passwords: ", e.msg
    discard usePasskeyVault(if theVault != nil: theVault.passkeys else: @[])
    return
  try:
    theVault = openVault()
  except VaultUnavailable as e:
    vaultError = e.msg
  except CatchableError as e:
    vaultError = "Could not open the password vault: " & e.msg
  if theVault == nil:
    stderr.writeLine "webby: ", vaultError
    return
  vaultError = ""
  for h in vaultOpenHooks: h()
  if not usePasskeyVault(theVault.passkeys): return
  # The authenticator now has the vault's passkeys plus any from the old file. Save that, then drop the file.
  passkeysInVault = true
  passkeySerial = webby_passkeys_serial()
  theVault.setPasskeys(exportPasskeys())
  if webby_passkeys_delete_file() != 0: stderr.writeLine "webby: could not delete the old passkeys file"
  # Passkeys are made inside libwebby during a sign-up; save them as soon as they appear.
  proc tick() =
    syncPasskeys()
    discard startTimer(250, tick)
  discard startTimer(250, tick)

proc retryVault*() =
  ## Tries to open the vault again after it couldn't be (say the keyring was locked and has been unlocked since).
  if theVault != nil or incognito: return
  startManager()
