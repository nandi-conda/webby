## The sync key, the code devices pair with, and the encryption of what goes to the server
## (app/lib/src/passwords/sync/sync_crypto.dart, same algorithms and formats):
##   code: "webby1-" + base32(key ‖ CRC-16/CCITT(key)) in groups of five
##   HKDF-SHA256(key, salt "webby-sync-v1", info) → blob ids (hex), auth token (base64url, unpadded), AES key
##   blob: {"format":"webby-sync","version":1,"nonce","data","mac"} around AES-256-GCM(canonical doc, AAD "webby-sync-v1")

import std/[base64, dynlib, json, os, strutils]
import ../passwords/crypto
import doc

const
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  codePrefix = "webby1"
  version = "webby-sync-v1"

type
  BadSyncCode* = object of CatchableError      ## mistyped, cut short, or not a sync code
  SyncDecryptError* = object of CatchableError ## the server's copy can't be read with this key

  SyncKeys* = object
    blobId*, bookmarksBlobId*, tabsBlobId*, summariesBlobId*, sessionsBlobId*: string  ## 64 hex characters each
    authToken*: string       ## Bearer token for the webby-sync server, which keeps only its hash
    encryptionKey*: string   ## 32 bytes

# ---------------------------------------------------------------------------------------------------------------
# HMAC-SHA256 from the runtime's libcrypto (loaded lazily, like passwords/crypto.nim)

var
  hmacFn: proc (md: pointer, key: pointer, keyLen: cint, data: pointer, dataLen: csize_t, output: pointer,
                outLen: ptr cuint): pointer {.cdecl.}
  sha256Fn: proc (): pointer {.cdecl.}

proc loadHmac() =
  if hmacFn != nil: return
  var lib: LibHandle
  let runtime = getEnv("WEBBY_LADYBIRD_PREFIX")
  for name in [(if runtime.len > 0: runtime / "lib" / "libcrypto.so.3" else: ""), "libcrypto.so.3", "libcrypto.so",
      (when defined(android): "libwebby.so" else: "")]:
    if name.len == 0: continue
    lib = loadLib(name)
    if lib != nil: break
  if lib == nil: raise newException(CryptoError, "libcrypto not found")
  hmacFn = cast[typeof(hmacFn)](lib.symAddr("HMAC"))
  sha256Fn = cast[typeof(sha256Fn)](lib.symAddr("EVP_sha256"))
  if hmacFn == nil or sha256Fn == nil: raise newException(CryptoError, "libcrypto lacks HMAC")

proc hmacSha256*(key, data: string): string =
  loadHmac()
  result = newString(32)
  var n: cuint
  let k = if key.len > 0: unsafeAddr key[0] else: nil
  let d = if data.len > 0: unsafeAddr data[0] else: nil
  if hmacFn(sha256Fn(), k, key.len.cint, d, data.len.csize_t, addr result[0], addr n) == nil or n != 32:
    raise newException(CryptoError, "HMAC failed")

proc hkdf32*(ikm, salt, info: string): string =
  ## RFC 5869 HKDF-SHA256 with 32 bytes out (one block).
  hmacSha256(hmacSha256(salt, ikm), info & "\x01")

# ---------------------------------------------------------------------------------------------------------------
# Codes

proc base32Encode(bytes: string): string =
  var buffer, bits = 0
  for c in bytes:
    buffer = (buffer shl 8) or ord(c)
    bits += 8
    while bits >= 5:
      result.add alphabet[(buffer shr (bits - 5)) and 31]
      bits -= 5
    buffer = buffer and ((1 shl bits) - 1)
  if bits > 0: result.add alphabet[(buffer shl (5 - bits)) and 31]

proc base32Decode(text: string): (bool, string) =
  var buffer, bits = 0
  var output = ""
  for c in text:
    let v = alphabet.find(c)
    if v < 0: return (false, "")
    buffer = (buffer shl 5) or v
    bits += 5
    if bits >= 8:
      output.add chr((buffer shr (bits - 8)) and 0xFF)
      bits -= 8
    buffer = buffer and ((1 shl bits) - 1)
  (true, output)

proc check(key: string): string =
  # CRC-16/CCITT: plenty for catching typos.
  var crc = 0xFFFF
  for c in key:
    crc = crc xor (ord(c) shl 8)
    for _ in 0 ..< 8:
      crc = if (crc and 0x8000) != 0: ((crc shl 1) xor 0x1021) and 0xFFFF else: (crc shl 1) and 0xFFFF
  chr(crc shr 8) & chr(crc and 0xFF)

proc codeFor*(key: string): string =
  ## The key as webby1-XXXXX-XXXXX-…
  let text = base32Encode(key & check(key))
  result = codePrefix
  var i = 0
  while i < text.len:
    result.add "-" & text[i ..< min(i + 5, text.len)]
    i += 5

proc generateCode*(): string = codeFor(randomBytes(32))

proc keyFromCode*(text: string): string =
  ## The 32 key bytes of a code, ignoring case, spaces and dashes and taking 0/1/8 for O/I/B. Raises BadSyncCode.
  var cleaned = ""
  for c in text.toUpperAscii:
    if c notin Whitespace and c != '-': cleaned.add c
  if cleaned.startsWith(codePrefix.toUpperAscii): cleaned = cleaned[codePrefix.len .. ^1]
  cleaned = cleaned.multiReplace(("0", "O"), ("1", "I"), ("8", "B"))
  if cleaned.len != 55: raise newException(BadSyncCode, "That sync code is the wrong length.")
  let (ok, bytes) = base32Decode(cleaned)
  if not ok or bytes.len < 34: raise newException(BadSyncCode, "That isn't a sync code.")
  result = bytes[0 ..< 32]
  if bytes[32 .. 33] != check(result): raise newException(BadSyncCode, "That sync code has a typo in it.")

proc normalizeCode*(text: string): string = codeFor(keyFromCode(text))

# ---------------------------------------------------------------------------------------------------------------
# Keys and blobs

proc hex(s: string): string = s.toHex.toLowerAscii

proc deriveKeys*(code: string): SyncKeys =
  let key = keyFromCode(code)
  proc part(info: string): string = hkdf32(key, version, info)
  SyncKeys(blobId: hex(part("id")), bookmarksBlobId: hex(part("id-bookmarks")), tabsBlobId: hex(part("id-tabs")),
    summariesBlobId: hex(part("id-summaries")), sessionsBlobId: hex(part("id-sessions")),
    authToken: encode(part("auth"), safe = true).strip(leading = false, chars = {'='}),
    encryptionKey: part("enc"))

proc seal*(keys: SyncKeys, d: JsonNode): string =
  ## The encrypted envelope of a doc, as the server stores it.
  let box = crypto.seal(keys.encryptionKey, canonical(d), version)
  dartJson(%*{"format": "webby-sync", "version": 1, "nonce": encode(box.nonce), "data": encode(box.cipherText),
    "mac": encode(box.mac)})

proc open*(keys: SyncKeys, sealed: string): JsonNode =
  ## The doc in an envelope. Raises SyncDecryptError.
  var envelope: JsonNode
  try: envelope = parseJson(sealed)
  except CatchableError: raise newException(SyncDecryptError, "The synced data on the server is damaged.")
  if envelope.kind != JObject or envelope{"format"}.getStr != "webby-sync":
    raise newException(SyncDecryptError, "The server has something else stored.")
  if envelope{"version"} == nil or envelope["version"].kind != JInt or envelope["version"].getInt != 1:
    raise newException(SyncDecryptError,
      "Another device synced with a newer webby. Update webby here to keep syncing.")
  var clear: string
  try:
    let box = (nonce: decode(envelope{"nonce"}.getStr), cipherText: decode(envelope{"data"}.getStr),
               mac: decode(envelope{"mac"}.getStr))
    clear = unseal(keys.encryptionKey, box, version)
  except CryptoError:
    raise newException(SyncDecryptError, "The synced data doesn't match this sync code.")
  except CatchableError as e:
    raise newException(SyncDecryptError, "The synced data on the server is damaged (" & e.msg & ").")
  try: docFromJson(parseJson(clear))
  except CatchableError as e:
    raise newException(SyncDecryptError, "The synced data on the server is damaged (" & e.msg & ").")
