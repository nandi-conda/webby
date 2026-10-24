## Web Push message encryption (RFC 8291, "aes128gcm" content coding from RFC 8188), from OpenSSL's libcrypto: the
## P-256 key pair and auth secret a subscription hands to the site, and decrypting what the push service delivers.

# Loaded on first use, after libwebby, like passwords/crypto.nim: the process must have only the runtime's libcrypto.

import std/[base64, dynlib, os, strutils]

type CryptoError* = object of CatchableError

var
  EVP_PKEY_CTX_new_from_name: proc (libctx: pointer, name: cstring, propq: pointer): pointer {.cdecl.}
  EVP_PKEY_CTX_new: proc (pkey, engine: pointer): pointer {.cdecl.}
  EVP_PKEY_CTX_free: proc (ctx: pointer) {.cdecl.}
  EVP_PKEY_keygen_init: proc (ctx: pointer): cint {.cdecl.}
  EVP_PKEY_CTX_set_group_name: proc (ctx: pointer, name: cstring): cint {.cdecl.}
  EVP_PKEY_generate: proc (ctx: pointer, pkey: ptr pointer): cint {.cdecl.}
  EVP_PKEY_new: proc (): pointer {.cdecl.}
  EVP_PKEY_free: proc (pkey: pointer) {.cdecl.}
  EVP_PKEY_copy_parameters: proc (to, frm: pointer): cint {.cdecl.}
  EVP_PKEY_set1_encoded_public_key: proc (pkey: pointer, pub: pointer, len: csize_t): cint {.cdecl.}
  EVP_PKEY_get_octet_string_param: proc (pkey: pointer, name: cstring, buf: pointer, max: csize_t,
                                         len: ptr csize_t): cint {.cdecl.}
  EVP_PKEY_derive_init: proc (ctx: pointer): cint {.cdecl.}
  EVP_PKEY_derive_set_peer: proc (ctx, peer: pointer): cint {.cdecl.}
  EVP_PKEY_derive: proc (ctx: pointer, key: pointer, len: ptr csize_t): cint {.cdecl.}
  i2d_PrivateKey: proc (pkey: pointer, output: ptr pointer): cint {.cdecl.}
  d2i_AutoPrivateKey: proc (a: pointer, input: ptr pointer, len: clong): pointer {.cdecl.}
  EVP_sha256: proc (): pointer {.cdecl.}
  HMAC: proc (md: pointer, key: pointer, keyLen: cint, data: pointer, dataLen: csize_t, md5: pointer,
              mdLen: ptr cuint): pointer {.cdecl.}
  EVP_CIPHER_CTX_new: proc (): pointer {.cdecl.}
  EVP_CIPHER_CTX_free: proc (ctx: pointer) {.cdecl.}
  EVP_aes_128_gcm: proc (): pointer {.cdecl.}
  EVP_DecryptInit_ex: proc (ctx, cipher, engine: pointer, key, iv: pointer): cint {.cdecl.}
  EVP_DecryptUpdate: proc (ctx: pointer, output: pointer, outLen: ptr cint, input: pointer, inLen: cint): cint {.cdecl.}
  EVP_DecryptFinal_ex: proc (ctx: pointer, output: pointer, outLen: ptr cint): cint {.cdecl.}
  EVP_CIPHER_CTX_ctrl: proc (ctx: pointer, kind, arg: cint, p: pointer): cint {.cdecl.}
  RAND_bytes: proc (buf: pointer, num: cint): cint {.cdecl.}
  loaded = false

const EVP_CTRL_GCM_SET_TAG = 0x11.cint

proc loadCrypto() =
  if loaded: return
  var lib: LibHandle
  let runtime = getEnv("WEBBY_LADYBIRD_PREFIX")
  for name in [(if runtime.len > 0: runtime / "lib" / "libcrypto.so.3" else: ""), "libcrypto.so.3", "libcrypto.so",
      (when defined(android): "libwebby.so" else: "")]:
    if name.len == 0: continue
    lib = loadLib(name)
    if lib != nil: break
  if lib == nil: raise newException(CryptoError, "libcrypto not found")
  template sym(p: untyped) =
    p = cast[typeof(p)](lib.symAddr(astToStr(p)))
    if p == nil: raise newException(CryptoError, "libcrypto lacks " & astToStr(p))
  sym EVP_PKEY_CTX_new_from_name
  sym EVP_PKEY_CTX_new
  sym EVP_PKEY_CTX_free
  sym EVP_PKEY_keygen_init
  sym EVP_PKEY_CTX_set_group_name
  sym EVP_PKEY_generate
  sym EVP_PKEY_new
  sym EVP_PKEY_free
  sym EVP_PKEY_copy_parameters
  sym EVP_PKEY_set1_encoded_public_key
  sym EVP_PKEY_get_octet_string_param
  sym EVP_PKEY_derive_init
  sym EVP_PKEY_derive_set_peer
  sym EVP_PKEY_derive
  sym i2d_PrivateKey
  sym d2i_AutoPrivateKey
  sym EVP_sha256
  sym HMAC
  sym EVP_CIPHER_CTX_new
  sym EVP_CIPHER_CTX_free
  sym EVP_aes_128_gcm
  sym EVP_DecryptInit_ex
  sym EVP_DecryptUpdate
  sym EVP_DecryptFinal_ex
  sym EVP_CIPHER_CTX_ctrl
  sym RAND_bytes
  loaded = true

proc at(s: string): pointer = (if s.len == 0: nil else: unsafeAddr s[0])

proc check(ok: cint, what: string) =
  if ok != 1: raise newException(CryptoError, what & " failed")

proc randomBytes*(n: int): string =
  loadCrypto()
  result = newString(n)
  if n > 0: check RAND_bytes(addr result[0], n.cint), "RAND_bytes"

proc b64url*(s: string): string =
  ## Base64url without padding, the way Web Push spells keys.
  base64.encode(s, safe = true).strip(leading = false, chars = {'='})

proc unb64url*(s: string): string =
  ## Base64url or plain base64, with or without padding ("" if it isn't either).
  var t = s.strip.multiReplace(("-", "+"), ("_", "/"))
  while t.len mod 4 != 0: t.add '='
  try: base64.decode(t) except ValueError: ""

type KeyPair* = tuple[priv, pub: string]   ## the private key as DER, the public key as an uncompressed point

proc publicKey(pkey: pointer): string =
  result = newString(65)
  var n: csize_t
  check EVP_PKEY_get_octet_string_param(pkey, "encoded-pub-key", addr result[0], 65, addr n), "public key"
  result.setLen n

proc newKeyPair*(): KeyPair =
  ## A fresh P-256 key pair for a subscription.
  loadCrypto()
  let ctx = EVP_PKEY_CTX_new_from_name(nil, "EC", nil)
  if ctx == nil: raise newException(CryptoError, "EVP_PKEY_CTX_new_from_name failed")
  defer: EVP_PKEY_CTX_free(ctx)
  check EVP_PKEY_keygen_init(ctx), "keygen init"
  check EVP_PKEY_CTX_set_group_name(ctx, "P-256"), "P-256"
  var pkey: pointer
  check EVP_PKEY_generate(ctx, addr pkey), "keygen"
  defer: EVP_PKEY_free(pkey)
  let n = i2d_PrivateKey(pkey, nil)
  if n <= 0: raise newException(CryptoError, "i2d_PrivateKey failed")
  result.priv = newString(n)
  var p = cast[pointer](addr result.priv[0])
  discard i2d_PrivateKey(pkey, addr p)
  result.pub = publicKey(pkey)

proc hmac(key, data: string): string =
  result = newString(32)
  var n: cuint
  if HMAC(EVP_sha256(), at(key), key.len.cint, at(data), data.len.csize_t, addr result[0], addr n) == nil:
    raise newException(CryptoError, "HMAC failed")

proc ecdh(priv, peerPub: string): string =
  var p = at(priv)
  let ours = d2i_AutoPrivateKey(nil, addr p, priv.len.clong)
  if ours == nil: raise newException(CryptoError, "bad private key")
  defer: EVP_PKEY_free(ours)
  let peer = EVP_PKEY_new()
  defer: EVP_PKEY_free(peer)
  check EVP_PKEY_copy_parameters(peer, ours), "copy parameters"
  check EVP_PKEY_set1_encoded_public_key(peer, at(peerPub), peerPub.len.csize_t), "sender's public key"
  let ctx = EVP_PKEY_CTX_new(ours, nil)
  defer: EVP_PKEY_CTX_free(ctx)
  check EVP_PKEY_derive_init(ctx), "derive init"
  check EVP_PKEY_derive_set_peer(ctx, peer), "derive peer"
  var n: csize_t
  check EVP_PKEY_derive(ctx, nil, addr n), "derive"
  result = newString(n)
  check EVP_PKEY_derive(ctx, addr result[0], addr n), "derive"
  result.setLen n

proc aesGcmOpen(key, nonce, sealed: string): string =
  if sealed.len < 16: raise newException(CryptoError, "record too short")
  let ctx = EVP_CIPHER_CTX_new()
  defer: EVP_CIPHER_CTX_free(ctx)
  check EVP_DecryptInit_ex(ctx, EVP_aes_128_gcm(), nil, at(key), at(nonce)), "DecryptInit"
  let body = sealed[0 ..< ^16]
  var tag = sealed[^16 .. ^1]
  result = newString(body.len + 16)
  var n, m: cint
  check EVP_DecryptUpdate(ctx, addr result[0], addr n, at(body), body.len.cint), "DecryptUpdate"
  check EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, addr tag[0]), "SET_TAG"
  if EVP_DecryptFinal_ex(ctx, addr result[n], addr m) != 1:
    raise newException(CryptoError, "the message doesn't decrypt with this subscription's keys")
  result.setLen n + m

proc decrypt*(priv, pub, auth, body: string): string =
  ## A push message's plain text: `body` in the aes128gcm coding (salt, record size, the sender's key, records),
  ## for the subscription with key pair (`priv`, `pub`) and auth secret `auth`.
  loadCrypto()
  if body.len < 21: raise newException(CryptoError, "message too short")
  let salt = body[0 ..< 16]
  let rs = (ord(body[16]) shl 24) or (ord(body[17]) shl 16) or (ord(body[18]) shl 8) or ord(body[19])
  let idLen = ord(body[20])
  if rs < 18 or body.len < 21 + idLen: raise newException(CryptoError, "bad header")
  let senderPub = body[21 ..< 21 + idLen]
  let records = body[21 + idLen .. ^1]
  # RFC 8291 section 3.4: the input keying material from the ECDH secret and the auth secret.
  let prkKey = hmac(auth, ecdh(priv, senderPub))
  let ikm = hmac(prkKey, "WebPush: info\0" & pub & senderPub & "\x01")
  # RFC 8188 section 2.2/2.3: the content encryption key and nonce.
  let prk = hmac(salt, ikm)
  let cek = hmac(prk, "Content-Encoding: aes128gcm\0\x01")[0 ..< 16]
  let baseNonce = hmac(prk, "Content-Encoding: nonce\0\x01")[0 ..< 12]
  var i = 0
  var counter = 0
  while i < records.len:
    let record = records[i ..< min(i + rs, records.len)]
    i += record.len
    var nonce = baseNonce
    for k in 0 ..< 8: nonce[11 - k] = chr(ord(nonce[11 - k]) xor ((counter shr (8 * k)) and 0xff))
    inc counter
    var clear = aesGcmOpen(cek, nonce, record)
    # Padding: zeros after a delimiter, 2 in the last record, 1 in the others.
    var e = clear.high
    while e >= 0 and clear[e] == '\0': dec e
    if e < 0 or clear[e] notin {'\x01', '\x02'}: raise newException(CryptoError, "bad padding")
    let last = clear[e] == '\x02'
    clear.setLen e
    result.add clear
    if last: break
