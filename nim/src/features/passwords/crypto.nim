## AES-256-GCM and random bytes from OpenSSL's libcrypto, the same construction as the Dart `cryptography`
## package's AesGcm.with256bits(): a 12-byte nonce, a 16-byte tag kept apart from the ciphertext, optional AAD.

# Loaded on first use, after libwebby: the Ladybird runtime brings its own (newer) libcrypto.so.3, and the process must
# have only that one (loading the system's first makes libwebby fail to load). Outside the browser (tests) the
# system's is used.

import std/[dynlib, os]

const
  EVP_CTRL_GCM_SET_IVLEN = 0x9.cint
  EVP_CTRL_GCM_GET_TAG = 0x10.cint
  EVP_CTRL_GCM_SET_TAG = 0x11.cint

var
  EVP_CIPHER_CTX_new: proc (): pointer {.cdecl.}
  EVP_CIPHER_CTX_free: proc (ctx: pointer) {.cdecl.}
  EVP_aes_256_gcm: proc (): pointer {.cdecl.}
  EVP_EncryptInit_ex: proc (ctx, cipher, engine: pointer, key, iv: pointer): cint {.cdecl.}
  EVP_EncryptUpdate: proc (ctx: pointer, output: pointer, outLen: ptr cint, input: pointer, inLen: cint): cint {.cdecl.}
  EVP_EncryptFinal_ex: proc (ctx: pointer, output: pointer, outLen: ptr cint): cint {.cdecl.}
  EVP_DecryptInit_ex: proc (ctx, cipher, engine: pointer, key, iv: pointer): cint {.cdecl.}
  EVP_DecryptUpdate: proc (ctx: pointer, output: pointer, outLen: ptr cint, input: pointer, inLen: cint): cint {.cdecl.}
  EVP_DecryptFinal_ex: proc (ctx: pointer, output: pointer, outLen: ptr cint): cint {.cdecl.}
  EVP_CIPHER_CTX_ctrl: proc (ctx: pointer, kind, arg: cint, p: pointer): cint {.cdecl.}
  RAND_bytes: proc (buf: pointer, num: cint): cint {.cdecl.}
  loaded = false

type
  CryptoError* = object of CatchableError
  Sealed* = tuple[nonce, cipherText, mac: string]

proc loadCrypto() =
  if loaded: return
  var lib: LibHandle
  let runtime = getEnv("WEBBY_LADYBIRD_PREFIX")
  # On Android, OpenSSL is inside libwebby.so.
  for name in [(if runtime.len > 0: runtime / "lib" / "libcrypto.so.3" else: ""), "libcrypto.so.3", "libcrypto.so",
      (when defined(android): "libwebby.so" else: "")]:
    if name.len == 0: continue
    lib = loadLib(name)
    if lib != nil: break
  if lib == nil: raise newException(CryptoError, "libcrypto not found")
  template sym(p: untyped) =
    p = cast[typeof(p)](lib.symAddr(astToStr(p)))
    if p == nil: raise newException(CryptoError, "libcrypto lacks " & astToStr(p))
  sym EVP_CIPHER_CTX_new
  sym EVP_CIPHER_CTX_free
  sym EVP_aes_256_gcm
  sym EVP_EncryptInit_ex
  sym EVP_EncryptUpdate
  sym EVP_EncryptFinal_ex
  sym EVP_DecryptInit_ex
  sym EVP_DecryptUpdate
  sym EVP_DecryptFinal_ex
  sym EVP_CIPHER_CTX_ctrl
  sym RAND_bytes
  loaded = true

proc at(s: string): pointer = (if s.len == 0: nil else: unsafeAddr s[0])

proc randomBytes*(n: int): string =
  ## n bytes from OpenSSL's CSPRNG.
  loadCrypto()
  result = newString(n)
  if n > 0 and RAND_bytes(addr result[0], n.cint) != 1: raise newException(CryptoError, "RAND_bytes failed")

proc check(ok: cint, what: string) =
  if ok != 1: raise newException(CryptoError, what & " failed")

proc seal*(key, clear, aad: string): Sealed =
  ## Encrypts with a fresh random nonce.
  if key.len != 32: raise newException(CryptoError, "AES-256 needs a 32-byte key")
  let nonce = randomBytes(12)
  loadCrypto()
  let ctx = EVP_CIPHER_CTX_new()
  if ctx == nil: raise newException(CryptoError, "EVP_CIPHER_CTX_new failed")
  defer: EVP_CIPHER_CTX_free(ctx)
  check EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nil, nil, nil), "EncryptInit"
  check EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nil), "SET_IVLEN"
  check EVP_EncryptInit_ex(ctx, nil, nil, key.at, nonce.at), "EncryptInit key"
  var n: cint
  if aad.len > 0: check EVP_EncryptUpdate(ctx, nil, addr n, aad.at, aad.len.cint), "EncryptUpdate aad"
  var output = newString(clear.len + 16)
  var total = 0
  if clear.len > 0:
    check EVP_EncryptUpdate(ctx, addr output[0], addr n, clear.at, clear.len.cint), "EncryptUpdate"
    total = n
  check EVP_EncryptFinal_ex(ctx, addr output[total], addr n), "EncryptFinal"
  total += n
  output.setLen(total)
  var tag = newString(16)
  check EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, addr tag[0]), "GET_TAG"
  (nonce, output, tag)

proc unseal*(key: string, box: Sealed, aad: string): string =
  ## Decrypts and checks the tag; raises CryptoError if it doesn't match.
  if key.len != 32: raise newException(CryptoError, "AES-256 needs a 32-byte key")
  if box.mac.len != 16: raise newException(CryptoError, "bad tag length")
  loadCrypto()
  let ctx = EVP_CIPHER_CTX_new()
  if ctx == nil: raise newException(CryptoError, "EVP_CIPHER_CTX_new failed")
  defer: EVP_CIPHER_CTX_free(ctx)
  check EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nil, nil, nil), "DecryptInit"
  check EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, box.nonce.len.cint, nil), "SET_IVLEN"
  check EVP_DecryptInit_ex(ctx, nil, nil, key.at, box.nonce.at), "DecryptInit key"
  var n: cint
  if aad.len > 0: check EVP_DecryptUpdate(ctx, nil, addr n, aad.at, aad.len.cint), "DecryptUpdate aad"
  result = newString(box.cipherText.len + 16)
  var total = 0
  if box.cipherText.len > 0:
    check EVP_DecryptUpdate(ctx, addr result[0], addr n, box.cipherText.at, box.cipherText.len.cint), "DecryptUpdate"
    total = n
  var tag = box.mac
  check EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, addr tag[0]), "SET_TAG"
  if EVP_DecryptFinal_ex(ctx, addr result[total], addr n) != 1:
    raise newException(CryptoError, "authentication failed")
  total += n
  result.setLen(total)
